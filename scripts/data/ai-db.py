#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "sqlite-vec",
# ]
# ///
"""ai-db.py — Database management backend for the ai-db TUI.

Provides subcommands for inspecting, browsing, searching, and maintaining
the ai-search vector database and feedback store.  Called by ai-db.sh; not
meant for direct interactive use.

Subcommands:
    status          Print JSON summary of database stats
    files           List indexed files with chunk counts
    chunks ROWID    Show chunks for a specific file (by any rowid belonging to it)
    filepath PATH   Show chunks for a file by its path
    search QUERY    Semantic + BM25 hybrid search
    stale           List files whose mtime on disk is newer than indexed mtime
    orphans         List metadata rows whose source file no longer exists on disk
    delete PATH     Delete all chunks for a given filepath
    delete-orphans  Remove all orphan entries
    vacuum          VACUUM + integrity check
    fts-rebuild     Rebuild the FTS5 index from file_metadata
    top-utility     Show top chunks by learned utility score
    top-files       Show top indexed files by chunk count
"""

from __future__ import annotations

import json
import os
import sys
import sqlite3
import time
from pathlib import Path

# ── Resolve lib path ─────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent
_lib = os.environ.get("AI_LIB_PATH") or str(SCRIPT_DIR.parent / "lib")
sys.path.insert(0, _lib)

import sqlite_vec  # noqa: E402
from config import get as _cfg  # noqa: E402

# ── Paths ────────────────────────────────────────────────────────────────────

XDG_DATA_HOME = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
APP_DIR = Path(XDG_DATA_HOME) / "ai-search"
DB_PATH = APP_DIR / "vectors.db"
FEEDBACK_DB_PATH = APP_DIR / "feedback.db"


def _open_db() -> sqlite3.Connection:
    """Open the vector database (read-only mode)."""
    if not DB_PATH.exists():
        print(json.dumps({"error": f"Database not found at {DB_PATH}"}))
        sys.exit(1)
    conn = sqlite3.connect(DB_PATH)
    conn.enable_load_extension(True)
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)
    return conn


def _open_feedback_db() -> sqlite3.Connection | None:
    """Open the feedback database if it exists."""
    if not FEEDBACK_DB_PATH.exists():
        return None
    return sqlite3.connect(FEEDBACK_DB_PATH)


# ── Subcommands ──────────────────────────────────────────────────────────────

