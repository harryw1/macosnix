"""rerank — LLM-based reranking using the reasoning model.

After hybrid retrieval returns a broad candidate set, this module uses the
small thinking model (lfm2.5-thinking:1.2b by default) to score each chunk's
relevance to the query.  This acts as a lightweight cross-encoder that catches
semantic relevance that neither embeddings nor keywords capture well.

Not meant to be run standalone.
"""

from __future__ import annotations

import json
import re
import sys

from config import get as _cfg
from ollama import generate, REASONING_MODEL


def rerank(
    query: str,
    chunks: list[dict],
    *,
    top_k: int = 5,
    model: str | None = None,
) -> list[dict]:
    """Score each chunk's relevance to *query* using the thinking model.

    Parameters
    ----------
    query : str
        The user's search query.
    chunks : list[dict]
        Candidate chunks from hybrid retrieval.  Each must have 'chunk_text'.
    top_k : int
        Number of top-scoring chunks to return.
    model : str, optional
        Override the reasoning model (defaults to REASONING_MODEL).

    Returns the top_k chunks sorted by LLM-assigned relevance score.
    Falls back to the original ordering if JSON parsing fails.
    """
    if not chunks:
        return []

    if len(chunks) <= top_k:
        return chunks

    # Build numbered passage list (truncate each to save context)
    numbered = "\n\n".join(
        f"[{i}] {c.get('chunk_text', c.get('snippet', ''))[:800]}"
        for i, c in enumerate(chunks)
    )

    prompt = (
        "You are a relevance judge. Given the QUERY and numbered PASSAGES below, "
        "return a JSON array of objects with 'index' (int) and 'score' (float 0-10) "
        "sorted by relevance. Only include passages scoring above 3. Be strict — "
        "a passage must directly help answer the query to score above 5.\n\n"
        f"QUERY: {query}\n\n"
        f"PASSAGES:\n{numbered}\n\n"
        "Respond with ONLY valid JSON. No explanation, no markdown fences."
    )

    try:
        raw = generate(
            prompt,
            model=model or REASONING_MODEL,
            temperature=0.1,
            num_predict=400,
            timeout=30,
        )
    except SystemExit:
        # generate() calls sys.exit on HTTP errors — catch and fall back
        print("rerank: Ollama generate failed, falling back to original order.",
              file=sys.stderr)
        return chunks[:top_k]

    # Strip <think>…</think> blocks the reasoning model may emit
    clean = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()

    # Try to extract JSON from the response (handle markdown fences)
    json_match = re.search(r"\[.*\]", clean, flags=re.DOTALL)
    if json_match:
        clean = json_match.group()

    try:
        scores = json.loads(clean)
    except json.JSONDecodeError:
        # Fallback: return chunks in their original RRF/vector order
        print("rerank: Could not parse JSON from reasoning model, "
              "falling back to original order.", file=sys.stderr)
        return chunks[:top_k]

    # Validate and map scores back to chunks
    score_map: dict[int, float] = {}
    for entry in scores:
        if isinstance(entry, dict) and "index" in entry and "score" in entry:
            idx = entry["index"]
            if isinstance(idx, int) and 0 <= idx < len(chunks):
                score_map[idx] = float(entry["score"])

    for i, c in enumerate(chunks):
        c["rerank_score"] = score_map.get(i, 0.0)

    reranked = sorted(chunks, key=lambda c: c.get("rerank_score", 0.0), reverse=True)
    return reranked[:top_k]
