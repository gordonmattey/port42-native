# Design: every port has a chat (nautilus Phase 1 step 5)

Draft for GM's review, revised 2026-09-25 after GM's direction: there is no separate chat port. Chat is
part of every port (web, terminal, browser), opened from an icon in the port's chrome beside its other
action buttons. Nothing here is built.

## What exists today

- **One native chat tile per space** (`isChatPort`, rendered by `ChatView` and `ConversationContent`,
  about 1,800 lines of SwiftUI). Its transcript is the `messages` table, including inline ports from
  fences and a `[portref]` card for every port created in the space.
- **A mention reaches a companion** through `routeMentionsToTerminals`: parse `@name`, find the
  companion in `agentSpaces`, respawn its terminal if closed, type the message in. The shim's
  end-of-turn hook posts the reply back as a message.
- **What does not work:** a message sent through the API speaks as the person (F16), the chat is not
  reachable by a browser guest, and its layout is the likeliest driver of the 70-second stall (F18).

## The shape

**Every port carries a chat.** A chat icon sits in the port's chrome with its other actions. It opens
that port's chat as a panel attached to the tile. A space is a port, so the space's own chrome opens
the space's chat. Port 0's chrome opens the desktop's.

**The transcript belongs to the port.** An append-only list in the storage service under the port's
key (D1, D3). It survives restart, eviction and remount, and it goes when the port is closed for good.

**Everything enters through one door.** A person typing in the panel, a companion replying, and an API
caller all post to the port's chat through one registry method. The app records who said it from the
caller's principal (fixes F16), appends, and publishes a `chat` event on the port's topic.

**A mention is an event, and a companion is a subscriber.** A companion attached to a port or a space
subscribes to that chat. On a mention the router does what `routeMentionsToTerminals` does today: wake
the companion's terminal and type the message in. The shim's end-of-turn hook posts the reply back into
the chat the mention came from. `agentSpaces` becomes the subscription list.

**A terminal port's chat is its companion's session.** A message there is typed into the terminal, and
the reply lands back in the same chat. This is Echo's first-run conversation.

**A browser guest sees the chat of the port it was invited to.** The guest page draws the same panel
from the same events.

## What goes with it

`ChatView`, `ConversationContent`, the space chat tile, inline ports and port fences (D11),
`[portref]` cards, the `messages` table and its observation, `input_history`, and the unread counters
built on messages.

## Build order

1. The registry method, the per-port transcript in storage, principal-stamped entries, the `chat`
   event. Tested headless.
2. The chat panel and the chrome icon, on every port type.
3. The router subscribes companions and the shim replies into the chat. Scenario 1 moves to a space's
   chat.
4. Remove the space chat tile, the native chat views and the `messages` table.
5. Port 0's chat.

The harness gains a check at step 3: a companion's reply lands in the chat attributed to the companion,
and a post through the API is attributed to its caller.

## Decided (GM, 2026-09-25)

1. **Old transcripts are dropped** with the `messages` table. This is a breaking upgrade; nothing is
   imported.
2. **The panel slides down from the companion bar.** The bar at the top of a port shows who is in its
   chat as profile pictures, the way the chat tile's header does today. Clicking it slides the chat
   down over the port.
3. **Unread lives in that bar.**