def cmd_status() -> None:
    conn = _open_db()
    cur = conn.cursor()

    cur.execute("SELECT COUNT(DISTINCT filepath), COUNT(*) FROM file_metadata")
    files, chunks = cur.fetchone()
    size_mb = DB_PATH.stat().st_size / (1024 * 1024)

    # FTS5 row count
    try:
        cur.execute("SELECT COUNT(*) FROM file_chunks_fts")
        fts_count = cur.fetchone()[0]
    except sqlite3.OperationalError:
        fts_count = 0

    # Feedback stats
    feedback_chunks = 0
    fconn = _open_feedback_db()
    if fconn:
        try:
            fc = fconn.cursor()
            fc.execute("SELECT COUNT(*) FROM chunk_utility")
            feedback_chunks = fc.fetchone()[0]
        except sqlite3.OperationalError:
            pass
        fconn.close()

    feedback_size = 0
    if FEEDBACK_DB_PATH.exists():
        feedback_size = round(FEEDBACK_DB_PATH.stat().st_size / (1024 * 1024), 2)

    # File type distribution
    cur.execute("""
        SELECT
            CASE
                WHEN filepath LIKE '%.py' THEN '.py'
                WHEN filepath LIKE '%.sh' THEN '.sh'
                WHEN filepath LIKE '%.nix' THEN '.nix'
                WHEN filepath LIKE '%.md' THEN '.md'
                WHEN filepath LIKE '%.toml' THEN '.toml'
                WHEN filepath LIKE '%.json' THEN '.json'
                WHEN filepath LIKE '%.yml' OR filepath LIKE '%.yaml' THEN '.yaml'
                WHEN filepath LIKE '%.js' OR filepath LIKE '%.jsx' THEN '.js'
                WHEN filepath LIKE '%.ts' OR filepath LIKE '%.tsx' THEN '.ts'
                WHEN filepath LIKE '%.rs' THEN '.rs'
                WHEN filepath LIKE '%.go' THEN '.go'
                WHEN filepath LIKE '%.css' THEN '.css'
                WHEN filepath LIKE '%.html' THEN '.html'
                WHEN filepath LIKE '%.pdf' THEN '.pdf'
                WHEN filepath LIKE '%.docx' THEN '.docx'
                WHEN filepath LIKE '%.txt' THEN '.txt'
                ELSE 'other'
            END AS ext,
            COUNT(DISTINCT filepath) AS file_count,
            COUNT(*) AS chunk_count
        FROM file_metadata
        GROUP BY ext
        ORDER BY chunk_count DESC
    """)
    file_types = [{"ext": r[0], "files": r[1], "chunks": r[2]} for r in cur.fetchall()]

    # Top directories
    cur.execute("""
        SELECT
            SUBSTR(filepath, 1, INSTR(filepath || '/', '/')) AS top_dir,
            COUNT(DISTINCT filepath),
            COUNT(*)
        FROM file_metadata
        GROUP BY top_dir
        ORDER BY COUNT(*) DESC
        LIMIT 10
    """)

    conn.close()

    print(json.dumps({
        "db_path": str(DB_PATH),
        "size_mb": round(size_mb, 2),
        "files_indexed": files or 0,
        "total_chunks": chunks or 0,
        "fts_rows": fts_count,
        "feedback_db_path": str(FEEDBACK_DB_PATH),
        "feedback_size_mb": feedback_size,
        "feedback_chunks": feedback_chunks,
        "file_types": file_types,
    }))


def cmd_files() -> None:
    conn = _open_db()
    cur = conn.cursor()
    cur.execute("""
        SELECT filepath, COUNT(*) AS chunk_count,
               MAX(mtime) AS last_mtime
        FROM file_metadata
        GROUP BY filepath
        ORDER BY filepath
    """)
    rows = cur.fetchall()
    conn.close()

    for fp, count, mtime in rows:
        ts = time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
        print(f"{count:4d} chunks  {ts}  {fp}")


def cmd_chunks(identifier: str) -> None:
    conn = _open_db()
    cur = conn.cursor()

    # First try as filepath
    cur.execute("""
        SELECT rowid, filepath, snippet, chunk_text, mtime
        FROM file_metadata
        WHERE filepath = ?
        ORDER BY rowid
    """, (identifier,))
    rows = cur.fetchall()

    # If not found, try as rowid to get the filepath, then get all chunks
    if not rows:
        try:
            rid = int(identifier)
            cur.execute("SELECT filepath FROM file_metadata WHERE rowid = ?", (rid,))
            result = cur.fetchone()
            if result:
                cur.execute("""
                    SELECT rowid, filepath, snippet, chunk_text, mtime
                    FROM file_metadata
                    WHERE filepath = ?
                    ORDER BY rowid
                """, (result[0],))
                rows = cur.fetchall()
        except ValueError:
            pass

    conn.close()

    if not rows:
        print(json.dumps({"error": f"No chunks found for: {identifier}"}))
        sys.exit(1)

    results = []
    for rowid, fp, snippet, chunk_text, mtime in rows:
        results.append({
            "rowid": rowid,
            "filepath": fp,
            "snippet": snippet,
            "chunk_text_len": len(chunk_text) if chunk_text else 0,
            "chunk_text_preview": (chunk_text[:300] + "...") if chunk_text and len(chunk_text) > 300 else chunk_text,
            "mtime": time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime)),
        })

    print(json.dumps(results, indent=2))


