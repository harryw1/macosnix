# Quality Pipeline Plan: Retrieve → Rerank → Generate → Verify → Learn

A four-stage quality pipeline plus a persistent learning layer for the
ai-scripts suite. Each stage is independent and can be shipped incrementally.
The plan references actual module paths and function signatures as they exist
today so that implementation patches are straightforward.

---

## Architecture Overview

```
                              ┌──────────────────────────────────────────────┐
                              │            Feedback Store (SQLite)           │
                              │  query_log · chunk_utility · exemplar_bank  │
                              └──────────┬──────────────────────┬───────────┘
                                         │ read utility scores  │ write feedback
    ┌──────────┐    ┌────────────────┐   │   ┌──────────────┐   │   ┌──────────────┐
    │  Query   │───▶│ Stage 1        │───┼──▶│ Stage 2      │──▶│──▶│ Stage 3      │
    │  (user)  │    │ Hybrid         │   │   │ Thinking-    │   │   │ Large-Model  │
    │          │    │ Retrieval      │   │   │ Model Rerank │   │   │ Generation   │
    └──────────┘    │ BM25 + Vector  │   │   │ (lfm2.5)    │   │   │ (qwen3.5:9b) │
                    │ + RRF + Utility│   │   └──────────────┘   │   └──────┬───────┘
                    └────────────────┘   │                      │          │
                                         │                      │          ▼
                                         │                      │   ┌──────────────┐
                                         │                      │   │ Stage 4      │
                                         │                      └───│ Thinking-    │
                                         │                          │ Model Verify │
                                         │                          │ (lfm2.5)    │
                                         │                          └──────┬───────┘
                                         │                                 │
                                         │      ┌───────────┐             │
                                         └──────│ Stage 5   │◀────────────┘
                                                │ Feedback   │
                                                │ Learning   │
                                                └───────────┘
```

---

## Stage 1 — Hybrid Retrieval (BM25 + Vector + RRF)

**Goal:** Catch queries where keyword match matters more than semantic
similarity, without losing the benefits of vector search.

**Latency cost:** ~0 ms extra (BM25 over SQLite FTS5 is sub-millisecond).

**No additional model calls.**

### 1.1 Schema Changes (embeddings.py — `init_db`)

Add an FTS5 virtual table alongside the existing vec0 table:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS file_chunks_fts USING fts5(
    chunk_text,
    content='file_metadata',
    content_rowid='rowid'
);
```

Add FTS5 triggers to keep the index in sync when rows are inserted or deleted
in `file_metadata`. This can go in `init_db()` right after the existing
`CREATE TABLE` statements.

Populate the FTS index from existing data on first migration:

```sql
INSERT INTO file_chunks_fts(file_chunks_fts)
VALUES('rebuild');
```

### 1.2 New Function: `bm25_search` (embeddings.py)

```python
def bm25_search(
    conn: sqlite3.Connection,
    query: str,
    *,
    top_k: int = 20,
    scope: str | None = None,
) -> list[dict]:
    """Keyword search over chunk_text using SQLite FTS5 BM25 ranking."""
    scope_clause = ""
    params: list = [query, top_k]
    if scope:
        scope_clause = "AND m.filepath LIKE ?"
        params.insert(1, scope.rstrip("/") + "/%")

    cur = conn.cursor()
    cur.execute(f"""
        SELECT m.rowid, m.filepath, m.snippet,
               COALESCE(m.chunk_text, m.snippet) AS chunk_text,
               rank  -- FTS5's built-in BM25 rank (lower = better)
        FROM file_chunks_fts fts
        JOIN file_metadata m ON fts.rowid = m.rowid
        WHERE file_chunks_fts MATCH ?
        {scope_clause}
        ORDER BY rank
        LIMIT ?
    """, params)
    return [
        {"rowid": r[0], "filepath": r[1], "snippet": r[2],
         "chunk_text": r[3], "bm25_rank": i + 1}
        for i, r in enumerate(cur.fetchall())
    ]
```

### 1.3 Reciprocal Rank Fusion (embeddings.py)

Merge the two ranked lists into a single fused ranking:

```python
RRF_K = 60  # standard constant from the RRF paper

