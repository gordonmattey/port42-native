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

## What a real lock would have to decide

Three questions, in order. The third is the one that makes this work rather than a dialog.

**1. What does unlocking prove?** Options: macOS user authentication (`LocalAuthentication`, which
gives Touch ID, Apple Watch and the login password through one API and returns a policy evaluation
rather than a secret); a separate Port42 passphrase; or presence only, where unlocking is a gesture
and the lock is a privacy screen. The first is the only one that is both familiar and not a second
credential for the user to manage.

**2. What is protected while locked?** The lock is worth nothing until something refuses. Candidates,
increasing in cost:
   - the UI only, which is today,
   - plus the bridge for callers that are not already granted,
   - plus the bridge entirely, which breaks every running agent and is probably wrong,
   - plus data at rest, which is a different project (see below).

**3. What happens to agents?** This is the question that decides the design. A companion mid-task,
a `/imagine` team, a terminal running a build: locking the screen must not kill them, and must not
silently queue their calls until a human returns. A lock that stalls work is a lock people disable.
The likely answer is that a grant made before the lock keeps working and a new consent cannot be
given while locked, which means a permission request during a lock must fail fast and legibly rather
than time out, which is a defect already recorded.

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

## The honest framing

There are two products here and they should not be confused.

**A privacy screen** hides the desktop from someone walking past and costs almost nothing: an
`LAContext` evaluation in front of the existing `unlock()`. It is worth doing, and it should be
described as what it is.

**A security boundary** means the gateway refuses, the data is at rest, and agents have a defined
behavior across the transition. That is real work and its first requirement is knowing what it is
defending against, which is not currently written down.

Doing the first and calling it the second is worse than doing neither, because it produces exactly
the false assurance the current screen already produces.

## Open

- **Does the gateway refuse while locked?** This is the decision the rest follows from, and it
  conflicts with agents running unattended, which is the product's main use.
- **What does a headless instance do?** A machine running Port42 for its agents has nobody to
  authenticate, so a lock that gates the bridge makes it unusable.
- **Does a remote peer see a locked host as unavailable, or as normal?** Either answer leaks
  something: the first leaks presence, the second contradicts the lock.
- **What is actually at risk on an unattended unlocked Mac** that the OS screen lock does not already
  cover. If the answer is nothing, this is a privacy screen and should stay one.
