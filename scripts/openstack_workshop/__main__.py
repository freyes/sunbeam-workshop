"""CLI entry point: ``python -m openstack_workshop vars|repos ...``."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .loader import DocError
from .vars import VarsError, build_vars, find_root


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "repos":
        from . import repos

        return repos.main(argv[1:])
    parser = argparse.ArgumentParser(prog="openstack_workshop")
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
        except DocError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        json.dump(doc, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    parser.error(f"unknown command {args.command!r}")  # pragma: no cover
    return 2  # pragma: no cover


if __name__ == "__main__":
    sys.exit(main())
