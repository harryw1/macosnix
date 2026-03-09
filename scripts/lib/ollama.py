"""ollama — Thin Python client for the Ollama HTTP API.

Provides ``generate()`` for text generation and ``embed()`` for embedding
vectors, with consistent error handling across all ai-* scripts.

Not meant to be run standalone.
"""

from __future__ import annotations

import os
import sys
from typing import Any

import requests

from config import get as _cfg

# ── Configuration ─────────────────────────────────────────────────────────────

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")

# Precedence: env var → config file → hardcoded default.
# _cfg() handles the config-file + default layers; os.environ.get adds the env layer.
CHAT_MODEL = os.environ.get("OLLAMA_MODEL") or _cfg("models", "chat", "qwen3.5:9b")
EMBED_MODEL = os.environ.get("OLLAMA_MODEL_EMBED") or _cfg("models", "embed", "qwen3-embedding:0.6b")
REASONING_MODEL = os.environ.get("OLLAMA_MODEL_REASON") or _cfg("models", "reasoning", "lfm2.5-thinking:1.2b")


# ── Generation ────────────────────────────────────────────────────────────────

def generate(
    prompt: str,
    *,
    model: str | None = None,
    system: str | None = None,
    temperature: float = 0.3,
    num_predict: int = 600,
    num_ctx: int | None = None,
    think: bool = False,
    keep_alive: int | None = None,
    stream: bool = False,
    timeout: int = 120,
) -> str:
    """Send *prompt* to Ollama's generate endpoint and return the response text.

    Parameters
    ----------
    model : str, optional
        Override the default CHAT_MODEL.
    system : str, optional
        System prompt prepended to the conversation.
    temperature : float
        Sampling temperature. ai-chat uses 0.3, ai-organize uses 0.15.
    num_predict : int
        Maximum tokens to generate. ai-chat uses 600, ai-organize uses 8192.
    num_ctx : int, optional
        Context window size. Omitted if None (uses model default).
    think : bool
        Whether to enable chain-of-thought. Usually False to suppress
        ``<think>`` blocks on qwen3 models.
    keep_alive : int, optional
        If set, passed to Ollama (e.g. -1 to pin model in VRAM).
    stream : bool
        Whether to stream the response. Default False.
    timeout : int
        HTTP request timeout in seconds.
    """
    payload: dict[str, Any] = {
        "model": model or CHAT_MODEL,
        "prompt": prompt,
        "stream": stream,
        "think": think,
        "options": {
            "temperature": temperature,
            "num_predict": num_predict,
        },
    }
    if system is not None:
        payload["system"] = system
    if num_ctx is not None:
        payload["options"]["num_ctx"] = num_ctx
    if keep_alive is not None:
        payload["keep_alive"] = keep_alive

    url = f"{OLLAMA_BASE_URL}/api/generate"
    try:
        resp = requests.post(url, json=payload, timeout=timeout)
        resp.raise_for_status()
        return resp.json().get("response", "").strip()
    except requests.exceptions.RequestException as e:
        print(f"Error calling Ollama generate: {e}", file=sys.stderr)
        sys.exit(1)


# ── Embedding ─────────────────────────────────────────────────────────────────

def embed(
    text: str,
    *,
    model: str | None = None,
    timeout: int = 10,
    keep_alive: int | None = None,
) -> list[float]:
    """Fetch the embedding vector from Ollama for *text*.

    Parameters
    ----------
    model : str, optional
        Override the default EMBED_MODEL.
    timeout : int
        HTTP request timeout in seconds. ai-search uses 10, ai-chat 30,
        ai-organize 120.
    keep_alive : int, optional
        If set, passed to Ollama's ``keep_alive`` parameter (e.g. -1 to pin
        the model in memory).
    """
    payload: dict[str, Any] = {
        "model": model or EMBED_MODEL,
        "prompt": text,
    }
    if keep_alive is not None:
        payload["keep_alive"] = keep_alive

    url = f"{OLLAMA_BASE_URL}/api/embeddings"
    try:
        resp = requests.post(url, json=payload, timeout=timeout)
        resp.raise_for_status()
        return resp.json().get("embedding", [])
    except requests.exceptions.RequestException as e:
        print(f"Error fetching embedding from Ollama: {e}", file=sys.stderr)
        sys.exit(1)


# ── Health check & model listing ──────────────────────────────────────────────

def is_running(timeout: int = 2) -> bool:
    """Return True if Ollama is responding on its API port."""
    try:
        resp = requests.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=timeout)
        return resp.status_code == 200
    except requests.exceptions.RequestException:
        return False


def list_models(timeout: int = 5) -> list[dict[str, Any]]:
    """Return a list of locally installed models from Ollama.

    Each dict has at least: name, size, modified_at, parameter_size, family.
    Returns an empty list if Ollama isn't running.
    """
    try:
        resp = requests.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=timeout)
        resp.raise_for_status()
        return resp.json().get("models", [])
    except requests.exceptions.RequestException:
        return []
