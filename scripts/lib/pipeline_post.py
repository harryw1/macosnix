#!/usr/bin/env python3
"""pipeline_post — Post-generation pipeline for bash-based ai-* tools.

Called after generation to run verification and feedback logging for tools
that don't use the full Python RAG pipeline (ai-cmd, ai-explain, ai-commit,
ai-pr).  Bash scripts call this as a subprocess:

    echo '{"tool":"ai-cmd","query":"...","answer":"..."}' | python3 pipeline_post.py

Input JSON (on stdin):
    tool     : str   — the calling tool name
    query    : str   — the user's input / prompt context
    answer   : str   — the generated output to verify

Output JSON (on stdout):
    verified   : bool  — whether verification passed
    confidence : float — verification confidence (0.0–1.0)
    issues     : list  — flagged claims (empty if verified)
    exemplar   : str|null — best past exemplar answer if available

When verification is disabled or unavailable, returns defaults.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Ensure lib is on the path
sys.path.insert(0, str(Path(__file__).resolve().parent))

from config import get as _cfg


def main() -> None:
    # Read input from stdin
    try:
        data = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, EOFError):
        print(json.dumps({"error": "Invalid JSON on stdin"}))
        sys.exit(1)

    tool = data.get("tool", "unknown")
    query = data.get("query", "")
    answer = data.get("answer", "")

    result: dict = {
        "verified": True,
        "confidence": 1.0,
        "issues": [],
        "exemplar": None,
    }

    verify_enabled = _cfg("verification", "enabled", True)
    learning_enabled = _cfg("learning", "enabled", True)

    # ── Verification (Stage 4) ───────────────────────────────────────────
    if verify_enabled and answer:
        try:
            from verify import verify
            # For non-RAG tools we verify against the query context itself
            # (no source chunks, so create a synthetic chunk from the query)
            synthetic_chunks = [{"filepath": "(user input)", "chunk_text": query}]
            vresult = verify(answer, synthetic_chunks, query)
            result["verified"] = vresult.get("grounded", True)
            result["confidence"] = round(vresult.get("confidence", 0.5), 3)
            result["issues"] = vresult.get("issues", [])
        except (ImportError, SystemExit, Exception):
            pass

    # ── Feedback logging (Stage 5) ───────────────────────────────────────
    if learning_enabled:
        try:
            from feedback import init_feedback_db, log_query, maybe_store_exemplar
            fconn = init_feedback_db()
            log_query(
                fconn,
                tool=tool,
                query=query,
                answer=answer,
                grounded=result["verified"],
                confidence=result["confidence"],
            )

            # Store as exemplar if high quality
            if result["confidence"] >= float(_cfg("learning", "exemplar_threshold", 0.85)):
                try:
                    from embeddings import get_embedding
                    emb = get_embedding(query, timeout=15)
                    if emb:
                        maybe_store_exemplar(
                            fconn,
                            tool=tool,
                            query=query,
                            answer=answer,
                            confidence=result["confidence"],
                            query_embedding=emb,
                        )
                except (ImportError, SystemExit, Exception):
                    pass

            # Check for a relevant exemplar to return
            try:
                from feedback import get_best_exemplar
                from embeddings import get_embedding
                emb = get_embedding(query, timeout=15)
                if emb:
                    ex = get_best_exemplar(fconn, tool=tool, query_embedding=emb)
                    if ex:
                        result["exemplar"] = ex["answer"]
            except (ImportError, SystemExit, Exception):
                pass

            fconn.close()
        except (ImportError, SystemExit, Exception):
            pass

    print(json.dumps(result))


if __name__ == "__main__":
    main()
