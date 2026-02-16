#!/usr/bin/env python3
"""
Properly reassemble ChatService.swift from the split files, then re-split
using method-boundary detection (brace depth = 1 inside class).
"""
import re
import os

DIR = "/Users/vsmirnov/docs/github/kasia-ios2-glm/KaChat/Services"

def read_file(name):
    path = os.path.join(DIR, name)
    with open(path) as f:
        return f.readlines()

def extract_extension_lines(lines):
    """Extract lines between 'extension ChatService {' and the final '}' closure."""
    start = None
    for i, line in enumerate(lines):
        if line.strip() == 'extension ChatService {':
            start = i + 1
            break
    if start is None:
        return []
    # The last line should be the closing '}'
    # Find the last '}' line
    end = len(lines) - 1
    while end > start and lines[end].strip() != '}':
        end -= 1
    return lines[start:end]

def extract_core_class_body(lines):
    """Extract class body from core file (between class { and // MARK: - Supporting Types)."""
    class_start = None
    types_start = None
    for i, line in enumerate(lines):
        if 'final class ChatService: ObservableObject {' in line:
            class_start = i + 1
        if '// MARK: - Supporting Types' in line:
            types_start = i
            break

    if class_start is None:
        raise Exception("Could not find class definition")

    # Find the class closing brace (just before MARK or end of class)
    if types_start:
        # Walk backwards from MARK to find closing }
        end = types_start - 1
        while end > class_start and lines[end].strip() == '':
            end -= 1
        if lines[end].strip() == '}':
            end = end  # exclude closing }
        class_body = lines[class_start:end]
    else:
        class_body = lines[class_start:]

    # Header = everything before the class definition
    header = lines[:class_start - 1]  # -1 to exclude the class line itself

    # Types = everything from MARK onwards
    types = lines[types_start:] if types_start else []

    return header, class_body, types

# ============================================================================
# STEP 1: Reconstruct the full file from split parts
# ============================================================================
print("Reading split files...")

core_lines = read_file("ChatService.swift")
push_lines = read_file("ChatService+PushAndSync.swift")
utxo_lines = read_file("ChatService+UtxoProcessing.swift")
send_lines = read_file("ChatService+Sending.swift")
proc_lines = read_file("ChatService+Processing.swift")
pers_lines = read_file("ChatService+Persistence.swift")

header, core_body, types_lines = extract_core_class_body(core_lines)
push_body = extract_extension_lines(push_lines)
utxo_body = extract_extension_lines(utxo_lines)
send_body = extract_extension_lines(send_lines)
proc_body = extract_extension_lines(proc_lines)
pers_body = extract_extension_lines(pers_lines)

print(f"  Core header: {len(header)} lines")
print(f"  Core body: {len(core_body)} lines")
print(f"  Push body: {len(push_body)} lines")
print(f"  Utxo body: {len(utxo_body)} lines")
print(f"  Send body: {len(send_body)} lines")
print(f"  Proc body: {len(proc_body)} lines")
print(f"  Pers body: {len(pers_body)} lines")
print(f"  Types: {len(types_lines)} lines")

# Combine all body lines
all_body = core_body + push_body + utxo_body + send_body + proc_body + pers_body

# Reconstruct full file
full_lines = header + ['@MainActor\n', 'final class ChatService: ObservableObject {\n']
full_lines += all_body
full_lines += ['}\n', '\n']
full_lines += types_lines

total = len(full_lines)
print(f"\nReconstructed: {total} lines")

# Verify brace balance
content = ''.join(full_lines)
depth = 0
for ch in content:
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1
print(f"Brace depth: {depth}")

# ============================================================================
# STEP 2: Find method boundaries using brace depth tracking
# ============================================================================
print("\nFinding method boundaries...")

# A "method boundary" is any line at brace depth 1 inside the class that starts
# a function, var, let, enum, struct, etc. (i.e., a top-level member)

# Parse the class body to find method groups
# We track where each method starts/ends by monitoring indent level

class MethodSpan:
    def __init__(self, start_idx, first_line):
        self.start = start_idx  # index into all_body
        self.end = None
        self.first_line = first_line.strip()
        self.name = self._extract_name(first_line)

    def _extract_name(self, line):
        s = line.strip()
        # Extract function name
        m = re.match(r'(?:nonisolated\s+)?func\s+(\w+)', s)
        if m: return m.group(1)
        m = re.match(r'(?:@\w+\s+)?var\s+(\w+)', s)
        if m: return m.group(1)
        m = re.match(r'(?:@\w+\s+)?let\s+(\w+)', s)
        if m: return m.group(1)
        m = re.match(r'(?:enum|struct|class)\s+(\w+)', s)
        if m: return m.group(1)
        return s[:40]

