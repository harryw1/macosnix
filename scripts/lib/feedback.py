"""feedback — Persistent learning layer for the ai-scripts quality pipeline.

Maintains a SQLite database (separate from vectors.db) that tracks:
  - query_log: every query that runs through the pipeline
  - chunk_utility: per-chunk EMA utility scores updated after each query
  - exemplar_bank: high-quality past (query, answer) pairs for few-shot injection

The chunk utility scores feed back into retrieval via RRF fusion, creating
a recurrent loop: use → evaluate → update state → influence next retrieval.

Not meant to be run standalone.
"""

from __future__ import annotations

import sqlite3
import struct
import time
from pathlib import Path

from config import get as _cfg

# ── Paths ────────────────────────────────────────────────────────────────────

_XDG_DATA = Path(
    __import__("os").environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")
)
FEEDBACK_DB_PATH = _XDG_DATA / "ai-search" / "feedback.db"

# ── Learning constants (from config) ─────────────────────────────────────────

ALPHA = float(_cfg("learning", "alpha", 0.3))
DECAY_HALFLIFE_DAYS = float(_cfg("learning", "decay_halflife_days", 30))
EXEMPLAR_THRESHOLD = float(_cfg("learning", "exemplar_threshold", 0.85))
MAX_EXEMPLARS = int(_cfg("learning", "max_exemplars_per_tool", 50))
LEARNING_ENABLED = _cfg("learning", "enabled", True)

# ── Embedding helpers (duplicated to avoid circular import) ──────────────────

def _vec_to_bytes(vec: list[float]) -> bytes:
    return struct.pack(f"<{len(vec)}f", *vec)


def _bytes_to_vec(raw: bytes) -> list[float]:
    n = len(raw) // 4
    return list(struct.unpack(f"<{n}f", raw))


# ── Database ─────────────────────────────────────────────────────────────────

def init_feedback_db(db_path: Path | None = None) -> sqlite3.Connection:
    """Create (or open) the feedback database with full schema."""
    db = db_path or FEEDBACK_DB_PATH
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db)
    conn.execute("PRAGMA journal_mode=WAL;")

    conn.execute("""
        CREATE TABLE IF NOT EXISTS query_log (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp   REAL NOT NULL,
            tool        TEXT NOT NULL,
            query       TEXT NOT NULL,
            answer      TEXT,
            grounded    BOOLEAN,
            confidence  REAL,
            feedback    INTEGER DEFAULT 0,
            resolved    BOOLEAN DEFAULT FALSE
        )
    """)

    conn.execute("""
        CREATE TABLE IF NOT EXISTS chunk_utility (
            chunk_rowid INTEGER PRIMARY KEY,
            utility_ema REAL DEFAULT 0.5,
            hit_count   INTEGER DEFAULT 0,
            last_used   REAL NOT NULL
        )
    """)

    conn.execute("""
        CREATE TABLE IF NOT EXISTS exemplar_bank (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            tool        TEXT NOT NULL,
            query       TEXT NOT NULL,
            answer      TEXT NOT NULL,
            score       REAL NOT NULL,
            embedding   BLOB,
            created     REAL NOT NULL
        )
    """)

    return conn


def open_feedback_db(db_path: Path | None = None) -> sqlite3.Connection | None:
    """Open the feedback DB if it exists.  Returns None if it doesn't."""
    db = db_path or FEEDBACK_DB_PATH
    if not db.exists():
        return None
    conn = sqlite3.connect(db)
    conn.execute("PRAGMA journal_mode=WAL;")
    return conn


# ── Query Logging ────────────────────────────────────────────────────────────

def log_query(
    conn: sqlite3.Connection,
    *,
    tool: str,
    query: str,
    answer: str | None = None,
    grounded: bool | None = None,
    confidence: float | None = None,
    chunk_rowids: list[int] | None = None,
) -> int:
    """Log a pipeline query and return the log entry ID.

    Also triggers chunk utility updates based on the verification result.
    """
    now = time.time()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO query_log (timestamp, tool, query, answer, grounded, confidence) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (now, tool, query, answer, grounded, confidence),
    )
    log_id = cur.lastrowid
    conn.commit()

    # Update chunk utility if we have both chunks and a verification signal
    if chunk_rowids and grounded is not None:
        if grounded and (confidence or 0) > 0.8:
            signal = 1.0
        elif not grounded:
            signal = -0.5
        else:
            signal = 0.3  # grounded but low-confidence → mild positive
        update_chunk_utility(conn, chunk_rowids, signal)

    return log_id


def detect_rerun(conn: sqlite3.Connection, tool: str, query: str, window_s: float = 60.0) -> bool:
    """Check if the same query was run recently (within *window_s* seconds).

    If so, apply a negative signal to the chunks from the previous run,
    since the user wasn't satisfied with the first result.
    """
    now = time.time()
    cur = conn.cursor()
    cur.execute(
        "SELECT id FROM query_log "
        "WHERE tool = ? AND query = ? AND timestamp > ? "
        "ORDER BY timestamp DESC LIMIT 1",
        (tool, query, now - window_s),
    )
    row = cur.fetchone()
    return row is not None


def mark_feedback(conn: sqlite3.Connection, log_id: int, feedback: int) -> None:
    """Record explicit feedback (-1, 0, or +1) for a logged query."""
    conn.execute(
        "UPDATE query_log SET feedback = ? WHERE id = ?",
        (feedback, log_id),
    )
    conn.commit()


# ── Chunk Utility EMA ────────────────────────────────────────────────────────

