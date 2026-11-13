"""CLI entry point: ``python -m sunbeam_workshop vars <name>``."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .vars import VarsError, build_vars, find_root


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="sunbeam_workshop")
    subparsers = parser.add_subparsers(dest="command", required=True)
    vars_parser = subparsers.add_parser(
        "vars", help="emit the merged vars doc for workshop NAME as JSON"
    )
    vars_parser.add_argument("name", metavar="NAME")
    args = parser.parse_args(argv)

    if args.command == "vars":
        try:
            doc = build_vars(find_root(Path.cwd()), args.name)
        except VarsError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return exc.exit_code
        json.dump(doc, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    parser.error(f"unknown command {args.command!r}")  # pragma: no cover
    return 2  # pragma: no cover


if __name__ == "__main__":
    sys.exit(main())