methods = []
# We scan all_body lines, tracking brace depth relative to the class body
# Depth 0 = class level (where methods are declared)
depth = 0
current_method = None
in_property_block = False

for i, line in enumerate(all_body):
    stripped = line.strip()

    # Skip empty lines and comments at depth 0
    if depth == 0:
        # Check if this line starts a new top-level declaration
        is_decl = bool(re.match(
            r'(func |var |let |enum |struct |class |@Published|@discardableResult|nonisolated |init\(|'
            r'static |/// |// MARK)',
            stripped
        ))

        if is_decl and not stripped.startswith('///') and not stripped.startswith('// MARK'):
            if current_method is not None:
                current_method.end = i
                methods.append(current_method)
            current_method = MethodSpan(i, line)
        elif is_decl and (stripped.startswith('///') or stripped.startswith('// MARK')):
            # Doc comment or mark - belongs to next method
            if current_method is not None:
                current_method.end = i
                methods.append(current_method)
            current_method = MethodSpan(i, line)

    # Track brace depth
    depth += line.count('{') - line.count('}')

# Close last method
if current_method is not None:
    current_method.end = len(all_body)
    methods.append(current_method)

print(f"Found {len(methods)} top-level declarations")

# ============================================================================
# STEP 3: Categorize methods into files
# ============================================================================

# Define categories by method name patterns
SYNC_METHODS = {
    'ChatHistoryImportSummary', 'ChatHistoryArchiveError',
    'exportChatHistoryArchive', 'importChatHistoryArchive',
    'recordRemotePushDelivery',
    'maybeRunCatchUpSync', 'startPolling', 'startFallbackPolling',
    'setupUtxoSubscription', 'scheduleSubscriptionRetry',
    'setupUtxoSubscriptionAfterReconnect',
    'pauseUtxoSubscriptionForRemotePush', 'resumeUtxoSubscriptionForRemotePush',
    'addContactToUtxoSubscription', 'syncContactHistoryFromGenesis',
    'checkAndResubscribeIfNeeded', 'executeResubscriptionIfNeeded',
    'addMessageFromPush', 'addPaymentFromPush',
    'fetchPaymentByTxId', 'fetchMessageByTxId',
    'fetchMessageByTxIdFromMempool', 'fetchMessageByTxIdFromIndexer',
    'fetchMessageByTxIdFromKaspaRest',
    'kaspaRestURL', 'fetchKaspaTransaction', 'resolvePaymentDetailsFromKaspa',
    'updateUtxoSubscriptionForRealtimeChange',
    'disableRealtimeForContact', 'dismissNoisyContactWarning',
    'startDisabledContactsPolling', 'pollDisabledContacts',
    'recordIrrelevantTxNotification',
}

UTXO_METHODS = {
    'handleUtxoChangeNotification', 'enqueueUtxoNotification',
    'processQueuedUtxoNotificationsIfNeeded', 'processParsedUtxoChangeNotification',
    'enqueueIncomingPaymentResolution', 'runIncomingPaymentResolution',
    'resolveAndProcessIncomingPayment',
    'scheduleResolveRetry', 'resolveRetryDelayNs',
    'markIncomingResolutionWarning', 'clearIncomingResolutionTracking',
    'incomingAmountHint', 'parseKasAmountFromPaymentContent',
    'updateIncomingPaymentDeliveryStatus', 'handleIncomingSpecialPayload',
    'retryIncomingWarningResolutionsOnSync',
    'resolveSelfStashCandidate', 'clearSelfStashRetryState',
    'sumOutputsToAddress', 'startMempoolResolveIfNeeded',
    'scheduleSelfStashRetry', 'resolveAndProcessSelfStash',
    'shouldAttemptSelfStashDecryption',
    'primaryConversationAlias', 'primaryOurAlias',
    'addConversationAlias', 'addOurAlias',
    'aliasBelongsToAnotherContact', 'resolvePayloadOnly', 'removeMessage',
    'configureAPIIfNeeded', 'stopPolling', 'stopPollingTimerOnly',
    'enterConversation', 'storedMessageCount', 'storedMessageCountAsync',
    'readCursor', 'loadOlderMessagesPage', 'loadOlderMessagesPageAsync',
    'loadOlderMessagesPageInternal', 'oldestLoadedCursor', 'leaveConversation',
}

