#!/usr/bin/env python3

import re
import sys
from pathlib import Path


ASSIGN_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_$]*)\s*(?:<=|=(?!=))")
WIRE_DECL_RE = re.compile(
    r"^(?P<indent>\s*)wire(?P<body>\s+(?:signed\s+)?(?:\[[^]]+\]\s+)?)(?P<name>[A-Za-z_][A-Za-z0-9_$]*)"
    r"(?P<tail>\s*;.*)$"
)
OUTPUT_DECL_RE = re.compile(
    r"^(?P<indent>\s*)output\s+wire(?P<body>\s+(?:signed\s+)?(?:\[[^]]+\]\s+)?)(?P<name>[A-Za-z_][A-Za-z0-9_$]*)"
    r"(?P<tail>\s*;.*)$"
)


def sanitize_text(text: str) -> str:
    driven = set(ASSIGN_RE.findall(text))
    out_lines = []
    for line in text.splitlines():
        match = WIRE_DECL_RE.match(line)
        if match and match.group("name") in driven:
            line = (
                f"{match.group('indent')}reg"
                f"{match.group('body')}{match.group('name')}{match.group('tail')}"
            )
        else:
            match = OUTPUT_DECL_RE.match(line)
            if match and match.group("name") in driven:
                line = (
                    f"{match.group('indent')}output reg"
                    f"{match.group('body')}{match.group('name')}{match.group('tail')}"
                )
        out_lines.append(line)
    return "\n".join(out_lines) + ("\n" if text.endswith("\n") else "")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sanitize_iverilog_verilog.py <input.v> <output.v>", file=sys.stderr)
        return 1

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    dst.write_text(sanitize_text(src.read_text()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
