#!/usr/bin/env python3
"""Convert `aapt2 dump xmltree` text back to ordinary XML.
This is intentionally small and handles the CarrierConfig vendor.xml grammar.
"""
import argparse, re
from pathlib import Path
from xml.etree import ElementTree as ET

E_RE = re.compile(r'^(\s*)E: ([^ ]+)(?: \(line=\d+\))?\s*$')
A_RAW_RE = re.compile(r'^(\s*)A: ([^=]+)=.* \(Raw: "(.*)"\)\s*$')
A_EMPTY_RE = re.compile(r'^(\s*)A: ([^=]+)=""\s*$')
T_RE = re.compile(r"^(\s*)T: '(.*)'\s*$")

def parse(path: Path) -> ET.Element:
    root = None
    stack = []  # (indent, element)
    for lineno, line in enumerate(path.read_text(errors='strict').splitlines(), 1):
        m = E_RE.match(line)
        if m:
            indent, tag = len(m.group(1)), m.group(2)
            while stack and stack[-1][0] >= indent:
                stack.pop()
            elem = ET.Element(tag)
            if stack:
                stack[-1][1].append(elem)
            elif root is None:
                root = elem
            else:
                raise ValueError(f"line {lineno}: multiple roots")
            stack.append((indent, elem))
            continue
        m = A_RAW_RE.match(line)
        if m:
            if not stack: raise ValueError(f"line {lineno}: attribute without element")
            stack[-1][1].set(m.group(2), m.group(3))
            continue
        m = A_EMPTY_RE.match(line)
        if m:
            if not stack: raise ValueError(f"line {lineno}: attribute without element")
            stack[-1][1].set(m.group(2), "")
            continue
        m = T_RE.match(line)
        if m:
            if not stack: raise ValueError(f"line {lineno}: text without element")
            # aapt2 surrounds text nodes with spaces in its dump. Preserve them.
            stack[-1][1].text = m.group(2)
            continue
        if line.strip():
            raise ValueError(f"line {lineno}: unsupported dump syntax: {line!r}")
    if root is None: raise ValueError("empty input")
    return root

def indent_xml(elem, level=0):
    pad = "    " * level
    if len(elem):
        if elem.text is None or not elem.text.strip(): elem.text = "\n" + "    " * (level + 1)
        for i, child in enumerate(elem):
            indent_xml(child, level + 1)
            child.tail = "\n" + ("    " * (level + 1) if i + 1 < len(elem) else pad)
    elif elem.text is None:
        elem.text = None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('input', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    root = parse(args.input)
    indent_xml(root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(args.output, encoding='utf-8', xml_declaration=True, short_empty_elements=True)

if __name__ == '__main__': main()