SENDING_METHODS = {
    'fetchHandshakesOnly', 'fetchNewMessages',
    'getConversation', 'getOrCreateConversation',
    'sendMessage', 'retryOutgoingMessage', 'sendMessageInternal',
    'resolveMessageIdForPending', 'resolveMessageIdForTx',
    'pruneOutgoingAttempts', 'registerOutgoingAttempt',
    'markOutgoingAttemptSubmitting', 'markOutgoingAttemptSubmitted',
    'markOutgoingAttemptFailed', 'hasInFlightOutgoingAttemptWithoutTxId',
    'isKnownOutgoingAttemptTxId', 'shouldDeferClassification',
    'promoteKnownOutgoingAttempt',
    'outpointKey', 'prepareMessageUtxos', 'pruneMessageUtxoCaches',
    'reserveMessageOutpoints', 'consumePendingUtxos', 'addPendingOutputs',
    'releaseMessageOutpoints',
    'shouldRetrySendError', 'shouldRetryNoSpendableFundsError',
    'spendableFundsRetryDelay', 'acceptedTransactionId',
    'extractLikelyTxId', 'extractTxId', 'extractFirstHex64',
    'extractFirstHex64AllowingWhitespace', 'scheduleOutgoingRetry',
    'sendPayment', 'estimateMessageFee', 'estimatePaymentFee',
    'estimateMaxPaymentAmount',
    'sendHandshake', 'shouldRetryHandshakeAsResponse', 'respondToHandshake',
    'isConversationDeclined', 'isConversationVisibleInChatList',
    'pushEligibleConversationAddresses',
    'hasOurAlias', 'hasTheirAlias', 'generateAlias', 'generateConversationId',
    'updateWalletBalanceIfNeeded', 'splitUtxosForHandshake',
    'connectRpcIfNeeded', 'fetchCachedUtxos', 'fetchUtxosWithFallback',
    'splitUtxosForSelfStash', 'sendOrQueueSelfStash', 'queueSelfStash',
    'submitSelfStashTx', 'changeUtxo', 'attemptPendingSelfStashSends',
    'updatePendingMessage', 'markPendingMessageFailed', 'resetPendingMessage',
    'updateOutgoingPendingMessageIfMatch', 'updatePendingMessageById',
    'updateOldestPendingOutgoingMessage', 'updateMostRecentPendingOutgoingMessage',
    'markConversationAsRead',
    'checkIndexerForHandshake', 'fetchIncomingHandshakes', 'fetchOutgoingHandshakes',
    'fetchIncomingPayments', 'fetchOutgoingPayments',
    'applyMessageRetention', 'messageRetentionCutoffMs',
    'fetchPaymentsFromKaspaAPI', 'fetchFullTransactionsPaginated',
}

PROCESSING_METHODS = {
    'processHandshakes', 'reclassifyMisidentifiedHandshakes', 'replaceMessageType',
    'resolveSenderAddress', 'isValidKaspaAddress',
    'isHandshakePayload', 'isContextualPayload', 'isSelfStashPayload',
    'fetchSenderAddressFromTransaction', 'resolveTransactionInfo',
    'resolveTransactionInfoFromIndexer', 'resolveTransactionInfoFromKaspaRest',
    'fetchKaspaFullTransaction', 'deriveSenderFromFullTx', 'fetchAnyInputAddress',
    'fetchSavedHandshakes', 'retryUntilSuccess',
    'beginChatFetch', 'markChatFetchLoading', 'endChatFetch',
    'fetchContextualMessages', 'fetchContextualMessagesForActive',
    'fetchContextualMessagesFromContactWithRetry', 'fetchContextualMessagesFromContact',
    'contextualFetchKey', 'beginContextualFetch', 'endContextualFetch',
    'processPayments',
    'findLocalMessage', 'hasLocalMessage',
    'addOutgoingMessageFromPush', 'scheduleCloudKitRetryForOutgoing',
    'contactAddressForOutgoingAlias', 'resolveRawPayloadForTx',
    'addMessageToConversation', 'updateIncomingPaymentStatus',
    'sendLocalNotification', 'formatNotificationBody',
    'updateConversation',
    'decodeMessagePayload', 'decodePaymentPayload',
    'messageType', 'paymentContent', 'formatKasAmount',
}

# Everything else goes to Persistence
PERSISTENCE_METHODS = set()  # Will catch everything not in the above sets

def categorize(method):
    name = method.name
    if name in SYNC_METHODS:
        return 'sync'
    if name in UTXO_METHODS:
        return 'utxo'
    if name in SENDING_METHODS:
        return 'sending'
    if name in PROCESSING_METHODS:
        return 'processing'
    return 'persistence'

