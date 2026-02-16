#!/usr/bin/env python3
"""
Fix ChatService.swift by:
1. Restoring 'private' keywords using backup as reference
2. Finding and fixing missing closing braces
"""
import re
import difflib

BACKUP = "/Users/vsmirnov/docs/github/kasia-ios2-glm/restore-from-backup/kasia-ios2-glm/KaChat/Services/ChatService.swift"
DAMAGED = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services/ChatService.swift.damaged"
OUTPUT = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services/ChatService.swift"

with open(BACKUP) as f:
    backup_lines = f.readlines()
with open(DAMAGED) as f:
    damaged_lines = f.readlines()

print(f"Backup: {len(backup_lines)} lines")
print(f"Damaged: {len(damaged_lines)} lines")

# ============================================================================
# STEP 1: Build a map of which lines in the backup had 'private'
# ============================================================================

# Create a "signature" for each line by stripping 'private ' to match damaged lines
def normalize(line):
    """Remove 'private ' from declarations for matching purposes."""
    s = line
    s = re.sub(r'^(    )private (func |var |let |enum |struct )', r'\1\2', s)
    return s

# Build normalized backup for matching
backup_normalized = [normalize(l) for l in backup_lines]

# For each backup line, check if it originally had 'private'
backup_had_private = {}
for i, (orig, norm) in enumerate(zip(backup_lines, backup_normalized)):
    if orig != norm:
        # This line had 'private' removed during normalization
        backup_had_private[norm.rstrip()] = orig.rstrip()

print(f"Backup lines with 'private': {len(backup_had_private)}")

# ============================================================================
# STEP 2: Restore 'private' in damaged file using backup reference
# ============================================================================

# Use SequenceMatcher to align damaged lines with backup
# For lines that match the normalized backup, restore the original form

fixed_lines = []
private_restored = 0

# Build a set of all normalized backup lines for quick lookup
backup_norm_set = set(l.rstrip() for l in backup_normalized)

for line in damaged_lines:
    stripped = line.rstrip()

    # Check if this line matches a backup line that had 'private'
    if stripped in backup_had_private:
        # Restore the original line with 'private'
        fixed_lines.append(backup_had_private[stripped] + '\n')
        private_restored += 1
    else:
        # Check if this is a NEW declaration (not in backup) that should be private
        # New code from logs: private for internal methods, vars, lets
        m = re.match(r'^(    )(func |var |let |enum |struct )', line)
        if m:
            # Check if it's genuinely new (not in backup's normalized form)
            if stripped not in backup_norm_set:
                # New code - check LOG conventions
                # Most new methods/vars in the logs were private
                # Exceptions: public API methods like maybeRunCatchUpSync, recordRemotePushDelivery
                public_methods = {
                    'func maybeRunCatchUpSync', 'func recordRemotePushDelivery',
                    'func startPolling', 'func addMessageFromPush', 'func addPaymentFromPush',
                    'func checkAndResubscribeIfNeeded', 'func sendHandshake',
                    'func addContactToUtxoSubscription', 'func syncContactHistoryFromGenesis',
                    'func setupUtxoSubscriptionAfterReconnect',
                    'func pauseUtxoSubscriptionForRemotePush',
                    'func resumeUtxoSubscriptionForRemotePush',
                    'func fetchPaymentByTxId', 'func fetchMessageByTxId',
                }
                is_public = any(stripped.lstrip().startswith(pm) for pm in public_methods)
                # Also @Published should stay as-is
                is_published = '@Published' in line

                if not is_public and not is_published and not stripped.startswith('    @'):
                    fixed_lines.append(line[:4] + 'private ' + line[4:])
                    private_restored += 1
                else:
                    fixed_lines.append(line)
            else:
                fixed_lines.append(line)
        else:
            fixed_lines.append(line)

print(f"Restored 'private' on {private_restored} lines")

# ============================================================================
# STEP 3: Find and fix missing closing braces
# ============================================================================

# Check brace balance
content = ''.join(fixed_lines)
depth = 0
for ch in content:
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1
print(f"Brace depth after private fix: {depth}")

# Track brace depth per-line to find where imbalances are
if depth != 0:
    print(f"\nNeed to fix {depth} missing closing braces")
    print("Scanning for imbalance locations...")

    # Compare brace depth progression between backup and fixed file
    # at corresponding function boundaries

    # Find all function-closing lines (depth goes from 2 to 1)
    # in both backup and fixed to identify mismatches

    # Strategy: find lines in the damaged file where the original split
    # script cut. These are at approximately:
    # - Line ~550 (core/PushAndSync boundary)
    # - Line ~1800 (PushAndSync/UtxoProcessing boundary)
    # - Line ~3555 (UtxoProcessing/Sending boundary)
    # - Line ~5965 (Sending/Processing boundary)
    # - Line ~7935 (Processing/Persistence boundary)

    # At each boundary, check if a function is properly closed
    line_depth = 0
    boundary_depths = {}
    for i, line in enumerate(fixed_lines):
        line_depth += line.count('{') - line.count('}')
        # Record depth at key boundaries
        for boundary in [550, 1800, 3555, 5965, 7935]:
            if i + 1 == boundary:
                boundary_depths[boundary] = line_depth

    print("Depths at original split boundaries:")
    for b, d in sorted(boundary_depths.items()):
        expected = 1  # Should be 1 (inside class, between methods)
        status = "OK" if d == expected else f"OFF by {d - expected}"
        print(f"  Line ~{b}: depth={d} ({status})")

# ============================================================================
# STEP 4: Write the fixed file
# ============================================================================

with open(OUTPUT, 'w') as f:
    f.writelines(fixed_lines)

line_count = len(fixed_lines)
print(f"\nWrote {line_count} lines to {OUTPUT}")

if depth != 0:
    print(f"\nWARNING: Still has brace imbalance of {depth}")
    print("The missing braces need manual review at the boundary areas")