def reciprocal_rank_fusion(
    vec_results: list[dict],
    bm25_results: list[dict],
    utility_scores: dict[int, float] | None = None,
    *,
    k: int = RRF_K,
    utility_weight: float = 0.15,
) -> list[dict]:
    """Fuse vector and BM25 ranked lists using RRF, with optional utility boost.

    Each result dict must have a 'rowid' key (for dedup) and either a
    'vec_rank' or 'bm25_rank' key set by the caller.

    When utility_scores is provided, each chunk's accumulated utility EMA
    is added as a third signal: rrf += utility_weight * utility_ema.
    """
    scores: dict[int, float] = {}
    lookup: dict[int, dict] = {}

    for i, r in enumerate(vec_results):
        rid = r["rowid"]
        scores[rid] = scores.get(rid, 0.0) + 1.0 / (k + i + 1)
        lookup[rid] = r

    for i, r in enumerate(bm25_results):
        rid = r["rowid"]
        scores[rid] = scores.get(rid, 0.0) + 1.0 / (k + i + 1)
        lookup.setdefault(rid, r)

    # Blend in learned utility scores
    if utility_scores:
        for rid, ema in utility_scores.items():
            if rid in scores:
                scores[rid] += utility_weight * ema

    ranked = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    return [lookup[rid] for rid, _ in ranked]
```

### 1.4 Updated `retrieve_with_chunks`

The existing function signature stays the same. Internally it now runs both
search paths and fuses:

```python
def retrieve_with_chunks(conn, query, *, top_k=5, max_distance=0.8,
                         scope=None, embed_timeout=30):
    # Vector search (existing path, widen to top_k * 3)
    vec_results = _vector_search(conn, query, top_k=top_k * 3,
                                 max_distance=max_distance, scope=scope,
                                 embed_timeout=embed_timeout)
    # BM25 search (new path)
    bm25_results = bm25_search(conn, query, top_k=top_k * 3, scope=scope)

    # Load utility scores from feedback store
    utility = _load_utility_scores(conn)

    # Fuse
    fused = reciprocal_rank_fusion(vec_results, bm25_results, utility)
    return fused[:top_k]
```

Extract the current vector-search SQL into a private `_vector_search` helper to
keep things clean. The public API does not change, so ai-chat.py, ai-search.py,
and all downstream consumers are unaffected.

### 1.5 Config Additions (config.py — DEFAULTS)

```toml
[retrieval]
rrf_k = 60
bm25_enabled = true        # kill switch for hybrid search
utility_weight = 0.15      # how much learned utility influences ranking
```

---

## Stage 2 — Thinking-Model Rerank

**Goal:** Use `lfm2.5-thinking:1.2b` as a lightweight cross-encoder to rescore
retrieved chunks before they reach the generator.

**Latency cost:** ~1–3 s (one generate call with short output on 1.2B model).

### 2.1 New Module: `scripts/lib/rerank.py`

```python
"""rerank — LLM-based reranking using the reasoning model."""

import json, re
from ollama import generate, REASONING_MODEL

def rerank(query: str, chunks: list[dict], *, top_k: int = 5) -> list[dict]:
    """Score each chunk's relevance to *query* using the thinking model.

    Returns the top_k chunks sorted by LLM-assigned relevance score.
    """
    numbered = "\n\n".join(
        f"[{i}] {c['chunk_text'][:800]}"
        for i, c in enumerate(chunks)
    )

    prompt = (
        "You are a relevance judge. Given the QUERY and numbered PASSAGES, "
        "return a JSON array of objects with 'index' (int) and 'score' "
        "(float 0-10) sorted by relevance. Only include passages scoring "
        "above 3. Be strict.\n\n"
        f"QUERY: {query}\n\n"
        f"PASSAGES:\n{numbered}\n\n"
        "Respond with ONLY valid JSON, no explanation."
    )

    raw = generate(
        prompt,
        model=REASONING_MODEL,
        temperature=0.1,
        num_predict=300,
        timeout=30,
    )

    # Strip <think> blocks, parse JSON
    clean = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    try:
        scores = json.loads(clean)
    except json.JSONDecodeError:
        # Fallback: return chunks in their original RRF order
        return chunks[:top_k]

    # Map scores back to chunks
    score_map = {s["index"]: s["score"] for s in scores if "index" in s}
    for i, c in enumerate(chunks):
        c["rerank_score"] = score_map.get(i, 0.0)

    reranked = sorted(chunks, key=lambda c: c["rerank_score"], reverse=True)
    return reranked[:top_k]
