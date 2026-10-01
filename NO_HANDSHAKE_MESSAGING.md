# No-handshake messaging and Message Requests

KaChat 5.2 drops the handshake from 1:1 chats. You message an address and the message goes; the
recipient finds it in **Message Requests** and accepts or rejects it. This file is the protocol
spec, the indexer handoff, and the porting notes for Android and desktop. iOS is the reference.

## Why a handshake existed, and what replaces it

A 1:1 message is a transaction back to the sender's own address (`kchat:1:comm:<alias>:<sealed>`).
It never touches the recipient's coins, and the indexer files it by **sender + alias**. So a
recipient can only fetch messages from someone whose address they already know. The handshake
was the one thing addressed to the recipient (it pays them 0.2 KAS and is indexed by receiver),
which is how a stranger got found.

The replacement: the sender's **first** message carries an **inbox tag** derived from the
recipient's address, and the indexer files it by that tag too.
The recipient asks the indexer for its own tag and learns who wrote. From then on everything
works as it already does: the sender's address and the deterministic aliases (see
`DETERMINISTIC_ALIASES.md`, `Utilities/DeterministicAlias.swift`) give the full history.

Privacy is the same as the handshake's. A handshake shows on chain that A started a
conversation with B; the one tagged message shows the same to anyone who knows B's address.
Every message after it is untagged, so the ongoing conversation stays unlinkable, exactly as
today.

What goes away: the 0.2 KAS handshake transfer, the "Send handshake" step, the "Request to
communicate" bubble, and the response handshake on accept.

## 1. Inbox tag

```
inboxTag(recipient) = lowercase hex of the first 16 bytes of
                      SHA-256( UTF-8( "kachat-inbox:v1:" + recipient ) )
```

- `recipient` is the full address string, lowercased, with its prefix
  (`kaspa:qr...` / `kaspatest:qr...`). 32 hex characters out.
- Test vector: compute it once per platform against iOS (`InboxTag.compute(for:)`) and compare
  before shipping.

## 2. Payload

```
kchat:1:dm:<inboxTag>:<alias>:<sealed>
```

- `<inboxTag>`: 32 lowercase hex characters (section 1).
- `<alias>` and `<sealed>`: exactly as in `kchat:1:comm:<alias>:<sealed>`. Same deterministic
  alias, same encryption to the recipient's key, same output back to the sender's own address.
- Only the prefix differs. A `dm` message is a `comm` message plus the tag.

## 3. Sender rule (every client)

Only the **first** message to B carries the tag. Use `dm` when **all** hold:

1. no tagged message to B has been submitted yet (record B once the `dm` transaction is
   accepted by the node - a failed send does not use up the tag),
2. B has never sent us anything we can see (no incoming message, payment or handshake), and
3. the configured indexer supports inbox lookups (section 5's endpoint answers; probe once per
   indexer URL and cache).

Otherwise send `comm` as today. Never send a handshake for a new chat.

One tagged message is enough: it tells B who wrote, and B's client then fetches everything else
from that sender by sender + alias, which nobody can link to B. Tagging more messages would
reveal how often the sender wrote before getting an answer.

If the indexer does not support inbox lookups yet, behave as before this change (send `comm`;
the recipient finds it once they know the sender). **Never send `dm` to an indexer that does
not support it**: an indexer that does not know the `dm` kind drops the transaction from its
index entirely (`parse_sealed_operation` returns `None`), so even the sender's other devices
would never see it.

### 3.1 Private chats (no link at all)

A user can start a chat as **Private**. A private chat never uses `dm`: every message is plain
`comm`, an ordinary transaction to the sender's own address, so nothing on chain links the two
people - not even who started it. The cost: the other person gets no request and no
notification. They see the messages only once they also open a private chat with the sender's
address, at which point both sides derive the same aliases and each sees the other's messages,
from the beginning.

