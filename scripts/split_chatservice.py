#!/usr/bin/env python3
"""Split ChatService.swift into multiple extension files for faster incremental builds."""

import re
import os

SRC = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services/ChatService.swift"
DST_DIR = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services"

# Read entire file
with open(SRC, "r") as f:
    lines = f.readlines()

total = len(lines)
print(f"Total lines: {total}")

# Line ranges are 1-indexed (matching the editor), convert to 0-indexed for slicing
def get_lines(start, end):
    """Get lines from start to end (1-indexed, inclusive)."""
    return lines[start-1:end]

def join_lines(line_list):
    return "".join(line_list)

# ============================================================================
# FILE SPLITS (1-indexed, inclusive ranges)
# ============================================================================

# File 1: ChatService.swift (Core)
# - Lines 1-549: imports, enums, class definition, properties, init, lifecycle, observers
# - Lines 9641-9641: closing brace of class
# - Lines 9643-9900: supporting types (file-private structs)

# File 2: ChatService+PushAndSync.swift
# - Lines 551-1799: chat history, push delivery, sync/polling, UTXO subscription,
#   push message handling, realtime disabled, spam detection

# File 3: ChatService+UtxoProcessing.swift
# - Lines 1801-3553: UTXO notification processing, payment resolution,
#   self-stash, remove message, configureAPI, stop polling, conversation mgmt

# File 4: ChatService+Sending.swift
# - Lines 3555-5965: fetching, get/create conversation, message/payment/handshake sending,
#   outgoing tracking, UTXO management, pending messages, mark as read,
#   handshake/payment API calls, REST payment fetching

# File 5: ChatService+Processing.swift
# - Lines 5967-7935: handshake/payment processing, transaction resolution,
#   contextual messages, message management, local notifications, decoders

# File 6: ChatService+Persistence.swift
# - Lines 7937-9640: store sync, migration, CloudKit, push reliability,
#   sync helpers, cursors, badge, store persistence, drafts, aliases, routing, decryption

HEADER_IMPORTS = """import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

"""

def make_extension_file(name, ranges, description):
    """Create an extension file from line ranges."""
    content = f"// {name}\n"
    content += f"// {description}\n"
    content += f"// Split from ChatService.swift for faster incremental builds\n\n"
    content += HEADER_IMPORTS
    content += "extension ChatService {\n"

    for start, end in ranges:
        chunk = get_lines(start, end)
        content += join_lines(chunk)
        content += "\n"

    content += "}\n"
    return content

def make_core_file(ranges_core, ranges_types):
    """Create the core ChatService.swift with properties, init, and types."""
    content = ""
    for start, end in ranges_core:
        chunk = get_lines(start, end)
        content += join_lines(chunk)

    # Close the class
    content += "}\n\n"

    # Add supporting types
    for start, end in ranges_types:
        chunk = get_lines(start, end)
        content += join_lines(chunk)

    return content

# ============================================================================
# ACCESS MODIFIER CHANGES
# ============================================================================

def fix_private_access(content):
    """
    Change 'private' to internal (remove private keyword) for stored properties
    and methods that need cross-file access in extensions.

    In Swift, extensions in separate files can't access private members.
    Since this is an app target (not a framework), internal is safe.
    """
    # Change 'private func' to 'func' (4-space indented, inside class/extension)
    content = re.sub(r'^(    )private func ', r'\1func ', content, flags=re.MULTILINE)

    # Change 'private var' to 'var' (4-space indented)
    content = re.sub(r'^(    )private var ', r'\1var ', content, flags=re.MULTILINE)

    # Change 'private let' to 'let' (4-space indented)
    content = re.sub(r'^(    )private let ', r'\1let ', content, flags=re.MULTILINE)

    # Change 'private enum' to 'enum' (4-space indented)
    content = re.sub(r'^(    )private enum ', r'\1enum ', content, flags=re.MULTILINE)

    # Change 'private struct' to 'struct' (4-space indented)
    content = re.sub(r'^(    )private struct ', r'\1struct ', content, flags=re.MULTILINE)

    # Change '@Published private(set)' stays as-is (that's fine, it's a setter restriction)
    # Don't touch 'private(set)' — that's a different pattern

    return content

def fix_private_for_file_scope_types(content):
    """Fix file-scope private types (no indentation) — these stay private/fileprivate."""
    # File-scope 'private struct/enum/actor' should become 'struct/enum/actor'
    # since they'll be in an extension or separate file
    content = re.sub(r'^private struct ', r'struct ', content, flags=re.MULTILINE)
    content = re.sub(r'^private actor ', r'actor ', content, flags=re.MULTILINE)
    content = re.sub(r'^private enum ', r'enum ', content, flags=re.MULTILINE)
    return content

# ============================================================================
# GENERATE FILES
# ============================================================================

# Core: properties, init, lifecycle, observers
core_content = make_core_file(
    ranges_core=[(1, 549)],  # Through end of resetForNewWallet
    ranges_types=[(9643, total)]  # Supporting types after class close
)
# For core, keep private on stored properties (they're in the same class definition)
# But we need to remove private so extensions in other files can access them
core_content = fix_private_access(core_content)
core_content = fix_private_for_file_scope_types(core_content)

# Extension 2: Push + Sync
ext2_content = make_extension_file(
    "ChatService+PushAndSync.swift",
    [(551, 1799)],
    "Chat history, push delivery, sync/polling, UTXO subscription, push message handling"
)
ext2_content = fix_private_access(ext2_content)

# Extension 3: UTXO Processing
ext3_content = make_extension_file(
    "ChatService+UtxoProcessing.swift",
    [(1801, 3553)],
    "UTXO notification processing, payment resolution, self-stash, conversation management"
)
ext3_content = fix_private_access(ext3_content)

# Extension 4: Sending
ext4_content = make_extension_file(
    "ChatService+Sending.swift",
    [(3555, 5965)],
    "Message/payment/handshake sending, outgoing tracking, UTXO management, API fetching"
)
ext4_content = fix_private_access(ext4_content)

# Extension 5: Processing
ext5_content = make_extension_file(
    "ChatService+Processing.swift",
    [(5967, 7935)],
    "Handshake/payment processing, transaction resolution, message management, notifications"
)
ext5_content = fix_private_access(ext5_content)

# Extension 6: Persistence
ext6_content = make_extension_file(
    "ChatService+Persistence.swift",
    [(7937, 9640)],
    "Store sync, migration, CloudKit, push reliability, aliases, routing, drafts, decryption"
)
ext6_content = fix_private_access(ext6_content)

# ============================================================================
# WRITE FILES
# ============================================================================

files = {
    "ChatService.swift": core_content,
    "ChatService+PushAndSync.swift": ext2_content,
    "ChatService+UtxoProcessing.swift": ext3_content,
    "ChatService+Sending.swift": ext4_content,
    "ChatService+Processing.swift": ext5_content,
    "ChatService+Persistence.swift": ext6_content,
}

for filename, content in files.items():
    filepath = os.path.join(DST_DIR, filename)
    line_count = content.count('\n')
    print(f"  {filename}: {line_count} lines")
    with open(filepath, "w") as f:
        f.write(content)

print(f"\nDone! Split {total} lines into {len(files)} files.")
print("\nRemember to:")
print("1. Add new files to Xcode project (project.pbxproj)")
print("2. Build to verify no compilation errors")
