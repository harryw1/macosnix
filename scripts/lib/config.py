"""config — Unified configuration for the ai-* script suite.

Reads ``~/.config/ai-scripts/config.toml`` (if present) and provides a
``load_config()`` function that returns a flat dict of typed values with
sensible defaults.

Precedence (highest → lowest):
    1. Environment variables (``OLLAMA_MODEL``, ``OLLAMA_MODEL_EMBED``, etc.)
    2. Config file values
    3. Hardcoded defaults

Also provides ``get(section, key, default)`` for quick single-value lookups,
and a ``CONFIG_PATH`` constant for the config file location.

Not meant to be run standalone — but *can* be invoked as a CLI helper for
bash scripts:

    python3 config.py models chat "fallback"
    → prints the resolved value for [models].chat
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

# ── Config path ───────────────────────────────────────────────────────────────

XDG_CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
CONFIG_DIR = Path(XDG_CONFIG_HOME) / "ai-scripts"
CONFIG_PATH = CONFIG_DIR / "config.toml"

# ── Defaults ──────────────────────────────────────────────────────────────────
# Every configurable value lives here so there's exactly one place to change
# a default.  The dict mirrors the TOML structure.

DEFAULTS: dict[str, dict[str, Any]] = {
    "models": {
        "chat": "qwen3.5:9b",
        "embed": "qwen3-embedding:0.6b",
        "reasoning": "lfm2.5-thinking:1.2b",
    },
    "search": {
        "top_k": 5,
        "threshold": 0.8,
    },
    "organize": {
        "dupe_threshold": 0.12,
        "hdbscan_min_cluster": 3,
        "composite_alpha": 0.65,
    },
}

# ── Env-var overrides ─────────────────────────────────────────────────────────
# Maps (section, key) → env var name.  Only values with an established env-var
# convention get an entry here.

_ENV_OVERRIDES: dict[tuple[str, str], str] = {
    ("models", "chat"): "OLLAMA_MODEL",
    ("models", "embed"): "OLLAMA_MODEL_EMBED",
    ("models", "reasoning"): "OLLAMA_MODEL_REASON",
}

# ── Internal cache ────────────────────────────────────────────────────────────

_config_cache: dict[str, dict[str, Any]] | None = None


def _parse_toml(path: Path) -> dict[str, Any]:
    """Parse a TOML file, using stdlib tomllib (3.11+) or the tomli backport."""
    text = path.read_text(encoding="utf-8")
    try:
        import tomllib  # Python 3.11+
        return tomllib.loads(text)
    except ModuleNotFoundError:
        pass
    try:
        import tomli  # backport for 3.10
        return tomli.loads(text)
    except ModuleNotFoundError:
        # Last resort: hand-parse a flat TOML subset (section headers + key = value)
        return _parse_toml_simple(text)


def _parse_toml_simple(text: str) -> dict[str, Any]:
    """Minimal TOML parser that handles the subset we actually use.

    Supports: section headers, string values (quoted), numeric values (int/float),
    and boolean values.  No arrays, inline tables, or multiline strings.
    """
    config: dict[str, dict[str, Any]] = {}
    section = ""
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            config.setdefault(section, {})
            continue
        if "=" in line:
            key, _, raw = line.partition("=")
            key = key.strip()
            raw = raw.strip()
            # Strip inline comments
            if " #" in raw:
                raw = raw[:raw.index(" #")].strip()
            # Parse value
            if (raw.startswith('"') and raw.endswith('"')) or \
               (raw.startswith("'") and raw.endswith("'")):
                val: Any = raw[1:-1]
            elif raw.lower() in ("true", "false"):
                val = raw.lower() == "true"
            elif "." in raw:
                try:
                    val = float(raw)
                except ValueError:
                    val = raw
            else:
                try:
                    val = int(raw)
                except ValueError:
                    val = raw
            config.setdefault(section, {})[key] = val
    return config


def load_config() -> dict[str, dict[str, Any]]:
    """Load the merged config: defaults ← file ← env overrides.

    Returns a nested dict matching the TOML structure.  Results are cached
    for the lifetime of the process.
    """
    global _config_cache
    if _config_cache is not None:
        return _config_cache

    # Start with defaults (deep copy)
    merged: dict[str, dict[str, Any]] = {
        section: dict(values) for section, values in DEFAULTS.items()
    }

    # Layer on config file
    if CONFIG_PATH.is_file():
        try:
            file_cfg = _parse_toml(CONFIG_PATH)
            for section, values in file_cfg.items():
                if isinstance(values, dict):
                    merged.setdefault(section, {}).update(values)
        except Exception as e:
            print(f"Warning: could not parse {CONFIG_PATH}: {e}", file=sys.stderr)

    # Layer on env-var overrides
    for (section, key), env_var in _ENV_OVERRIDES.items():
        env_val = os.environ.get(env_var)
        if env_val is not None:
            merged.setdefault(section, {})[key] = env_val

    _config_cache = merged
    return merged


def get(section: str, key: str, default: Any = None) -> Any:
    """Look up a single config value with full precedence resolution."""
    cfg = load_config()
    return cfg.get(section, {}).get(key, default)


def save_config(config: dict[str, dict[str, Any]]) -> None:
    """Write a config dict to the TOML file.

    Only writes sections/keys that differ from DEFAULTS, to keep the file
    minimal and forward-compatible.
    """
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    lines: list[str] = [
        "# ai-scripts configuration",
        "# Generated by ai-config. Edit freely; env vars override these values.",
        "",
    ]

    for section in sorted(config.keys()):
        values = config[section]
        if not isinstance(values, dict) or not values:
            continue
        lines.append(f"[{section}]")
        for key in sorted(values.keys()):
            val = values[key]
            if isinstance(val, str):
                lines.append(f'{key} = "{val}"')
            elif isinstance(val, bool):
                lines.append(f"{key} = {'true' if val else 'false'}")
            elif isinstance(val, (int, float)):
                lines.append(f"{key} = {val}")
            else:
                lines.append(f'{key} = "{val}"')
        lines.append("")

    CONFIG_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ── CLI helper for bash scripts ───────────────────────────────────────────────

if __name__ == "__main__":
    # Usage: python3 config.py <section> <key> [default]
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <section> <key> [default]", file=sys.stderr)
        sys.exit(1)

    section = sys.argv[1]
    key = sys.argv[2]
    fallback = sys.argv[3] if len(sys.argv) > 3 else ""

    result = get(section, key, fallback)
    print(result)
