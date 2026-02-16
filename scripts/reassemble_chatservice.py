#!/usr/bin/env python3
"""
Reassemble ChatService.swift from the split files, then re-split using
brace-depth-aware parsing to find correct function boundaries.
"""
import re
import os

DIR = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services"

def read_file(name):
    with open(os.path.join(DIR, name)) as f:
        return f.read()

def extract_extension_body(content):
    """Extract the body of 'extension ChatService { ... }' from an extension file."""
    # Find the extension opening
    match = re.search(r'^extension ChatService \{$', content, re.MULTILINE)
    if not match:
        return ""
    start = match.end() + 1  # skip the newline after {

    # Find the matching closing brace
    depth = 1
    pos = start
    while pos < len(content) and depth > 0:
        if content[pos] == '{':
            depth += 1
        elif content[pos] == '}':
            depth -= 1
        pos += 1

    # pos now points just after the closing }
    return content[start:pos-1]  # exclude the closing }

# Step 1: Reassemble from split files
print("Reassembling original ChatService.swift from split files...")

core = read_file("ChatService.swift")
ext_push = read_file("ChatService+PushAndSync.swift")
ext_utxo = read_file("ChatService+UtxoProcessing.swift")
ext_send = read_file("ChatService+Sending.swift")
ext_proc = read_file("ChatService+Processing.swift")
ext_pers = read_file("ChatService+Persistence.swift")

# Extract the class body from core (everything between class { and the closing })
# Find where the class body starts
class_match = re.search(r'^final class ChatService: ObservableObject \{$', core, re.MULTILINE)
class_body_start = class_match.end() + 1

# Find where supporting types begin (after the class closes)
types_match = re.search(r'^// MARK: - Supporting Types$', core, re.MULTILINE)
if types_match:
    # Everything before this is class body + closing brace
    # Find the class closing brace (last } before MARK)
    pre_types = core[:types_match.start()]
    # The class closing } is at the end of pre_types (strip trailing whitespace)
    class_end = pre_types.rstrip()
    if class_end.endswith('}'):
        class_body = core[class_body_start:len(class_end)-1]  # exclude closing }
    else:
        class_body = core[class_body_start:types_match.start()]

    supporting_types = core[types_match.start():]
else:
    class_body = core[class_body_start:]
    supporting_types = ""

# Header (everything before class definition)
header = core[:class_match.start()]

# Extract bodies from extension files
push_body = extract_extension_body(ext_push)
utxo_body = extract_extension_body(ext_utxo)
send_body = extract_extension_body(ext_send)
proc_body = extract_extension_body(ext_proc)
pers_body = extract_extension_body(ext_pers)

# Reassemble the full class
reassembled = header
reassembled += "final class ChatService: ObservableObject {\n"
reassembled += class_body
reassembled += push_body + "\n"
reassembled += utxo_body + "\n"
reassembled += send_body + "\n"
reassembled += proc_body + "\n"
reassembled += pers_body + "\n"
reassembled += "}\n\n"
reassembled += supporting_types

# Verify brace balance
depth = 0
for ch in reassembled:
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1
print(f"Reassembled brace depth: {depth}")
print(f"Reassembled line count: {reassembled.count(chr(10))}")

# Write reassembled file
reassembled_path = os.path.join(DIR, "ChatService_reassembled.swift")
with open(reassembled_path, "w") as f:
    f.write(reassembled)
print(f"Wrote reassembled file to {reassembled_path}")