```

### 2.2 Integration Point

In `ai-chat.py`, between retrieval and prompt building:

```python
from rerank import rerank as llm_rerank

chunks = retrieve_with_chunks(conn, query, top_k=15, scope=scope)
chunks = llm_rerank(query, chunks, top_k=TOP_K)
prompt = build_prompt(query, chunks)
```

The wider initial retrieval (top_k=15) gives the reranker more candidates to
work with. It narrows back down to 5 before generation.

### 2.3 Config

```toml
[retrieval]
rerank_enabled = true
rerank_candidates = 15     # how many to fetch before reranking
```

When `rerank_enabled = false`, the pipeline skips Stage 2 and passes the
top-5 RRF results directly to generation (same as today's behavior).

---

## Stage 3 — Large-Model Generation (mostly unchanged)

The generation step in `ai-chat.py` stays largely as-is. The improvements
from Stages 1–2 mean the generator now sees higher-quality context, which
improves output even with no code changes.

### 3.1 Few-Shot Injection (from Exemplar Bank)

The one change is injecting the single most relevant past example from the
exemplar bank (Stage 5) into the prompt. This gives the model implicit
guidance on response tone, depth, and formatting:

```python
def build_prompt(query: str, chunks: list[dict],
                 exemplar: dict | None = None) -> str:
    # ... existing code ...

    # Inject best past example if available
    exemplar_block = ""
    if exemplar:
        exemplar_block = (
            "\n--- example of a good past answer ---\n"
            f"Q: {exemplar['query']}\n"
            f"A: {exemplar['answer'][:400]}\n"
            "--- end example ---\n"
        )

    return "\n".join([
        # ... existing system instructions ...
        exemplar_block,
        "--- question ---",
        query,
        # ... rest of prompt ...
    ])
```

### 3.2 Applies To All Tools

For tools that don't use retrieval (ai-commit, ai-pr, ai-cmd), the exemplar
bank still helps. Each tool can maintain its own exemplar category so that
`ai-cmd` learns from past command-generation successes independently.

---

## Stage 4 — Thinking-Model Verification

**Goal:** Catch hallucinated file paths, invented option names, and
unsupported claims before the answer reaches the user.

**Latency cost:** ~1–2 s (one generate call on 1.2B model with short output).

### 4.1 New Module: `scripts/lib/verify.py`

```python
"""verify — Post-generation grounding check using the reasoning model."""

import json, re
from ollama import generate, REASONING_MODEL

def verify(answer: str, chunks: list[dict], query: str) -> dict:
    """Check whether *answer* is grounded in the provided *chunks*.

    Returns:
        {
            "grounded": bool,
            "issues": ["list of flagged claims"],
            "confidence": float  # 0.0 – 1.0
        }
    """
    sources = "\n".join(
        f"[{c['filepath']}]: {c['chunk_text'][:600]}"
        for c in chunks
    )

    prompt = (
        "You are a fact-checker. Given the SOURCES and the ANSWER to a "
        "user's QUESTION, check if every claim in the answer is supported "
        "by the sources. Flag:\n"
        "- File paths mentioned in the answer that don't appear in sources\n"
        "- Config option names or values that aren't in the sources\n"
        "- Any claim that goes beyond what the sources say\n\n"
        f"QUESTION: {query}\n\n"
        f"SOURCES:\n{sources}\n\n"
        f"ANSWER:\n{answer}\n\n"
        "Respond with ONLY a JSON object: "
        '{"grounded": true/false, "issues": [...], "confidence": 0.0-1.0}'
    )

    raw = generate(
        prompt,
        model=REASONING_MODEL,
        temperature=0.1,
        num_predict=300,
        timeout=30,
    )

    clean = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    try:
        return json.loads(clean)
    except json.JSONDecodeError:
        return {"grounded": True, "issues": [], "confidence": 0.5}
```

### 4.2 Integration

In `ai-chat.py`, after generation:

```python
from verify import verify

result = verify(answer, chunks, query)
if not result["grounded"]:
    # Option A: Retry with tighter prompt
    # Option B: Append warning to output
    answer += f"\n\n(Note: some claims could not be verified against sources.)"
