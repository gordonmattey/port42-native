# Append writes: the token is two things wearing one name

**Opened 2026-07-31**, from GM's question about whether a port could declare itself multi-append, and
whether that needs a different mechanism or just a faster path. Written before any code, because it
changes the token contract and that deserves an argument on paper.

## The observation

Two kinds of write exist and we have been treating them as one.

**State writes replace what is there.** `getHtml` then `patch`, `update`. Two writers genuinely
conflict: whoever writes second erases the first unless something stops them. CAS on the port's token
is exactly right, one driver at a time is the correct model, and `stale_write` carrying `current` is
what lets a loser self-correct in one retry.

**Append writes add to something.** A chat message, a line typed into a terminal, console output, a
log. **Two writers cannot conflict.** Both appends land. There is nothing to overwrite, so there is
nothing for a precondition to protect.

## Why it currently feels wrong, in one measurement

`port.push` demands a token. Pushing a line into a terminal on 2026-07-31 was refused with
`token_required`, then required a read to obtain `current`, then succeeded — three round trips to
type one line into a shell, where nothing could possibly have been overwritten.

That is not a bug in CAS. It is CAS applied to a write that has no conflict to prevent.

## The resolution: not a new mechanism, a separated one

**The token is doing two jobs under one name**, which is the disease this codebase keeps finding:
`sender_id` addressed and authorized; `companionId` and `companionPrompt` both meant "is a
companion"; the space sat in the object slot and impersonated it. Every time, the fix was to name the
two jobs rather than to add a mechanism.

| job | what it is | who needs it |
|---|---|---|
| **sequence** | `<epoch>:<seq>`, monotonic per port. The ordering key every Notify carries (§10c) and the thing that lets a subscriber tell a gap from a reorder | **every** write, append included |
| **precondition** | "I composed this against `<token>`; refuse me if the port has moved" | **state writes only** |

So an append still ADVANCES the token, and is never REFUSED by it.

**Advancing matters and is easy to lose.** §10c made the token the display ordering key precisely so
no sequence field was needed. If appends ignored the token outright rather than skipping the check,
chat and terminal output would lose their ordering key and Notify would need a second one, which is
the same field arriving under a different name.

## What this buys

- **N writers on a chat work by construction**, with no right-of-way, no driver, no contention. This
  is the honest answer to "how does a shared chat behave with three people and two companions", and
  it needs neither the N-peer concurrency work nor CRDTs
- **`port.push` into a terminal stops demanding a read first**, removing two round trips from the
  most common write in the product
- **`isRetryableWithCurrentState` keeps meaning what it says.** An append can never produce
  `stale_write`, so it never invites a retry that cannot fail

## What declares it

Not the method, because the same verb differs by port. Terminal push is unambiguously append. Web
port push delivers an event to JS, and what the port does with it is the port's business: it may
append to a list or replace its whole state (GM, 2026-07-31: "web port depends").

So the **port** declares it, which is also the shape `BridgeStreamMethod.endless` already uses: a
property of the thing, declared rather than inferred from a name, so the behavior cannot drift from
the description.

A first cut:

| port kind | state writes | appends |
|---|---|---|
| chat | — | messages |
| terminal | — | input, output |
| web | `patch`, `update`, `getHtml` | `push`, IF the port declares it |
| browser | navigation | — |

## Open questions

1. **Can one port have both?** A web port that appends to a log and also replaces its HTML is
   plausible, which argues the declaration belongs to the WRITE rather than the port. That reopens
   the "not the method" reasoning above, and the answer is probably that the port declares which of
   ITS writes are appends, rather than declaring itself wholly one or the other.
2. **Does an append need any precondition at all?** Existence, presumably: appending to a port that
   is gone should fail. That is `not_found`, not `stale_write`.
3. **Ordering between writers.** Appends cannot conflict, but they can interleave. For chat that is
   correct and expected. For terminal INPUT it may not be: two writers typing into one shell
   interleave into one command line, which is a genuine mess. That may be an argument for terminal
   input being a state write after all, or for right-of-way on input specifically.
4. **Does this change the wire half?** It should reduce it: an append needs no `current` round trip
   and no retry, which is one less thing to prove over a link with real latency.