def cmd_search(query: str) -> None:
    """Hybrid search — uses embeddings lib directly."""
    from embeddings import open_db, retrieve_with_chunks  # noqa: E402

    conn = open_db()
    results = retrieve_with_chunks(conn, query, top_k=15)
    conn.close()

    for i, r in enumerate(results, 1):
        score = r.get("score", 0)
        fp = r.get("filepath", "?")
        snippet = r.get("snippet", "")[:120]
        print(f"  {i:2d}. [{score:.4f}]  {fp}")
        print(f"      {snippet}")
        print()


def cmd_stale() -> None:
    conn = _open_db()
    cur = conn.cursor()
    cur.execute("SELECT DISTINCT filepath, MAX(mtime) FROM file_metadata GROUP BY filepath")
    rows = cur.fetchall()
    conn.close()

    stale = []
    for fp, indexed_mtime in rows:
        p = Path(fp)
        if p.exists():
            try:
                disk_mtime = p.stat().st_mtime
                if disk_mtime > indexed_mtime:
                    stale.append({
                        "filepath": fp,
                        "indexed": time.strftime("%Y-%m-%d %H:%M", time.localtime(indexed_mtime)),
                        "on_disk": time.strftime("%Y-%m-%d %H:%M", time.localtime(disk_mtime)),
                    })
            except OSError:
                pass

    print(json.dumps(stale, indent=2))


def cmd_orphans() -> None:
    conn = _open_db()
    cur = conn.cursor()
    cur.execute("SELECT DISTINCT filepath FROM file_metadata")
    rows = cur.fetchall()
    conn.close()

    orphans = []
    for (fp,) in rows:
        if not Path(fp).exists():
            orphans.append(fp)

    for o in sorted(orphans):
        print(o)

    if not orphans:
        print("No orphans found.")
    else:
        print(f"\n{len(orphans)} orphaned file(s) found.")


def cmd_delete(filepath: str) -> None:
    conn = _open_db()
    cur = conn.cursor()
    cur.execute("SELECT rowid FROM file_metadata WHERE filepath = ?", (filepath,))
    rowids = [r[0] for r in cur.fetchall()]

    if not rowids:
        print(json.dumps({"error": f"No entries found for: {filepath}"}))
        conn.close()
        sys.exit(1)

    placeholders = ",".join("?" * len(rowids))
    cur.execute(f"DELETE FROM file_embeddings WHERE rowid IN ({placeholders})", rowids)
    cur.execute(f"DELETE FROM file_metadata WHERE rowid IN ({placeholders})", rowids)
    conn.commit()
    conn.close()

    print(json.dumps({"deleted": filepath, "chunks_removed": len(rowids)}))


def cmd_delete_orphans() -> None:
    conn = _open_db()
    cur = conn.cursor()
    cur.execute("SELECT DISTINCT filepath FROM file_metadata")
    rows = cur.fetchall()

    deleted = 0
    for (fp,) in rows:
        if not Path(fp).exists():
            cur.execute("SELECT rowid FROM file_metadata WHERE filepath = ?", (fp,))
            rowids = [r[0] for r in cur.fetchall()]
            if rowids:
                ph = ",".join("?" * len(rowids))
                cur.execute(f"DELETE FROM file_embeddings WHERE rowid IN ({ph})", rowids)
                cur.execute(f"DELETE FROM file_metadata WHERE rowid IN ({ph})", rowids)
                deleted += len(rowids)

    conn.commit()
    conn.close()
    print(json.dumps({"orphan_chunks_deleted": deleted}))


def cmd_vacuum() -> None:
    conn = _open_db()
    cur = conn.cursor()
    cur.execute("PRAGMA integrity_check")
    result = cur.fetchone()[0]
    if result != "ok":
        print(json.dumps({"error": f"Integrity check failed: {result}"}))
        conn.close()
        sys.exit(1)

    size_before = DB_PATH.stat().st_size
    conn.execute("VACUUM")
    conn.close()
    size_after = DB_PATH.stat().st_size

    saved_kb = (size_before - size_after) / 1024
    print(json.dumps({
        "integrity": "ok",
        "size_before_mb": round(size_before / (1024 * 1024), 2),
        "size_after_mb": round(size_after / (1024 * 1024), 2),
        "saved_kb": round(saved_kb, 1),
    }))


