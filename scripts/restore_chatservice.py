#!/usr/bin/env python3
"""Restore ChatService.swift from split files."""
import os
import re

DIR = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services"

def read_file(name):
    with open(os.path.join(DIR, name)) as f:
        return f.readlines()

def extract_extension_body(lines):
    """Extract lines between 'extension ChatService {' and the final matching '}'."""
    start = None
    for i, line in enumerate(lines):
        if line.strip() == 'extension ChatService {':
            start = i + 1
            break
    if start is None:
        return []
    # Find the LAST '}' that matches the extension opening
    # Simply take everything except the last line that is just '}'
    end = len(lines) - 1
    while end > start and lines[end].strip() != '}':
        end -= 1
    if end <= start:
        return []
    return lines[start:end]

# Read all files
core_lines = read_file("ChatService.swift")
push_lines = read_file("ChatService+PushAndSync.swift")
utxo_lines = read_file("ChatService+UtxoProcessing.swift")
send_lines = read_file("ChatService+Sending.swift")
proc_lines = read_file("ChatService+Processing.swift")
pers_lines = read_file("ChatService+Persistence.swift")

# Extract header (imports + enums before class definition)
header = []
class_line_idx = None
for i, line in enumerate(core_lines):
    if 'final class ChatService: ObservableObject {' in line:
        class_line_idx = i
        break
    # Include @MainActor on the line before
    header.append(line)

# Extract core class body (between class { and // MARK: - Supporting Types or closing })
core_body = []
types_section = []
in_types = False
for i in range(class_line_idx + 1, len(core_lines)):
    line = core_lines[i]
    if '// MARK: - Supporting Types' in line:
        in_types = True
    if in_types:
        types_section.append(line)
    else:
        # Skip the class closing brace (standalone })
        if line.strip() == '}' and i > 0 and core_lines[i-1].strip() in ['', '}']:
            # Check if this is the class-closing brace by looking at context
            # If the previous non-empty line closes a function, this might be class close
            pass
        core_body.append(line)

# Remove trailing '}' from core_body (the class closing brace the script added)
while core_body and core_body[-1].strip() in ['', '}']:
    last = core_body.pop()
    if last.strip() == '}':
        break

# Extract extension bodies
push_body = extract_extension_body(push_lines)
utxo_body = extract_extension_body(utxo_lines)
send_body = extract_extension_body(send_lines)
proc_body = extract_extension_body(proc_lines)
pers_body = extract_extension_body(pers_lines)

print(f"Header: {len(header)} lines")
print(f"Core body: {len(core_body)} lines")
print(f"Push body: {len(push_body)} lines")
print(f"Utxo body: {len(utxo_body)} lines")
print(f"Send body: {len(send_body)} lines")
print(f"Proc body: {len(proc_body)} lines")
print(f"Pers body: {len(pers_body)} lines")
print(f"Types: {len(types_section)} lines")

# Reassemble
result = []
result.extend(header)
result.append('final class ChatService: ObservableObject {\n')
result.extend(core_body)
result.extend(push_body)
result.extend(utxo_body)
result.extend(send_body)
result.extend(proc_body)
result.extend(pers_body)
result.append('}\n')
result.append('\n')
result.extend(types_section)

content = ''.join(result)
line_count = content.count('\n')

# Check brace balance
depth = 0
for ch in content:
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1

print(f"\nRestored: {line_count} lines")
print(f"Brace depth: {depth}")

# Write restored file
restored_path = os.path.join(DIR, "ChatService.swift")
with open(restored_path, 'w') as f:
    f.write(content)

# Remove split files
for name in ['ChatService+PushAndSync.swift', 'ChatService+UtxoProcessing.swift',
             'ChatService+Sending.swift', 'ChatService+Processing.swift',
             'ChatService+Persistence.swift']:
    path = os.path.join(DIR, name)
    if os.path.exists(path):
        os.remove(path)
        print(f"Removed {name}")

print(f"\nRestored ChatService.swift ({line_count} lines)")

if depth != 0:
    print(f"WARNING: Brace imbalance of {depth}! Manual review needed.")
