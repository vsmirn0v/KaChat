# Online Chess (5.1): 1v1 and tournaments

Public 1v1 games and eight-player single-elimination tournaments where **every move is a Kaspa
transaction**. Lives in Kaspa Hub > **Chess Online**: choose 1v1 or Tournaments, each with its own Active, Finished and Leaderboard tabs. This document is the protocol (Android and desktop replicate it
byte for byte) and the indexer handoff for the leaderboard.

## 1. How it works

- A tournament is a room in the public **`#chess-arena`** broadcast channel. Every tournament
  message - create, join, move, resign, timeout claim, chat - is an ordinary plaintext
  broadcast payload (`kchat:1:bcast:chess-arena:<json>`), so the sender of every message is
  the transaction's signer: nothing can be forged, and no extra signature is needed.
- The channel is machinery, not a chat: the app hides it from Public Chats, never notifies for
  it, and only scans it while a chess screen is open.
- **There is no referee.** Every phone reads the same messages in the same order (block time,
  then txid) and applies the same rules below, so they all arrive at the same bracket, the same
  boards and the same clocks. A message that breaks a rule (a move out of turn, an illegal
  move, a ninth join) is simply ignored by everyone.
- Cost: one transaction per move, about 0.0017 KAS each. A 40-move game is ~0.07 KAS per
  player; a full tournament (3 rounds) ~0.2 KAS per finalist.

## 2. Messages

All are JSON in the broadcast content. `type` is always `"chess_t"`, `v` is `1`, `t` is the
tournament id (a lowercase UUID chosen by the creator).

| `a` | Fields | Meaning |
|---|---|---|
| `create` | `t`, `name` (≤ 40 chars), `p` (2 or 8), `k` (8 only) | Opens a private 1v1 or tournament (§2.1). The creator is player 1. |
| `join` | `t` | Takes a seat (and opens a public room, §2.1). The first eight distinct addresses are the players; later joins are ignored. |
| `leave` | `t` | Gives a seat back while the room is still waiting (open). Ignored once it has started. |
| `cancel` | `t` | Private only, creator only, before the eighth join: the tournament is withdrawn. |
| `move` | `t`, `g`, `n`, `from`, `to`, `promo`? | A move in game `g` (`"<round>-<index>"`, e.g. `"1-3"`), `n` = the ply number (1 = white's first move), squares in algebraic (`e2`), `promo` in `q r b n`. |
| `resign` | `t`, `g` | The sender resigns game `g`. |
| `claim` | `t`, `g` | The sender claims game `g` on time: the opponent's clock had run out (§4). |
| `chat` | `t`, `g`, `text` (≤ 280) | A line under the board of game `g`. |

Example: `{"type":"chess_t","v":1,"t":"7c1e…","a":"move","g":"1-0","n":1,"from":"e2","to":"e4"}`

### 2.1 Public rooms and private tournaments

- **Public 1v1 rooms** are numbered `duel-1`, `duel-2`, ... with two seats, and work exactly
  like the public tournament rooms below: the first join opens a room, one takes players at a
  time, and it starts (a single game, seed 1 white) the moment the second player joins.
- **Public tournament rooms** are numbered `public-1`, `public-2`, ... and nobody creates them: the first
  `join` to a room opens it, whichever number it names, and the app shows "Public tournament #N"
  with its seats at all times. Which room is taking players is the client's choice, the same
  rule on every platform: **the lowest-numbered room still open (not full); when none is, one
  past the highest room the phone knows**. Two things keep every phone's view the same: the
  arena keeps the indexer's full 30-day window locally (never the short default retention -
  a phone that forgot yesterday's rooms overnight offered a room number the others had moved
  past), and a phone pulls the arena's newest rows from the indexer right before it picks a
  room, after waiting for the initial history on open. The leaderboard is computed from the
  same rows, so phones with the same window agree; beyond the window the indexer's
  `/chess/leaderboard` (§6) is the answer. (There
  used to be a rule that a join to room N counts only once room N-1 is full; it made every
  phone depend on the complete history back to room 1, and a phone missing the early rooms
  rejected every later one and queued alone. Dropped.) A `join` that arrives after the last
  seat went is ignored, and the app re-joins the next room by itself. Public rooms cannot be
  cancelled.