def cmd_fts_rebuild() -> None:
    conn = _open_db()
    try:
        conn.execute("INSERT INTO file_chunks_fts(file_chunks_fts) VALUES('rebuild')")
        conn.commit()

        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM file_chunks_fts")
        count = cur.fetchone()[0]
        print(json.dumps({"rebuilt": True, "fts_rows": count}))
    except sqlite3.OperationalError as e:
        print(json.dumps({"error": str(e)}))
    conn.close()


def cmd_top_utility() -> None:
    fconn = _open_feedback_db()
    if not fconn:
        print("No feedback database found.")
        return

    decay_halflife = float(_cfg("learning", "decay_halflife_days", 30))
    now = time.time()

    try:
        fc = fconn.cursor()
        fc.execute("SELECT chunk_rowid, utility_ema, last_used FROM chunk_utility ORDER BY utility_ema DESC LIMIT 25")
        rows = fc.fetchall()
    except sqlite3.OperationalError:
        print("No chunk_utility table found.")
        fconn.close()
        return

    fconn.close()

    if not rows:
        print("No utility data recorded yet.")
        return

    # Enrich with filepath from vectors DB
    conn = _open_db()
    cur = conn.cursor()

    for rid, ema, last_used in rows:
        age_days = (now - last_used) / 86400
        decay = 0.5 ** (age_days / decay_halflife) if decay_halflife > 0 else 1.0
        decayed = 0.5 + (ema - 0.5) * decay

        cur.execute("SELECT filepath, snippet FROM file_metadata WHERE rowid = ?", (rid,))
        result = cur.fetchone()
        fp = result[0] if result else "?"
        snippet = (result[1][:80] if result else "?")

        print(f"  [{decayed:.3f}]  rowid={rid}  {fp}")
        print(f"           {snippet}")
        print()

    conn.close()


def cmd_top_files() -> None:
    conn = _open_db()
    cur = conn.cursor()
    cur.execute("""
        SELECT filepath, COUNT(*) AS chunks, MAX(mtime)
        FROM file_metadata
        GROUP BY filepath
        ORDER BY chunks DESC
        LIMIT 25
    """)
    rows = cur.fetchall()
    conn.close()

    for fp, chunks, mtime in rows:
        ts = time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
        print(f"  {chunks:4d} chunks  {ts}  {fp}")


# ── Dispatch ─────────────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: ai-db.py <subcommand> [args]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    dispatch = {
        "status": lambda: cmd_status(),
        "files": lambda: cmd_files(),
        "chunks": lambda: cmd_chunks(sys.argv[2]) if len(sys.argv) > 2 else print("Usage: ai-db.py chunks <filepath|rowid>"),
        "search": lambda: cmd_search(" ".join(sys.argv[2:])) if len(sys.argv) > 2 else print("Usage: ai-db.py search <query>"),
        "stale": lambda: cmd_stale(),
        "orphans": lambda: cmd_orphans(),
        "delete": lambda: cmd_delete(sys.argv[2]) if len(sys.argv) > 2 else print("Usage: ai-db.py delete <filepath>"),
        "delete-orphans": lambda: cmd_delete_orphans(),
        "vacuum": lambda: cmd_vacuum(),
        "fts-rebuild": lambda: cmd_fts_rebuild(),
        "top-utility": lambda: cmd_top_utility(),
        "top-files": lambda: cmd_top_files(),
    }

    if cmd in dispatch:
        dispatch[cmd]()
    else:
        print(f"Unknown subcommand: {cmd}", file=sys.stderr)
        print(f"Available: {', '.join(sorted(dispatch.keys()))}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