# Separate core properties from methods
# Core = everything that's a stored property, init, or observer
CORE_KEEP = {
    'conversations', 'isLoading', 'error', 'declinedContacts',
    'settingsViewModel', 'cachedSettings', 'activeConversationAddress',
    'ChatFetchState', 'chatFetchStates', 'ContactFetchResult',
    'chatFetchCounts', 'chatFetchFailed', 'pendingChatNavigation',
    'isRpcSubscribed', 'lastSuccessfulSyncDate', 'currentConnectedNode',
    'currentNodeLatencyMs',
    'QueuedUtxoNotification', 'OutgoingAttemptPhase', 'OutgoingTxAttempt',
    'SyncObjectCursor', 'PushReliabilityState', 'PendingPushObservation',
    'connectionStatus',
    'apiClient', 'contactsManager', 'userDefaults', 'messageStore',
    # All private let/var properties stay in core
    'init',
    'observeConversationCount', 'observePingLatency',
    'observeNodePoolConnectionState', 'observeRpcReconnection',
    'clearAllData', 'wipeIncomingMessagesAndResync', 'resetForNewWallet',
}

# ============================================================================
# STEP 4: Build the output files
# ============================================================================

IMPORTS = """import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit
"""

# Separate methods into categories
categorized = {'core': [], 'sync': [], 'utxo': [], 'sending': [], 'processing': [], 'persistence': []}

for m in methods:
    name = m.name
    if name in CORE_KEEP:
        categorized['core'].append(m)
    else:
        cat = categorize(m)
        categorized[cat].append(m)

# Also include any uncategorized property declarations in core
# (properties at depth 0 that aren't functions)
core_property_lines = []
for m in methods:
    if m.name in CORE_KEEP:
        continue
    # Check if it's a property (not a func/enum/struct)
    fl = m.first_line
    if not re.match(r'(func |enum |struct |class |init\(|nonisolated func|static func)', fl):
        # It's a property - keep in core
        if m not in categorized['core']:
            categorized['core'].append(m)
            # Remove from other categories
            for cat in ['sync', 'utxo', 'sending', 'processing', 'persistence']:
                if m in categorized[cat]:
                    categorized[cat].remove(m)

# Sort core methods by their original position
for cat in categorized:
    categorized[cat].sort(key=lambda m: m.start)

def build_file_content(category_methods, header_comment, is_core=False):
    """Build file content from method list."""
    parts = []

    if is_core:
        # Core file includes header, class definition, properties, and methods
        parts.append(''.join(header))
        parts.append('@MainActor\n')
        parts.append('final class ChatService: ObservableObject {\n')
        for m in category_methods:
            parts.append(''.join(all_body[m.start:m.end]))
        parts.append('}\n\n')
        parts.append(''.join(types_lines))
    else:
        # Extension file
        parts.append(f'// ChatService+{header_comment}.swift\n')
        parts.append(f'// Split from ChatService.swift for faster incremental builds\n\n')
        parts.append(IMPORTS + '\n')
        parts.append('extension ChatService {\n')
        for m in category_methods:
            parts.append(''.join(all_body[m.start:m.end]))
        parts.append('}\n')

    return ''.join(parts)

print("\nMethod distribution:")
for cat, ms in categorized.items():
    total_lines = sum(m.end - m.start for m in ms)
    print(f"  {cat}: {len(ms)} methods, ~{total_lines} lines")

# Build files
files = {
    'ChatService.swift': build_file_content(categorized['core'], 'Core', is_core=True),
    'ChatService+PushAndSync.swift': build_file_content(categorized['sync'], 'PushAndSync'),
    'ChatService+UtxoProcessing.swift': build_file_content(categorized['utxo'], 'UtxoProcessing'),
    'ChatService+Sending.swift': build_file_content(categorized['sending'], 'Sending'),
    'ChatService+Processing.swift': build_file_content(categorized['processing'], 'Processing'),
    'ChatService+Persistence.swift': build_file_content(categorized['persistence'], 'Persistence'),
}

# Verify brace balance for each file
print("\nBrace balance check:")
for name, content in files.items():
    depth = 0
    for ch in content:
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
    line_count = content.count('\n')
    status = "OK" if depth == 0 else f"IMBALANCED ({depth})"
    print(f"  {name}: {line_count} lines, braces: {status}")

# Write all files
print("\nWriting files...")
for name, content in files.items():
    path = os.path.join(DIR, name)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  {name}")

# Clean up temp files
for f in ['ChatService_original.swift', 'ChatService_reassembled.swift']:
    path = os.path.join(DIR, f)
    if os.path.exists(path):
        os.remove(path)
        print(f"  Cleaned up {f}")

print("\nDone!")