- **Private 1v1s** are for playing a friend: `create` with `p: 2` needs no code; the id is the
  code to share. They count on the leaderboard exactly like public games.
- **Private tournaments** are for friends. `create` (`p: 8`, or absent) needs `k` = first 24 hex chars of
  SHA-256(`CODE:id`), where CODE is the creator code (upper-cased, trimmed; `KACHAT-CHESS`
  as shipped - change `ChessTournamentCodec.privateCreateCode` on every platform to rotate
  it) and `id` is the tournament's eight-character id (`a-z 2-9`, no confusable letters).
  A `create` with a wrong or missing `k` is ignored by everyone. The id is the code the
  creator shares; `join` with it takes a seat. Private tournaments are listed only to their
  players.

## 3. Bracket

- **Seeds** are join order: the creator is seed 1, the eighth joiner seed 8. The tournament
  starts at the block time of the eighth join.
- **Round 1:** games `1-0` … `1-3` are seeds 1v8, 2v7, 3v6, 4v5. **Round 2:** `2-0` = winner
  of `1-0` v winner of `1-1`, `2-1` = winners of `1-2` and `1-3`. **Round 3** (`3-0`) is the
  final. A round-2 or final game starts at the block time of the message that decided the
  later of its two feeding games.
- **Colours:** in round 1 the lower seed is white. Afterwards, the player who has had white
  fewer times in this tournament is white; if equal, the lower seed.