def update_chunk_utility(
    conn: sqlite3.Connection,
    chunk_rowids: list[int],
    signal: float,
    *,
    alpha: float = ALPHA,
) -> None:
    """Update the utility EMA for chunks that contributed to a response.

    signal values:
      +1.0  grounded/accepted answer
      +0.3  user moved to new topic (implicit satisfaction)
      -0.1  user asked a follow-up (incomplete answer)
      -0.3  user re-ran same query within 60s
      -0.5  verification failed (ungrounded)
      -1.0  explicit negative feedback
    """
    now = time.time()
    cur = conn.cursor()
    for rid in chunk_rowids:
        cur.execute(
            "SELECT utility_ema, hit_count FROM chunk_utility WHERE chunk_rowid = ?",
            (rid,),
        )
        row = cur.fetchone()
        if row:
            old_ema, hits = row
            new_ema = alpha * signal + (1 - alpha) * old_ema
            cur.execute(
                "UPDATE chunk_utility SET utility_ema = ?, hit_count = ?, last_used = ? "
                "WHERE chunk_rowid = ?",
                (new_ema, hits + 1, now, rid),
            )
        else:
            # First time seeing this chunk — start at neutral + signal
            new_ema = 0.5 + alpha * signal
            cur.execute(
                "INSERT INTO chunk_utility (chunk_rowid, utility_ema, hit_count, last_used) "
                "VALUES (?, ?, 1, ?)",
                (rid, new_ema, now),
            )
    conn.commit()


def load_utility_scores(
    conn: sqlite3.Connection | None = None,
    *,
    decay_halflife: float = DECAY_HALFLIFE_DAYS,
) -> dict[int, float] | None:
    """Load all chunk utility scores with temporal decay applied.

    Scores decay toward 0.5 (neutral) over time so that stale signals
    don't permanently dominate ranking.
    """
    if conn is None:
        conn = open_feedback_db()
        if conn is None:
            return None
        should_close = True
    else:
        should_close = False

    now = time.time()
    try:
        cur = conn.cursor()
        cur.execute("SELECT chunk_rowid, utility_ema, last_used FROM chunk_utility")
        rows = cur.fetchall()
    except sqlite3.OperationalError:
        if should_close:
            conn.close()
        return None

    if should_close:
        conn.close()

    if not rows:
        return None

    scores: dict[int, float] = {}
    for rid, ema, last_used in rows:
        age_days = (now - last_used) / 86400
        decay = 0.5 ** (age_days / decay_halflife) if decay_halflife > 0 else 1.0
        decayed = 0.5 + (ema - 0.5) * decay
        scores[rid] = decayed

    return scores


# ── Exemplar Bank ────────────────────────────────────────────────────────────

def maybe_store_exemplar(
    conn: sqlite3.Connection,
    *,
    tool: str,
    query: str,
    answer: str,
    confidence: float,
    query_embedding: list[float] | None = None,
    threshold: float = EXEMPLAR_THRESHOLD,
    max_exemplars: int = MAX_EXEMPLARS,
) -> bool:
    """Store a high-quality (query, answer) pair in the exemplar bank.

    Returns True if stored, False if the answer didn't meet the threshold.
    """
    if confidence < threshold or len(answer) > 800:
        return False

    emb_bytes = _vec_to_bytes(query_embedding) if query_embedding else None

    conn.execute(
        "INSERT INTO exemplar_bank (tool, query, answer, score, embedding, created) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (tool, query, answer, confidence, emb_bytes, time.time()),
    )

    # Keep the bank bounded — retain only the top N per tool
    conn.execute(
        "DELETE FROM exemplar_bank WHERE tool = ? AND id NOT IN "
        "(SELECT id FROM exemplar_bank WHERE tool = ? ORDER BY score DESC LIMIT ?)",
        (tool, tool, max_exemplars),
    )
    conn.commit()
    return True


def get_best_exemplar(
    conn: sqlite3.Connection,
    *,
    tool: str,
    query_embedding: list[float],
    threshold: float = 0.7,
) -> dict | None:
    """Return the most relevant past exemplar for *tool*, or None.

    Uses cosine distance between the current query embedding and stored
    exemplar embeddings.  Requires sqlite-vec to be loaded on *conn*.
    """
    emb_bytes = _vec_to_bytes(query_embedding)
    cur = conn.cursor()

    try:
        # Load all exemplars for this tool and compute distance manually
        # (exemplar_bank isn't a vec0 table, so we do brute-force search
        # over the small set — max 50 rows per tool)
        cur.execute(
            "SELECT query, answer, embedding FROM exemplar_bank "
            "WHERE tool = ? AND embedding IS NOT NULL",
            (tool,),
        )
        rows = cur.fetchall()
    except sqlite3.OperationalError:
        return None

    if not rows:
        return None

    # Cosine similarity via dot product (embeddings are normalised by Ollama)
    import math
    query_vec = _bytes_to_vec(emb_bytes) if isinstance(emb_bytes, bytes) else query_embedding

    best_sim = -1.0
    best_row = None

    for q_text, a_text, stored_emb in rows:
        if stored_emb is None:
            continue
        stored_vec = _bytes_to_vec(stored_emb)
        # Cosine similarity
        dot = sum(a * b for a, b in zip(query_vec, stored_vec))
        norm_q = math.sqrt(sum(a * a for a in query_vec))
        norm_s = math.sqrt(sum(b * b for b in stored_vec))
        if norm_q == 0 or norm_s == 0:
            continue
        sim = dot / (norm_q * norm_s)
        if sim > best_sim:
            best_sim = sim
            best_row = (q_text, a_text)

    # Threshold is in distance space (lower = better), convert from similarity
    if best_row and best_sim >= (1.0 - threshold):
        return {"query": best_row[0], "answer": best_row[1]}

    return None
