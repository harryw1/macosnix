"""verify — Post-generation grounding check using the reasoning model.

After the large model generates an answer from retrieved chunks, this module
uses the small thinking model to verify that every claim in the answer is
supported by the source chunks.  Catches hallucinated file paths, invented
option names, and unsupported assertions.

Not meant to be run standalone.
"""

from __future__ import annotations

import json
import re
import sys

from config import get as _cfg
from ollama import generate, REASONING_MODEL


def verify(
    answer: str,
    chunks: list[dict],
    query: str,
    *,
    model: str | None = None,
) -> dict:
    """Check whether *answer* is grounded in the provided *chunks*.

    Parameters
    ----------
    answer : str
        The generated answer to verify.
    chunks : list[dict]
        The source chunks that were used to generate the answer.
    query : str
        The original user query (for context).
    model : str, optional
        Override the reasoning model.

    Returns
    -------
    dict with keys:
        grounded : bool
            True if all claims are supported by the sources.
        issues : list[str]
            Specific claims that couldn't be verified.
        confidence : float
            Overall confidence score (0.0 – 1.0).
    """
    if not answer or not chunks:
        return {"grounded": True, "issues": [], "confidence": 0.5}

    sources = "\n".join(
        f"[{c['filepath']}]: {c.get('chunk_text', c.get('snippet', ''))[:600]}"
        for c in chunks
    )

    prompt = (
        "You are a fact-checker. Given the SOURCES and the ANSWER to a user's "
        "QUESTION, check if every claim in the answer is supported by the sources.\n"
        "Flag:\n"
        "- File paths mentioned in the answer that don't appear in sources\n"
        "- Config option names or values that aren't in the sources\n"
        "- Any claim that goes beyond what the sources say\n"
        "- Invented or guessed information\n\n"
        f"QUESTION: {query}\n\n"
        f"SOURCES:\n{sources}\n\n"
        f"ANSWER:\n{answer}\n\n"
        "Respond with ONLY a JSON object (no markdown fences): "
        '{"grounded": true/false, "issues": ["issue1", ...], "confidence": 0.0-1.0}\n'
        "If the answer is fully grounded, issues should be an empty array and "
        "confidence should be high (0.8+)."
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
        print("verify: Ollama generate failed, assuming grounded.",
              file=sys.stderr)
        return {"grounded": True, "issues": [], "confidence": 0.5}

    # Strip <think>…</think> blocks
    clean = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()

    # Try to extract JSON object from the response
    json_match = re.search(r"\{.*\}", clean, flags=re.DOTALL)
    if json_match:
        clean = json_match.group()

    try:
        result = json.loads(clean)
    except json.JSONDecodeError:
        print("verify: Could not parse JSON from reasoning model.",
              file=sys.stderr)
        return {"grounded": True, "issues": [], "confidence": 0.5}

    # Normalise the result to ensure expected keys exist
    return {
        "grounded": bool(result.get("grounded", True)),
        "issues": list(result.get("issues", [])),
        "confidence": float(result.get("confidence", 0.5)),
    }
