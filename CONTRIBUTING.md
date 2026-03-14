# Contributing to Port42

Port42 is open source (MIT) and we welcome contributions. Here's how to swim in.

## Bug fixes

Found a bug? Fix it and open a PR. No process needed beyond:

1. Fork the repo
2. Create a branch
3. Fix the bug
4. Write a clear commit message explaining what broke and why
5. Open a PR

If the fix is non-obvious, include steps to reproduce.

## Small improvements

Typos, docs, performance fixes, test coverage. Same as bug fixes. Just open a PR.

## New features and major changes

Major changes require a **Port42 Proposal (P42P)** before any code is written.

Port42 is a communication protocol. Changes to the protocol affect everyone. A companion built today should still work tomorrow. P42Ps make sure we think before we ship.

### What counts as major?

- New user-facing features
- Changes to the protocol (message format, encryption, handshake)
- Changes to the port bridge API (`port42.*`)
- Architectural changes (new modules, restructured data flow)
- Removing or changing existing behavior

### The P42P process

1. **Open an issue** titled `[P42P] Your feature name`
2. **Fill out the P42P template** (see below)
3. **Discussion happens in the issue.** Ask questions, raise concerns, refine the idea.
4. **Maintainer approval.** A maintainer will approve, request changes, or close with explanation.
5. **Build it.** Once approved, implement and open a PR referencing the P42P issue.

### P42P template

A P42P has two parts: the **spec** (what it is) and the **implementation plan** (how to build it). Both are required.

#### Part 1: Spec

```markdown
## Summary

One paragraph. What are you proposing and why?

## Status

Draft | In Discussion | Approved | Building | Complete

## User Flows

For each distinct user interaction:

### Flow N: Name

    User does X
    → System does Y
    → User sees Z

Target: One sentence describing the quality bar.

## Architecture

ASCII diagram showing where this fits in the system. How data flows
through existing and new components. See ports-spec.md for reference.

## Feature Registry

Enumerate every discrete feature with an ID, description, priority, and
"done when" acceptance criteria.

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| XX-100 | Feature name | What it does | High/Med/Low | Observable outcome |

## Protocol Changes

If the proposal changes the wire protocol, message format, bridge API,
or encryption, specify the exact changes. Include method signatures,
data shapes, and backwards compatibility notes.

## Sandbox and Security

How does this interact with the port sandbox, CSP, and permission model?
What new permissions are required? What attack surface does this add?

## Open Questions

What needs more thought? What are the tradeoffs?
```

#### Part 2: Implementation Plan

```markdown
## Constraint

What must NOT break. (e.g., "No breaking changes. All existing chat,
swim, and sync functionality must continue working at every step.")

## Build Steps

For each step:

### Step N: Name (Feature IDs)

**Goal:** One sentence.

**Files to create:**
- path/to/NewFile.swift — what it does

**Files to modify:**
- path/to/ExistingFile.swift — what changes

**What to build:**

Numbered list of specific implementation tasks. Include method signatures,
data structures, and integration points.

**Unit tests:**
- testName — what it verifies

**User test:**
- Manual verification steps. What to try, what to observe.

## Build Order Summary

ASCII timeline showing the dependency chain across steps.

    Step 1:  Feature name  → observable outcome  ← NEXT
    Step 2:  Feature name  → observable outcome
    Phase N complete ──────────────────────────
```

### Examples

See `docs/` for real P42Ps that shipped:

- `docs/ports-spec.md` — the ports feature spec
- `docs/ports-implementation-plan.md` — the ports implementation plan
- `docs/e2e-encryption-plan.md` — end-to-end encryption
- `docs/openclaw-channel-adapter-spec.md` — OpenClaw integration

## Code style

- Swift: follow the existing patterns in the codebase
- No SwiftLint or formatter enforced (yet), just be consistent
- Port bridge JS: vanilla JS, no frameworks, keep it minimal

## Signing commits

Not required but appreciated.

## Questions?

Open an issue or find us in a Port42 channel.