- Per conversation, chosen when starting the chat, and shown in the chat ("Private - <name> isn't
  notified; they'll see your messages once they start a private chat with your address").
- Starting a chat (private or not) counts as accepting it (section 4).
- Once either side has written, a private chat is an ordinary chat; it simply never sends `dm`.

## 4. Recipient: Message Requests (every client)

- **Discovery.** Ask `GET /contextual-messages/by-inbox?tag=<inboxTag(me)>` on app open, on the
  foreground sweep, and when a request push arrives. For each sender found: if they are blocked,
  ignore it; otherwise add the sender, derive the routing state, and fetch their whole history by
  sender + alias from block time 0 (iOS: `syncContactHistoryFromGenesis`).
- **Request vs chat.** A conversation is a **request** until accepted. Accepted means any of:
  - the user tapped Accept,
  - the user has ever sent this address a message (messaging someone first is consent),
  - the conversation existed before this feature shipped (grandfather every existing chat).
  Requests are not in the chat list. They sit behind one **Message Requests** row, pinned
  directly above your own chat (Saved Messages), with the number of requests.
- **Inside a request** the full thread is readable. Instead of the composer there are two
  buttons:
  - **Accept**: the conversation moves to the chat list. Nothing is sent on chain.
  - **Reject**: the messages are deleted from this device and the address is **blocked**.
- **Blocked** addresses are ignored by discovery, fetching and notifications, and never reappear
  as a request. The block lifts only when the user messages that address themselves.
- **Replying** from a request (if a client allows it) is an Accept.
- **Notifications**: one notification per new requester - "New message request" - and nothing
  for their later messages until accepted. Opening the request shows everything they sent.
- **Old clients and Kasia** still send handshakes. An incoming handshake from an address with no
  accepted conversation is a request like any other (no Accept/Decline bubble; the handshake
  line is just the first entry in the request). Blocked addresses stay blocked.

## 5. Indexer handoff (kachat-indexer)

### 5.1 Parse `dm`

In `protocol/src/operation/deserializer.rs` (`parse_sealed_operation`), add a `dm:` arm beside
`comm:`:

```
dm:<tag>:<alias>:<sealed>
```

- `tag` must be exactly 32 lowercase hex; otherwise reject the operation (return `None`).
- Produce the existing contextual-message operation (alias + sealed) **plus** the tag, so the
  message is stored exactly like a `comm` message (by sender + alias, by tx id) - the existing
  `/contextual-messages/by-sender` must return `dm` messages unchanged.

### 5.2 Index by tag

A new partition, e.g. `contextual_message_by_inbox`:

```
key = tag (16 bytes) | block_time (u64 BE) | tx_id (32 bytes)     value = sender (resolved)
```

Same sender resolution as the by-sender partition (the sender comes from the transaction's
inputs). Reorg/acceptance handling as for the other contextual partitions.

### 5.3 Endpoint

```
GET /contextual-messages/by-inbox?tag=<32 hex>&block_time=<ms, optional>&limit=<n, optional>
```

Response: the same objects as `/contextual-messages/by-sender`, plus `sender` (the resolved
address). Ascending by block time, newer than `block_time`. `limit` default 100, max 500.
A malformed tag is `400`; an unknown tag is `200 []`.

Clients probe support with any well-formed tag: `200` means supported, `404` means not.

### 5.4 Push

Every push registration already carries `primaryAddress`. Compute `inboxTag(primaryAddress)` for
each registered device; when a `dm` transaction with a matching tag is accepted, send that device
the usual 1:1 push (`type: "contextual"`, `sender`, `tx_id`, the sealed payload when it fits)
with one extra key:

```
"inbox": true
```

The client decides whether it is a request (and whether to show anything) - the server only
routes.

### 5.5 Stats

`/stats` should count `dm` under `messages` (STATS_INDEXER.md).

## 6. Porting notes (Android, desktop)

- Implement sections 1-4 exactly; the tag function must match iOS byte for byte.
- Ship together with the indexer change; until a client has it, a KaChat user on iOS reaching
  them for the first time is invisible to them (they will find it as soon as they update -
  the indexer keeps the history).
- Remove the handshake UI (send button, banner, Accept/Decline bubble). Keep parsing incoming
  handshakes for old clients and Kasia (section 4).
