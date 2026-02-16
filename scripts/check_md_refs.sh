#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
import os
import re
import sys
from collections import defaultdict
from glob import glob

targets = sorted(glob("*.md") + glob("docs/*.md"))
if not targets:
    print("No markdown files found for reference check.")
    sys.exit(0)

all_files = []
for base, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d not in {".git", "build", "external"}]
    for name in files:
        rel = os.path.join(base, name).lstrip("./")
        all_files.append(rel)

by_basename = defaultdict(list)
for rel in all_files:
    by_basename[os.path.basename(rel)].append(rel)

pattern = re.compile(r'([A-Za-z0-9_./-]+\.(?:swift|md|xcodeproj|plist))(?::[0-9][0-9,\-]*)?')

errors = []

for md in targets:
    with open(md, "r", encoding="utf-8", errors="ignore") as fh:
        text = fh.read()

    for match in pattern.finditer(text):
        token = match.group(1)
        if token.startswith(("http://", "https://", "mailto:")):
            continue
        if token.startswith(("external/", "build/")):
            continue

        if os.path.exists(token):
            continue

        if "/" not in token:
            candidates = by_basename.get(token, [])
            if len(candidates) == 1:
                continue

        errors.append(f"{md}: missing reference `{token}`")

if errors:
    print("Markdown reference check failed:")
    for err in errors:
        print(f"- {err}")
    sys.exit(1)

print(f"Markdown reference check passed ({len(targets)} files scanned).")
PY
