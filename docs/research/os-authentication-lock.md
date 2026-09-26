# Making the lock screen a real boundary

Research note, 2026-09-26. Future work, not scheduled. Written because the lock screen currently
implies a boundary it does not have.

## What exists

`AppState.lockApp()` sets `showDreamscape = true`. `AppState.unlock()` sets it to false and restores
the last view. No credential is checked, nothing outside the UI reads the state, and the gateway
continues answering calls throughout. The permission work observed the same thing from the other
side: a permission card raised while locked has no render site, so the call waits and the gateway
answers `timed_out` after 30 seconds.

So the lock screen is presentation. Walking away from an unlocked machine with Port42 "locked"
protects nothing, and a remote caller with a grant is unaffected by it.

## The decision

GM, 2026-09-26: "you can't use the app without unlocking, simple. lock shouldn't stall running work,
my computer locks but processes still run."

That is the macOS model and it settles the design:

- **Unlocking requires OS authentication.** `LocalAuthentication` with `.deviceOwnerAuthentication`,
  so Touch ID, Apple Watch or the login password. No second credential to manage.
- **The lock gates the human, not the machine.** The UI is inaccessible until authenticated.
- **The bridge keeps serving.** Agents, companions, `/imagine` teams and terminals run through a lock
  exactly as processes do through a screen lock. Nothing is queued, nothing stalls, nothing is killed.

So the boundary is the interface, not the API, and that is a coherent position rather than a
compromise: a screen lock on any OS stops a person at the keyboard and does not stop `cron`.

**The one case where the two halves meet:** a caller asks for a capability it has no grant for while
the shell is locked. There is nobody to approve. Today the card is enqueued with no render site and
the gateway answers `timed_out` after 30 seconds, which tells the caller nothing true.

**A queue, and the call does not block on it** (GM, 2026-09-26). Those are two decisions and the
second is what makes the first work.

Refusing outright loses overnight work: an agent that needs a capability at 2am fails, and the run is
dead by morning. Blocking until someone unlocks is worse: the caller hangs for hours, holds whatever
it holds, and every timeout in the chain fires anyway.

So the request is **persisted and the call returns immediately** with a distinct pending result
naming the request. The caller decides what to do: wait and poll, continue without that capability, or
park itself. When the shell unlocks, the queue is presented. A decision wakes the caller, which is the
same mechanism Phase 3 uses to wake a rested subscriber.

What that needs:

- **A distinct outcome.** Not `timed_out`, not `permission_denied`. Something a caller can act on,
  meaning approval is pending and nobody is at the machine.
- **Persistence and expiry.** The request survives a restart, and it ages out. A request from three
  days ago should not be approvable without being re-raised, because nobody remembers what it was.
- **Context at decision time.** Who asked, what for, what they were doing, and when. Approving a
  prompt you cannot place is how people learn to approve everything.
- **Bounds and coalescing.** `PermissionCoordinator` already coalesces on `(principal, permission)`.
  The queue needs the same, plus a cap, or one looping agent fills it overnight.
- **Batch decisions.** Forty items reviewed one dialog at a time is a queue that gets cleared rather
  than read.

The failure mode to design against is not a missed prompt. It is waking to a long queue and
approving it wholesale, which grants more than any single prompt ever would.

## The platform primitive

`LocalAuthentication`'s `LAContext` with `.deviceOwnerAuthentication` covers biometry with a password
fallback, which is what a user expects from a Mac. It answers "is the owner here", not "here is a
key", so it authenticates a moment and nothing more. Two consequences worth stating up front:

- **It is not a key.** The result is a boolean in the app's own process. Anything that can modify the
  app can bypass it. This raises the bar for a passer-by, not for a process running as the user, and
  the threat model already places that process outside scope.
- **If the lock should protect data rather than attention**, the primitive is different: a key in the
  Keychain with `.userPresence` or `.biometryCurrentSet` access control, which makes the system
  release the key only after authentication, and that key encrypts something. That is the version
  that survives someone copying the database file, and it is a materially larger piece of work,
  because everything that reads the database while locked has to stop.

## What this is and is not

It gates the interface. Someone at the keyboard cannot use Port42 without authenticating as the
machine's owner. That is the whole claim, and it should be described that way rather than as
protecting data.

It does not protect data at rest. `LocalAuthentication` returns a policy evaluation in the app's own
process, not a key, so anything able to modify the app or read the database file is unaffected. A
process running as the user is already outside the threat model. If data at rest becomes the goal,
the primitive is different: a Keychain key with `.userPresence` or `.biometryCurrentSet` access
control, released by the system only after authentication, encrypting the store. That is a separate
project, and everything that reads the database while locked would have to stop, which conflicts
directly with the decision above.

## Open

- **A remote peer's view of a locked host.** Normal, presumably, since the bridge keeps serving.
  Worth confirming that the lock state is not disclosed, because it says whether someone is present.
- **Re-lock policy.** On sleep, on a timer, on the OS screen locking, or only by hand.
- **The failure path.** Authentication cancelled, unavailable (no biometry enrolled, headless), or
  failing repeatedly. A machine with no way to authenticate must not become a machine that cannot be
  used.