```

The verification result also feeds into the feedback store (Stage 5): a
grounded answer with high confidence is a positive signal, an ungrounded
answer is negative.

### 4.3 Config

```toml
[verification]
enabled = true
retry_on_failure = false    # if true, regenerate on failed verification
confidence_floor = 0.6      # below this, add a warning to the output
```

---

## Stage 5 — Feedback Learning Layer

**Goal:** Build a persistent memory that improves retrieval and generation
quality over time without retraining model weights. This is the "RNN-like"
recurrent structure — hidden state that accumulates and decays, influencing
future outputs.

### 5.1 Schema: Feedback Store

A new SQLite database at `~/.local/share/ai-search/feedback.db` (separate
from vectors.db to keep concerns isolated):

```sql
-- Every query that runs through the pipeline
CREATE TABLE query_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   REAL NOT NULL,           -- time.time()
    tool        TEXT NOT NULL,            -- 'ai-chat', 'ai-cmd', etc.
    query       TEXT NOT NULL,
    answer      TEXT,
    grounded    BOOLEAN,                 -- from Stage 4 verification
    confidence  REAL,                    -- from Stage 4
    feedback    INTEGER DEFAULT 0,       -- -1 negative, 0 neutral, +1 positive
    resolved    BOOLEAN DEFAULT FALSE    -- did user ask a follow-up? (FALSE = success signal)
);

-- Per-chunk utility score: EMA-updated over time
CREATE TABLE chunk_utility (
    chunk_rowid INTEGER PRIMARY KEY,     -- FK to file_metadata.rowid
    utility_ema REAL DEFAULT 0.5,        -- starts neutral
    hit_count   INTEGER DEFAULT 0,
    last_used   REAL NOT NULL
);

-- Best past (query, answer) pairs for few-shot injection
CREATE TABLE exemplar_bank (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    tool        TEXT NOT NULL,
    query       TEXT NOT NULL,
    answer      TEXT NOT NULL,
    score       REAL NOT NULL,           -- quality score (from verification confidence)
    embedding   BLOB,                    -- query embedding for similarity lookup
    created     REAL NOT NULL
);
```

### 5.2 Chunk Utility: Exponential Moving Average

The core learning mechanism. After each query:

```python
ALPHA = 0.3  # EMA decay factor — recent signals count 3x more than older ones

def update_chunk_utility(conn, chunk_rowids: list[int], signal: float):
    """Update the utility EMA for chunks that were used in a response.

    signal: +1.0 for grounded/accepted answers, -0.5 for ungrounded,
            -1.0 for explicit negative feedback.
    """
    now = time.time()
    cur = conn.cursor()
    for rid in chunk_rowids:
        cur.execute("SELECT utility_ema, hit_count FROM chunk_utility WHERE chunk_rowid = ?", (rid,))
        row = cur.fetchone()
        if row:
            old_ema, hits = row
            new_ema = ALPHA * signal + (1 - ALPHA) * old_ema
            cur.execute(
                "UPDATE chunk_utility SET utility_ema = ?, hit_count = ?, last_used = ? "
                "WHERE chunk_rowid = ?",
                (new_ema, hits + 1, now, rid),
            )
        else:
            cur.execute(
                "INSERT INTO chunk_utility (chunk_rowid, utility_ema, hit_count, last_used) "
                "VALUES (?, ?, 1, ?)",
                (rid, 0.5 + ALPHA * signal, now),
            )
    conn.commit()
