"""CLI entry point: ``python -m sunbeam_workshop vars|repos ...``."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .loader import DocError
from .uservars import UserVarsError
from .vars import VarsError, build_vars_full, find_root


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "repos":
        from . import repos

        return repos.main(argv[1:])
    parser = argparse.ArgumentParser(prog="sunbeam_workshop")
    subparsers = parser.add_subparsers(dest="command", required=True)
    vars_parser = subparsers.add_parser(
        "vars", help="emit the merged vars doc for workshop NAME as JSON"
    )
    vars_parser.add_argument("name", metavar="NAME")
    args = parser.parse_args(argv)

    if args.command == "vars":
        try:
            result = build_vars_full(find_root(Path.cwd()), args.name)
        except VarsError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return exc.exit_code
        except (DocError, UserVarsError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        # stdout stays pure JSON (render.sh and setup.sh parse it); every
        # diagnostic goes to stderr only (sequencing trap 5).
        json.dump(result.doc, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        for warning in result.warnings:
            print(f"warning: {warning}", file=sys.stderr)
        diff = result.chain_diff
        print(
            f"layers: {result.layers_applied} applied; "
            f"sdks +{len(diff.added)} ~{len(diff.overridden)} "
            f"-{len(diff.removed)}; actions +{result.actions_added}",
            file=sys.stderr,
        )
        return 0
    parser.error(f"unknown command {args.command!r}")  # pragma: no cover
    return 2  # pragma: no cover


if __name__ == "__main__":
    sys.exit(main())
