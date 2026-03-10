#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "sqlite-vec",
#     "requests",
#     "pypdf",
#     "python-docx",
#     "openpyxl",
# ]
# ///
import argparse
import json
import sys
from pathlib import Path

# ── Import shared library ─────────────────────────────────────────────────────
import os
_lib = os.environ.get("AI_LIB_PATH") or str(Path(__file__).resolve().parent.parent / "lib")
sys.path.insert(0, _lib)
from embeddings import (
    init_db,
    clear_db,
    get_status,
    index_directory,
    search,
    check_dir_indexed,
)


def main():
    parser = argparse.ArgumentParser(description="Local Semantic Search Python Backend")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--index", metavar="DIR", help="Directory to recursively index")
    group.add_argument("--search", metavar="QUERY", help="Semantic search query")
    group.add_argument("--status", action="store_true", help="Print database statistics as JSON")
    group.add_argument("--clear", action="store_true", help="Delete the vector database")
    group.add_argument("--check-dir", metavar="DIR", help="Check if directory is indexed (exits 0 if true, 1 if false)")

    args = parser.parse_args()

    if args.clear:
        clear_db()
        sys.exit(0)

    # All other commands require the database connection
    conn = init_db()

    if args.status:
        print(json.dumps(get_status(conn)))
    elif args.index:
        index_directory(conn, args.index)
    elif args.search:
        results = search(conn, args.search)
        print(json.dumps(results))
    elif args.check_dir:
        if check_dir_indexed(conn, args.check_dir):
            conn.close()
            sys.exit(0)
        else:
            conn.close()
            sys.exit(1)

    conn.close()


if __name__ == "__main__":
    main()