- **Seats expire.** A seat in a waiting room lasts five minutes from the join. A room that
  has not filled by then has lost that seat: at the next `join` to the room, every phone first
  drops seats older than five minutes (judged at that join's block time), then seats the
  joiner. So a player who closed the app, or walked away, is out of the queue by themselves
  - no message needed - and a room can never fill with players who left long ago. The app
  shows the time a seat is held for, and the lobby counts only live seats.
- A game with no message from one player is still a game: its clock runs from the start
  (§4). There is no "waiting for both players": if you are not there, you lose on time.

## 4. Clocks and results

- **5 minutes per side, no increment.** Time is measured in *chain time*: a player's clock
  is charged the block time of their move minus the block time of the previous event
  (the opponent's move, or the game start), **less the move's allowance**: 25 s for a side's
  first move (ply 1 and ply 2), 10 s for every move after (`ChessTournamentCodec.moveDelayMs`,
  `firstMoveGraceMs`, `allowanceMs(ply:startedAt:)`; the charge is `max(0, elapsed - allowance)`).
  **The allowances apply to games started at or after `allowanceFromMs` = 1790208000000
  (2026-09-24 00:00 UTC); earlier games have none.** A rule change never reaches back: the
  games before it were decided under the rules of their day, and re-judging them re-opened
  finished games (a claim valid at 5:00 became "early" under the grace) and let a player resign a finished
  game for a second loss. Any future clock rule change gets its own activation instant the
  same way, shipped identically on every platform. The
  ten seconds cover what a move spends reaching the other phone - a block, the indexer's
  poll - so propagation is nobody's thinking time. The 25 s is the gate on a simultaneous
  join: the game starts at the second join's block time, but neither clock runs until that
  side has shown up with a move, so nobody loses time before their phone has even shown the
  board. A side that never shows up is not stuck either: after the 25 s their five minutes
  run and the opponent claims. The phone shows the side to move's clock from the last
  event's block time by its own wall clock, frozen while the allowance lasts. Whatever a
  phone claims about its own thinking time is irrelevant; the chain decides.
- **Flagging:** when the side to move's remaining time reaches zero, the *opponent* posts
  `claim`. Everyone accepts it if, at the claim's block time, the mover's clock had indeed
  run out (the same allowance applies: elapsed − allowance ≥ remaining). A claim that
  arrives early is ignored. (The app posts the claim itself the moment
  it sees the opponent flagged.) A player may also resign.
- **Game over:** checkmate (mover wins), resignation, time claim, or a draw (stalemate,
  insufficient material, fifty moves, threefold repetition). Knockout needs a winner, so a
  **draw goes to the player with more clock left**; if equal, to black.
- **Reconnecting:** leaving the app does not stop your clock. Come back within your remaining
  time and play on; otherwise the opponent claims the win. (The clock IS the grace period - a
  separate one-minute rule would be shorter than a long think in a five-minute game.)
- Ply `n` must be exactly the next ply; the sender must own the side to move; the move must
  be legal from the current position. Anything else is ignored and the game is unchanged.

## 5. Spectating and the lobby

- **Match found.** When a room fills, every phone shows "Match found" (or "Tournament
  full") with a countdown and opens the board at `startedAt + 10 000 ms` of chain time
  (`ChessTournamentCodec.matchFoundDelayMs`) - the same instant everywhere, so the players
  arrive together; a phone that learns of the start later than that opens the board at once.
  It is display only (nothing on chain), and it sits inside the first-move grace (§4), so it
  costs nobody clock. Leaving is off once the room has filled.

- The lobby shows the public room taking players, the player's own private tournaments,
  public tournaments in play and recently finished. Anyone can open a public tournament and
  watch any game live, since all games are the same public stream.
- A winner waiting for the next round can watch the other game of their pair; the moment it
  ends their game exists (§3) and their screen switches to it.

## 6. Leaderboard (indexer handoff)

The leaderboard is two boards, by address, over the games played here - never the casual
games inside 1:1 chats:

- **1v1**: wins and losses in 1v1 games (`duel-N` rooms and private 1v1s). Most wins first,
  fewest losses breaking ties.
- **Tournaments**: tournaments won (champion of an eight-player bracket), then wins and losses
  in the games inside tournaments. Most tournaments won first, then most game wins, then
  fewest game losses. A 1v1 never counts here.

`wins`/`losses` in the row below are the totals over both. For the full history the KaChat
broadcast indexer must:

1. **Track `chess-arena`** like the curated rooms (30-day history served by `/get-broadcasts`),
   so a phone that opens Chess sees every tournament of the last month, not only what it
   scanned itself. **This one is a config change, and it is what makes two phones find each
   other:** add the channel to the broadcast indexer's allowlist -
   `CHANNELS: "kaspa,kachat-bugs,chess-arena"` in its `docker-compose.yml` - and restart it.
   The app already polls `/get-broadcasts?channel=chess-arena` every 8 s while Chess is open
   and merges what comes back. Without it a phone only learns of a join or a move it
   happened to scan live from a block, so the other player's join is missed whenever the
   phone was locked, reconnecting, or not yet on the Chess screen when it landed.
2. **Serve `GET /chess/leaderboard?limit=100`** →
   `{"players":[{"address":"kaspa:…","wins":12,"losses":4,"duelWins":9,"duelLosses":3,"tournamentGameWins":3,"tournamentGameLosses":1,"tournamentsPlayed":5,"tournamentsWon":2,"lastPlayedAt":<ms>}], "generatedAt":<ms>}`,
   sorted by `wins` desc, then `losses` asc (the phone sorts each board itself, see
   `ChessTournamentEngine.duelLeaderboard` / `tournamentLeaderboard`). Computed by replaying the arena with the
   rules above (the reference reducer is `ChessTournamentEngine.swift` in this repo; port it,
   do not reinterpret it). Also `GET /chess/player?address=` → the same row for one player.
3. Optional: `GET /chess/tournaments?status=open|live|done&limit=` → the lobby list
   precomputed, for phones that want it without scanning.

Until (1) and (2) exist the lobby shows what the phone has scanned in-session plus whatever
the store retains, and the leaderboard is local.
