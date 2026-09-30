#!/usr/bin/env python3
"""Convert ANSI-escaped terminal output to an SVG image.

Usage: ansi2svg.py IN.ansi [OUT.svg]

Handles the SGR sequences tmux emits from `capture-pane -e` (reset, bold,
default fg/bg and 256-colour fg/bg). Intended for README screenshots of the
dui-redis TUI.
"""
import re
import sys

DEFAULT_FG = "#d4d4d4"
DEFAULT_BG = "#1e1e1e"
FONT = "Menlo, Consolas, 'DejaVu Sans Mono', monospace"
CHAR_W = 8.4
LINE_H = 17
PAD = 12

SGR = re.compile(r"\x1b\[([0-9;]*)m")

BASE16 = [
    (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
    (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
    (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
]


def xterm_rgb(n):
    n = int(n)
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        vals = (n // 36, (n % 36) // 6, n % 6)
        return tuple(0 if v == 0 else 55 + v * 40 for v in vals)
    v = 8 + (n - 232) * 10
    return (v, v, v)


def hexc(rgb):
    return "#%02x%02x%02x" % rgb


def apply_sgr(codes, fg, bg, bold):
    side = [int(c) if c else 0 for c in codes.split(";")]
    i = 0
    while i < len(side):
        c = side[i]
        if c == 0:
            fg, bg, bold = None, None, False
        elif c == 1:
            bold = True
        elif c == 22:
            bold = False
        elif c == 39:
            fg = None
        elif c == 49:
            bg = None
        elif c == 38 and i + 2 < len(side) and side[i + 1] == 5:
            fg = side[i + 2]
            i += 2
        elif c == 48 and i + 2 < len(side) and side[i + 1] == 5:
            bg = side[i + 2]
            i += 2
        i += 1
    return fg, bg, bold


def parse(text):
    lines = []
    for raw in text.split("\n"):
        runs = []
        fg, bg, bold = None, None, False
        pos = 0
        buf = ""
        for m in SGR.finditer(raw):
            buf += raw[pos:m.start()]
            if buf:
                runs.append((buf, fg, bg, bold))
                buf = ""
            fg, bg, bold = apply_sgr(m.group(1), fg, bg, bold)
            pos = m.end()
        buf += raw[pos:]
        if buf:
            runs.append((buf, fg, bg, bold))
        lines.append(runs)
    while lines and not any(t for t, *_ in lines[-1]):
        lines.pop()
    return lines


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def to_svg(lines):
    ncols = max((sum(len(t) for t, *_ in r) for r in lines), default=1)
    nrows = max(len(lines), 1)
    width = int(PAD * 2 + CHAR_W * ncols)
    height = int(PAD * 2 + LINE_H * nrows)
    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" font-family="%s" font-size="14">'
        % (width, height, width, height, FONT),
        '<rect width="%d" height="%d" fill="%s"/>' % (width, height, DEFAULT_BG),
    ]
    for row, runs in enumerate(lines):
        y_top = PAD + LINE_H * row
        baseline = y_top + LINE_H - 4
        col = 0
        for text, fg, bg, bold in runs:
            if not text:
                continue
            x = PAD + CHAR_W * col
            if bg is not None:
                out.append(
                    '<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="%s"/>'
                    % (x, y_top, CHAR_W * len(text), LINE_H, hexc(xterm_rgb(bg)))
                )
            fill = hexc(xterm_rgb(fg)) if fg is not None else DEFAULT_FG
            weight = "bold" if bold else "normal"
            out.append(
                '<text x="%.1f" y="%.1f" fill="%s" font-weight="%s" '
                'xml:space="preserve">%s</text>' % (x, baseline, fill, weight, esc(text))
            )
            col += len(text)
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main(argv):
    src = sys.argv[1]
    with open(src, "r", encoding="utf-8") as fh:
        text = fh.read()
    svg = to_svg(parse(text))
    if len(argv) > 2:
        with open(argv[2], "w", encoding="utf-8") as fh:
            fh.write(svg)
    else:
        sys.stdout.write(svg)


if __name__ == "__main__":
    main(sys.argv)
