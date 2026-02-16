#!/usr/bin/env python3
"""
Split ChatService.swift into extension files for incremental build speed.

Strategy:
1. Keep class declaration + all stored properties in main file
2. Move method implementations to categorized extension files
3. Change 'private' to 'internal' (default) for cross-file access

IMPORTANT: Backup was made before running this script.
"""
import re
import sys

INPUT = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services/ChatService.swift"

with open(INPUT) as f:
    lines = f.readlines()

print(f"Input: {len(lines)} lines")

# ============================================================================
# STEP 1: Track brace depth per-line (string/comment aware)
# ============================================================================

def compute_brace_depths(lines):
    """Compute brace depth at the END of each line, handling strings and comments."""
    depths = []
    depth = 0
    in_block_comment = False

    for line in lines:
        i = 0
        s = line
        while i < len(s):
            if in_block_comment:
                if s[i:i+2] == '*/':
                    in_block_comment = False
                    i += 2
                    continue
                i += 1
                continue

            ch = s[i]

            # Block comment start
            if s[i:i+2] == '/*':
                in_block_comment = True
                i += 2
                continue

            # Line comment - skip rest
            if s[i:i+2] == '//':
                break

            # String literal (double-quoted)
            if ch == '"':
                # Check for multi-line string """
                if s[i:i+3] == '"""':
                    i += 3
                    while i < len(s):
                        if s[i:i+3] == '"""':
                            i += 3
                            break
                        if s[i] == '\\':
                            i += 2
                            continue
                        i += 1
                    continue
                # Regular string
                i += 1
                while i < len(s):
                    if s[i] == '\\':
                        i += 2
                        continue
                    if s[i] == '"':
                        i += 1
                        break
                    i += 1
                continue

            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1

            i += 1

        depths.append(depth)

    return depths

depths = compute_brace_depths(lines)
print(f"Final brace depth: {depths[-1]}")

# ============================================================================
# STEP 2: Find clean cut points (where depth == 1 = inside class, between members)
# ============================================================================

# Approximate target line numbers for cuts (0-indexed)
# These are based on method analysis:
#   Main file: lines 0-561 (properties, init, observers, lifecycle)
#   Ext 1: lines 562-1817 (push, sync, subscriptions, archive)
#   Ext 2: lines 1818-3425 (UTXO processing, payment resolution, self-stash)
#   Ext 3: lines 3426-5559 (conversations, sending, handshakes)
#   Ext 4: lines 5559-7932 (fetching, processing, message helpers)
#   Ext 5: lines 7933-9362 (persistence, UI, aliases, CloudKit)
#   Ext 6: lines 9362-end (decryption, support structs)

target_cuts = [562, 1818, 3426, 5559, 7933, 9362]

def find_nearest_cut(target, depths, lines):
    """Find the nearest line to target where depth==1 and the line is blank or a comment."""
    best = None
    best_dist = 999999
    # Search within 30 lines of target
    for i in range(max(0, target - 30), min(len(lines), target + 30)):
        if depths[i] == 1:
            # Prefer blank lines or comment-only lines for clean cuts
            stripped = lines[i].strip()
            is_clean = stripped == '' or stripped.startswith('//')
            dist = abs(i - target)
            if is_clean:
                dist -= 0.5  # Prefer clean lines
            if dist < best_dist:
                best_dist = dist
                best = i
    return best

cut_points = []
for target in target_cuts:
    cut = find_nearest_cut(target, depths, lines)
    if cut is not None:
        cut_points.append(cut)
        print(f"  Target ~{target+1} -> cut after line {cut+1} (depth={depths[cut]})")
    else:
        print(f"  WARNING: No clean cut point near line {target+1}")

# ============================================================================
# STEP 3: Split into sections
# ============================================================================

sections = []
prev = 0
for cut in cut_points:
    sections.append(lines[prev:cut+1])
    prev = cut + 1
sections.append(lines[prev:])  # Last section

print(f"\nSections: {len(sections)}")
for i, sec in enumerate(sections):
    print(f"  Section {i}: {len(sec)} lines (lines {sum(len(s) for s in sections[:i])+1}-{sum(len(s) for s in sections[:i+1])})")

# ============================================================================
# STEP 4: Verify brace depth at each cut point
# ============================================================================

for i, cut in enumerate(cut_points):
    d = depths[cut]
    if d != 1:
        print(f"  ERROR: Cut point {i} at line {cut+1} has depth {d}, expected 1")
        sys.exit(1)

print("\nAll cut points have depth 1 - good!")

# ============================================================================
# STEP 5: Transform access control
# ============================================================================

def strip_private_from_declarations(line):
    """Remove 'private' from declarations to make them internal (default)."""
    # private func -> func
    line = re.sub(r'^(\s+)private (func )', r'\1\2', line)
    # private var -> var (but not @Published private(set))
    line = re.sub(r'^(\s+)private (var )', r'\1\2', line)
    # private let -> let
    line = re.sub(r'^(\s+)private (let )', r'\1\2', line)
    # private enum -> enum
    line = re.sub(r'^(\s+)private (enum )', r'\1\2', line)
    # private struct -> struct
    line = re.sub(r'^(\s+)private (struct )', r'\1\2', line)
    # private nonisolated -> nonisolated
    line = re.sub(r'^(\s+)private (nonisolated )', r'\1\2', line)
    return line

