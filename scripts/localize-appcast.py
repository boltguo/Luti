#!/usr/bin/env python3
"""Embed every translation of docs/release-<version>.md in that version's appcast item.

Usage: scripts/localize-appcast.py appcast.xml 1.4.0

Sparkle shows the description whose xml:lang best matches the system languages.
Run it after each generate_appcast run, which rewrites only the first description.
"""
import pathlib
import re
import sys

LANGUAGES = ["en", "zh-Hans", "ja"]

appcast, version = pathlib.Path(sys.argv[1]), sys.argv[2]
docs = pathlib.Path(__file__).resolve().parent.parent / "docs"


def description(language):
    name = f"release-{version}.md" if language == "en" else f"release-{version}.{language}.md"
    text = (docs / name).read_text(encoding="utf-8")
    if "]]>" in text:
        sys.exit(f"{name} must not contain ']]>'.")
    return f'<description xml:lang="{language}" sparkle:format="markdown"><![CDATA[{text}]]></description>'


xml = appcast.read_text(encoding="utf-8")
items = [m for m in re.finditer(r"<item>.*?</item>", xml, re.S)
         if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in m.group()]
if len(items) != 1:
    sys.exit(f"Expected one appcast item for {version}, found {len(items)}.")
item = re.sub(r"\s*<description\b.*?</description>", "", items[0].group(), flags=re.S)
indent = "\n            "
localized = indent.join(description(language) for language in LANGUAGES)
item = item.replace("<enclosure", localized + indent + "<enclosure", 1)
appcast.write_text(xml[:items[0].start()] + item + xml[items[0].end():], encoding="utf-8")