```

These utility scores feed back into Stage 1's RRF fusion, where high-utility
chunks get a ranking boost and low-utility chunks are demoted. This creates
the recurrent loop: **use → evaluate → update state → influence next use**.

### 5.3 Implicit Feedback Signals

Since we don't want to force users to rate every answer, we derive feedback
from behavioral signals:

| Signal | Interpretation | Value |
|--------|---------------|-------|
| Verification passes (grounded=true, confidence>0.8) | Answer was accurate | +1.0 |
| Verification fails (grounded=false) | Answer hallucinated | -0.5 |
| User re-runs same query within 60s | First answer was unsatisfying | -0.3 |
| User asks a follow-up question | First answer was incomplete | -0.1 |
| User moves to a new topic | Answer was sufficient | +0.3 |
| Explicit thumbs-up (if UI supports it) | Strong positive | +1.0 |
| Explicit thumbs-down (if UI supports it) | Strong negative | -1.0 |

For CLI tools, "re-runs same query within 60s" and "moves to new topic"
are detectable by logging timestamps and comparing sequential queries.

### 5.4 Exemplar Bank

When a query gets high verification confidence (>0.85) and the answer is
concise, store it as an exemplar:

```python
def maybe_store_exemplar(conn, tool, query, answer, confidence, query_embedding):
    if confidence < 0.85 or len(answer) > 800:
        return
    # Check we don't already have a near-duplicate
    # (cosine similarity against stored exemplar embeddings)
    conn.execute(
        "INSERT INTO exemplar_bank (tool, query, answer, score, embedding, created) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (tool, query, answer, confidence, vec_to_bytes(query_embedding), time.time()),
    )
    # Keep bank small: retain only top-50 exemplars per tool
    conn.execute(
        "DELETE FROM exemplar_bank WHERE tool = ? AND id NOT IN "
        "(SELECT id FROM exemplar_bank WHERE tool = ? ORDER BY score DESC LIMIT 50)",
        (tool, tool),
    )
    conn.commit()
```

At generation time (Stage 3), retrieve the exemplar whose query embedding is
most similar to the current query:

```python
def get_best_exemplar(conn, tool, query_embedding, threshold=0.7):
    """Return the most relevant past exemplar, or None."""
    cur = conn.cursor()
    cur.execute(
        "SELECT query, answer, vec_distance_cosine(embedding, ?) as dist "
        "FROM exemplar_bank WHERE tool = ? ORDER BY dist LIMIT 1",
        (vec_to_bytes(query_embedding), tool),
    )
    row = cur.fetchone()
    if row and row[2] < threshold:
        return {"query": row[0], "answer": row[1]}
    return None
```

### 5.5 Temporal Decay

To prevent stale signals from dominating, apply time-based decay during
utility score reads:

```python
DECAY_HALFLIFE_DAYS = 30

def _load_utility_scores(conn) -> dict[int, float]:
    """Load chunk utility scores with temporal decay applied."""
    now = time.time()
    cur = conn.cursor()
    cur.execute("SELECT chunk_rowid, utility_ema, last_used FROM chunk_utility")
    scores = {}
    for rid, ema, last_used in cur.fetchall():
        age_days = (now - last_used) / 86400
        decay = 0.5 ** (age_days / DECAY_HALFLIFE_DAYS)
        # Decay toward neutral (0.5), not toward zero
        decayed = 0.5 + (ema - 0.5) * decay
        scores[rid] = decayed
    return scores
```

This means a chunk that was great 90 days ago but hasn't been used since
gradually returns to a neutral score, while recently validated chunks
maintain their boost.

---

## Implementation Status

All phases have been implemented. Below is the status and file manifest.

| Phase | Stage | Status | Files Modified/Created |
|-------|-------|--------|----------------------|
| **P1** | Hybrid BM25+Vector | **DONE** | `scripts/lib/embeddings.py` — FTS5 table, triggers, `bm25_search()`, `reciprocal_rank_fusion()`, refactored `retrieve_with_chunks()` |
| **P2** | Feedback schema + utility EMA | **DONE** | `scripts/lib/feedback.py` (new) — `query_log`, `chunk_utility`, `exemplar_bank` tables, EMA updates, temporal decay |
| **P3** | Thinking-model rerank | **DONE** | `scripts/lib/rerank.py` (new) — LLM-based reranking via reasoning model |
| **P4** | Verification | **DONE** | `scripts/lib/verify.py` (new) — post-generation grounding check |
| **P5** | Exemplar injection | **DONE** | Integrated into `scripts/search/ai-chat.py` `build_prompt()` |
| **P6** | Implicit feedback signals | **DONE** | `scripts/lib/feedback.py` — `detect_rerun()`, signal-based chunk utility updates |
| **—** | Config defaults | **DONE** | `scripts/lib/config.py` — `[retrieval]`, `[verification]`, `[learning]` sections |
| **—** | Bash tool integration | **DONE** | `scripts/lib/pipeline_post.py` (new) — stdin/stdout CLI for verify+feedback from bash scripts |

### New Files

```
scripts/lib/feedback.py       — Persistent learning layer (schema, EMA, exemplar bank)
scripts/lib/rerank.py          — LLM-based reranking module
scripts/lib/verify.py          — Post-generation grounding check
scripts/lib/pipeline_post.py   — CLI bridge for bash-based tools (ai-cmd, ai-commit, etc.)
```

### Modified Files

```
scripts/lib/embeddings.py      — FTS5 schema, hybrid retrieval, RRF fusion
scripts/lib/config.py          — New default sections for retrieval/verification/learning
scripts/search/ai-chat.py      — Full 5-stage pipeline integration
```

### Bash Tool Integration

The bash-based tools (ai-cmd, ai-explain, ai-commit, ai-pr) can call
`pipeline_post.py` as a post-generation step to get verification + feedback:

```bash
RESULT=$(echo "{\"tool\":\"ai-cmd\",\"query\":\"$QUERY\",\"answer\":\"$ANSWER\"}" \
    | python3 "$LIB_DIR/pipeline_post.py")