def strip_private_properties(line):
    """Remove 'private' from property declarations only (not methods)."""
    # private var -> var (but not @Published private(set))
    if 'private(set)' in line:
        return line
    line = re.sub(r'^(\s+)private (var )', r'\1\2', line)
    line = re.sub(r'^(\s+)private (let )', r'\1\2', line)
    # private enum/struct in properties section
    line = re.sub(r'^(\s+)private (enum )', r'\1\2', line)
    line = re.sub(r'^(\s+)private (struct )', r'\1\2', line)
    return line

# For the main file (section 0), only strip private from properties
# For extension files (sections 1+), strip private from everything

# ============================================================================
# STEP 6: Write output files
# ============================================================================

IMPORTS = """import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit
"""

output_dir = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services/"

file_configs = [
    {
        'name': 'ChatService.swift',
        'desc': 'Core class declaration, properties, init, observers, lifecycle',
        'is_main': True,
    },
    {
        'name': 'ChatService+PushAndSync.swift',
        'desc': 'Push notifications, sync orchestration, UTXO subscriptions, archive',
    },
    {
        'name': 'ChatService+UtxoProcessing.swift',
        'desc': 'UTXO notification handling, payment resolution, self-stash processing',
    },
    {
        'name': 'ChatService+Conversations.swift',
        'desc': 'Conversation state, message sending, handshake sending, fee estimation',
    },
    {
        'name': 'ChatService+Fetching.swift',
        'desc': 'Handshake/message/payment fetching from APIs, processing',
    },
    {
        'name': 'ChatService+Persistence.swift',
        'desc': 'Data persistence, UI helpers, aliases, CloudKit, badges',
    },
    {
        'name': 'ChatService+Decryption.swift',
        'desc': 'Message decryption, hex utilities, support structures',
    },
]

written_files = []

for idx, (section, config) in enumerate(zip(sections, file_configs)):
    filepath = output_dir + config['name']
    is_main = config.get('is_main', False)

    if is_main:
        # Main file: strip private from properties, keep class structure
        out_lines = []
        for line in section:
            # In the main file, strip private from properties
            out_lines.append(strip_private_properties(line))
        # The main file already has the class closing brace elsewhere,
        # but since we cut at depth 1, we need to add the closing brace
        # Actually, the class { is opened in the main section and closed at the end
        # Since we cut at depth 1 (inside class), the main file needs a closing }
        out_lines.append('}\n')

        with open(filepath, 'w') as f:
            f.writelines(out_lines)
        written_files.append((filepath, len(out_lines)))

    else:
        # Extension file: wrap in extension ChatService { ... }
        out_lines = []
        out_lines.append(IMPORTS + '\n')
        out_lines.append(f'// MARK: - {config["desc"]}\n')
        out_lines.append('\n')
        out_lines.append('extension ChatService {\n')

        for line in section:
            transformed = strip_private_from_declarations(line)
            out_lines.append(transformed)

        # Check if the last section includes the class closing brace
        # If so, we need to handle it
        if idx == len(sections) - 1:
            # Last section - ends with the class closing brace '}'
            # We need to remove that closing brace and add extension closing brace
            # Actually, the class closing brace is at depth 0.
            # Since we're extracting content from inside the class,
            # the final '}' at depth 0 should be removed and replaced with '}\n'
            # Let's check: strip trailing blank lines and find the last '}'
            while out_lines and out_lines[-1].strip() == '':
                out_lines.pop()
            # The last non-blank line should be '}'
            if out_lines[-1].strip() == '}':
                out_lines.pop()  # Remove the class closing brace
            out_lines.append('}\n')  # Add extension closing brace
        else:
            out_lines.append('}\n')

        with open(filepath, 'w') as f:
            f.writelines(out_lines)
        written_files.append((filepath, len(out_lines)))

print("\nWritten files:")
total_lines = 0
for filepath, count in written_files:
    name = filepath.split('/')[-1]
    print(f"  {name}: {count} lines")
    total_lines += count
print(f"  Total: {total_lines} lines")

# ============================================================================
# STEP 7: Verify brace balance in each file
# ============================================================================

print("\nVerifying brace balance:")
all_good = True
for filepath, _ in written_files:
    with open(filepath) as f:
        content = f.read()
    file_lines = content.split('\n')
    file_depths = compute_brace_depths([l + '\n' for l in file_lines])
    final_depth = file_depths[-1] if file_depths else 0
    name = filepath.split('/')[-1]
    status = "OK" if final_depth == 0 else f"IMBALANCED (depth={final_depth})"
    print(f"  {name}: {status}")
    if final_depth != 0:
        all_good = False

if all_good:
    print("\nAll files have balanced braces!")
else:
    print("\nERROR: Some files have imbalanced braces!")
    sys.exit(1)