VERIFIED=$(echo "$RESULT" | jq -r '.verified')
EXEMPLAR=$(echo "$RESULT" | jq -r '.exemplar // empty')
```

### Test Results

- **91 / 103 tests pass** (12 failures are pre-existing sklearn dep, not regressions)
- All new modules import cleanly
- Config defaults verified
- RRF fusion, FTS sanitizer, chunk utility EMA all unit-tested

---

## Config Summary

All new settings, added to `~/.config/ai-scripts/config.toml`:

```toml
[retrieval]
bm25_enabled = true          # enable hybrid BM25 + vector search
rrf_k = 60                   # RRF fusion constant
rerank_enabled = true         # enable thinking-model reranking
rerank_candidates = 15        # candidates to fetch before reranking
utility_weight = 0.15         # how much learned utility boosts ranking

[verification]
enabled = true                # enable post-generation grounding check
retry_on_failure = false      # regenerate when verification fails
confidence_floor = 0.6        # warn user below this confidence

[learning]
enabled = true                # enable the feedback learning layer
alpha = 0.3                   # EMA decay factor (0 = no learning, 1 = no memory)
decay_halflife_days = 30      # temporal decay half-life
exemplar_threshold = 0.85     # minimum confidence to store an exemplar
max_exemplars_per_tool = 50   # cap on stored exemplars per tool
```

---

## How Tools Benefit

| Tool | Stages Used | Primary Benefit |
|------|------------|-----------------|
| **ai-chat** | 1 → 2 → 3 → 4 → 5 | Full pipeline: better retrieval, grounded answers, learning |
| **ai-search** | 1 + 5 (utility only) | Hybrid search finds exact matches; utility boosts proven chunks |
| **ai-cmd** | 3 → 4 → 5 | Verification catches invalid commands; exemplars teach style |
| **ai-explain** | 3 → 4 | Verification catches misattributed behavior |
| **ai-commit** | 3 → 5 | Exemplar bank learns the user's preferred commit style |
| **ai-pr** | 3 → 5 | Exemplar bank learns PR description format |
| **ai-organize** | 5 (utility only) | Better dedup accuracy as utility scores accumulate |
| **ai-narrative** | 3 → 5 | Exemplars teach narrative tone and structure |

---

## Measuring Impact

### Retrieval Quality

Track **Mean Reciprocal Rank (MRR)** on a held-out set of (query, known-good-file)
pairs. Compare MRR before and after each stage:

```python
def mrr(queries_and_targets, retrieval_fn):
    """Compute MRR over a list of (query, target_filepath) pairs."""
    reciprocals = []
    for query, target in queries_and_targets:
        results = retrieval_fn(query)
        for i, r in enumerate(results):
            if r["filepath"] == target:
                reciprocals.append(1.0 / (i + 1))
                break
        else:
            reciprocals.append(0.0)
    return sum(reciprocals) / len(reciprocals)
```

### Generation Quality

Track from the feedback store:

- **Grounding rate**: % of answers that pass verification (target: >90%)
- **Retry rate**: % of queries where the user re-runs within 60s (target: <10%)
- **Utility drift**: average chunk utility EMA over time (should trend upward)

### Latency

Log wall-clock time per stage in `query_log`. Target total pipeline latency
(all stages enabled) under 8 seconds on Apple Silicon.
