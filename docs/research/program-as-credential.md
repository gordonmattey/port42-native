# The program as the credential

Measured against `nautilus` at `0369388`, 2026-09-26, on Darwin 24.6.0 with the macOS 26.3 SDK. A
research note, not an approved plan. Item 1 in the research order in `docs/research/README.md`, from
the Future roadmap in `plan-shell-only.md`: "authenticate a caller by its code signature, not a
token."

## Verdict

**The mechanism does not exist on the transport Port42 uses, and the identity it would name is the
wrong one.**

Three findings, in the order they kill the idea:

1. **The app never holds the caller's socket.** A `/call` arrives at the gateway, a separate process,
   which forwards it to the app over a WebSocket the *app* dialed out. The app's only socket peer is
   `port42-gateway`. Measured live (`lsof`): `Port42 22638 … 127.0.0.1:62562->127.0.0.1:4242
   (ESTABLISHED)`. Any peer-identity mechanism would have to live in the gateway and be forwarded as
   a claim, at which point it is a token again.
2. **On TCP loopback there is no supported way to learn the peer's process, and the obvious attempt
   fails open.** `SOL_LOCAL` is `0`, which on an `AF_INET` socket is `IPPROTO_IP`, and the six
   `LOCAL_PEER*` option numbers collide exactly with `IP_OPTIONS` through `IP_RECVRETOPTS`. A
   `LOCAL_PEERCRED` call on a TCP socket therefore **returns success with `uid = 0`**. Measured
   below. There is one working technique (a `libproc` FD-table scan), it is unsupported-tier, and it
   is racy by construction.
3. **The program on the other end is `curl`.** Port42's own instructions teach `curl` at `/call`,
   gated by `InstructionService`. Measured: `/usr/bin/curl` is `com.apple.curl`, Apple platform
   signed, `TeamIdentifier=not set`. Every agent, every tool and every script would present the same
   signing identity, so a signature cannot distinguish the callers the grant model exists to
   distinguish.

Two measured defects found on the way, both worth fixing regardless of this item:

- **The shipped `port42` CLI is ad-hoc signed.** `dist/Port42.app/Contents/MacOS/port42-cli` reports
  `Identifier=a.out`, `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not set`, inside a
  notarized bundle whose gateway and shim both carry `Developer ID Application: Gordon Mattey
  (5R5X43WDXE)`. `build.sh:383` signs `$MACOS/port42`; `build.sh:326` bundles the file as
  `port42-cli`. The rename at `build.sh:309-313` did not carry to the signing line, so the binary
  keeps whatever the Go linker gave it.
- **`LOCAL_PEERCRED` returning `uid = 0` on a TCP socket is a trap with a live consumer class.** Any
  future code that reaches for kernel peer credentials without both checking the return length and
  asserting `AF_UNIX` grants root. Recorded here because `plan-caller-identity-fixes.md:79-80` already
  names "a unix socket with kernel peer credentials" as the deferred fix, so this is the first thing
  whoever picks it up will write.

The problem the item was reaching for is real and is stated in the tree already
(`membrane/slice-02-cross-instance.md:824`): *a token file is readable by anything with the user's
uid*. A code signature does not solve it. The reachable part of it is **non-transferable
credentials** (§6), which is a different mechanism and does not need a signature at all.

---

## 1. What identifies a caller today

One `/call`, traced end to end. Identity is asserted in exactly one place, stored in two, checked in
one, and keyed in one. Nothing anywhere records or examines a program.

| # | Where | What happens |
|---|---|---|
| 1 | `GatewayProcess.swift:90` | The gateway is spawned with `["-addr", "127.0.0.1:\(port)", "-watch-parent"]`. Loopback TCP, no unix socket. |
| 2 | `gateway/main.go:43` | `/call` routes to `gw.HandleHTTPCall`. |
| 3 | `gateway/gateway.go:310-317` | The request body is decoded into `{method, args}` and nothing else. `r.RemoteAddr` is never read; the connection is never inspected. |
| 4 | `gateway/gateway.go:390` | `Credential: BearerToken(r.Header.Get("Authorization"))`. **The only identity input on this door.** |
| 5 | `gateway/credentials.go:85-91` | `BearerToken` parses the header and returns a string. It never verifies. `credentials.go:20-22`: "Client tokens are verified by the APP, which is also the only thing that mints them." |
| 6 | `gateway/gateway.go:361-376` | `sender_id` is fixed to the constant `local-http` and documented as a routing address only, deliberately inert: "Nothing anywhere authorizes on `sender_id`." |
| 7 | `gateway/gateway.go:394` | The envelope is forwarded to the host peer over that peer's WebSocket. |
| 8 | `GatewayDoor.swift:140-155` | The app is the WebSocket **client**: it dials `ws://127.0.0.1:<port>/ws` and identifies as host with the per-spawn host credential. It never accepts a caller's socket. |
| 9 | `GatewayDoor.swift:234-235` | The frame reaches `onCallReceived(senderId, callId, method, args, credential, emit)`. |
| 10 | `AppState.swift:913-943` | The closure. `AppState.swift:933` calls `resolveGatewayCaller`. |
| 11 | `AppState.swift:602-648` | **The one place a gateway caller's identity is decided.** Four gates: a credential is present (`:604`), the HMAC verifies against this instance's root secret (`:614`), the client row exists (`:628`), the row is not revoked (`:639`). No fallback; an unnamed caller is refused with `auth_required`. |
| 12 | `ClientRegistry.swift:149-156` | `verify(token:secret:)`. Format `p42_<id>_<mac>`, `mac = base64url(HMAC-SHA256(rootSecret, id))` (`:132-143`), constant-time compare (`:158-165`). Stateless: it consults no table. |
| 13 | `ClientRegistry.swift:337-356` | The token at rest: `~/.port42/<instance>/tokens/<id>`, mode 0600 inside a 0700 directory. |
| 14 | `ToolExecutor.swift:171` | `Principal.peer(id: senderId, displayName: senderName)`. The verified client id becomes the authorization identity. |
| 15 | `Principal.swift:87-89`, `:60-66` | The `peer` factory. The memberwise init is private so all identity policy lives in one file, enforced by `PrincipalConstructionTests` scanning the package. |
| 16 | `BridgeDispatcher.swift:50-53` | The permission gate: `ensurePermission(perm, for: principal, pregrant:)` or `permissionDenied`. |
| 17 | `BridgeDispatcher.swift:110-119` | The gate reads and writes grants keyed `(principal.id, PortObject.machine, principal.spaceId)`. |
| 18 | `PortObject.swift:137-140` | `PortGrantKey.key` → `portGrant.<grantee>.<object>.<zone>`. |
| 19 | `DatabaseService.swift:673-687` | The `grants` table. Primary key `(grantee, object, zone, permission)`. `grantee` is the principal id, which for a gateway caller is the client id. |
| 20 | `DatabaseService.swift:701-708` | The `clients` table: `id`, `name`, `kind`, `createdAt`, `lastSeenAt`, `revokedAt`. **No path, no program, no signature, no pid.** |
| 21 | `PermissionCoordinator.swift:99` | `request(_:from principal:)` renders the human-facing card, coalesced on the Principal (`Principal.swift:173-176`: identity is `(id, displayName, spaceId, kind)`). |

**Zero code-signature machinery exists in the tree.** A grep for `SecCode`, `SecStaticCode`,
`SecRequirement`, `audit_token` and `LOCAL_PEERCRED` across `Sources/`, `gateway/`, `cli/` and `shim`
returns one hit, a comment in `BundleHelper.swift:7` about where resources must live.

**The enrolment kinds** (`ClientRegistry.swift:36-54`) are the population a signature would have to
cover: `paired` (a caller the user approved), `child` (a terminal or agent the app spawned, no
prompt, because the spawn is the consent), `manual` (added by hand, for scripts and cron), and
`installed` (the `port42` CLI, enrolled at install). Three of the four are things a user brings, not
things Port42 ships.

---

## 2. What a code signature can prove on macOS

### 2.1 The measured per-transport result

Probe: `scratchpad/peercred.c`, a process that opens both an `AF_INET` loopback listener and an
`AF_UNIX` listener, connects to each from a thread in the same process (pid 68499), and calls every
`SOL_LOCAL` option on the accepted socket.

```
pid of this process = 68499

AF_INET server on 127.0.0.1:63751
  [AF_INET / 127.0.0.1 accepted socket]
    LOCAL_PEERCRED   OK  version=0 uid=0 ngroups=0 len=0
    LOCAL_PEERPID    FAIL errno=42 (Protocol not available)
    LOCAL_PEEREPID   OK  pid=0 len=4
    LOCAL_PEERUUID   OK  len=4
    LOCAL_PEEREUUID  OK  len=4
    LOCAL_PEERTOKEN  OK  len=4 pid_from_token=0

AF_UNIX server on /tmp/p42-peercred-test.sock
  [AF_UNIX accepted socket]
    LOCAL_PEERCRED   OK  version=0 uid=501 ngroups=16 len=76
    LOCAL_PEERPID    OK  pid=68499 len=4
    LOCAL_PEEREPID   OK  pid=68499 len=4
    LOCAL_PEERUUID   OK  len=16
    LOCAL_PEEREUUID  OK  len=16
    LOCAL_PEERTOKEN  OK  len=32 pid_from_token=68499
```

Over `AF_UNIX` every option works, including `LOCAL_PEERTOKEN`, which hands back a 32-byte
`audit_token_t` whose pid matches. Over `AF_INET` **five of the six return success and lie**, and the
sixth returns an error only by accident.

The cause, confirmed from the SDK headers:

```
sys/un.h:85       #define SOL_LOCAL        0
sys/un.h:88-93    LOCAL_PEERCRED 0x001 … LOCAL_PEERTOKEN 0x006
netinet/in.h:97   #define IPPROTO_IP       0
netinet/in.h:405  #define IP_OPTIONS       1
netinet/in.h:406  #define IP_HDRINCL       2
netinet/in.h:407  #define IP_TOS           3
netinet/in.h:408  #define IP_TTL           4
netinet/in.h:409  #define IP_RECVOPTS      5
netinet/in.h:410  #define IP_RECVRETOPTS   6
```

`SOL_LOCAL` and `IPPROTO_IP` are the same number, and options 1 through 6 are the same numbers. On an
`AF_INET` socket the call is dispatched to `ip_ctloutput`, which answers the *IP* option of that
number. `LOCAL_PEERCRED` reads `IP_OPTIONS`, which is empty, so it returns `len = 0` over a
zero-filled buffer. `LOCAL_PEERPID` reads `IP_HDRINCL`, valid only on raw sockets, which is the one
that errors (`ENOPROTOOPT`, 42).

**A zero-filled `xucred` has `cr_version = 0`, which equals `XUCRED_VERSION` (`sys/ucred.h:106`), and
`cr_uid = 0`.** So the two checks a careful implementer writes, "did getsockopt succeed" and "is the
version right", both pass, and the answer is root. The only defenses are asserting the returned
length and asserting the socket family. This settles item 1 on the sub-agent research's
could-not-determine list with a direct measurement, and finds a stronger result than "it returns an
error".

`LOCAL_PEER*` are in the public SDK (`sys/un.h`, guarded only by
`!defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)`, not by `PRIVATE`), and are implemented by
the unix-domain protocol's own `pr_ctloutput` in
[`xnu/bsd/kern/uipc_usrreq.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_usrreq.c).
Whether Apple considers `LOCAL_PEERTOKEN` sanctioned for third-party use is **unknown**: it is a
header-only symbol with no documentation page, sample or forum guidance found.

### 2.2 From a pid to a signing identity: the public path works

Probe: `scratchpad/sigfrompid.c`. It uses only public API, calling
`SecCodeCopyGuestWithAttributes(NULL, {kSecGuestAttributePid: pid}, …)`, then
`SecCodeCopySigningInformation`, then `SecCodeCheckValidity` against a requirement string. Run
against the invoking shell, it reports:

```
SecCodeCopyGuestWithAttributes(pid=69868) -> 0
SecCodeCopySigningInformation -> 0
  identifier             com.apple.zsh
  teamIdentifier         (absent)
  flags                  0x0
  certificates           array of 3
  check 'anchor apple'         -> 0 PASS
  check 'anchor apple generic' -> 0 PASS
```

So the second half of the chain is real, public, and cheap. `kSecCodeInfoTeamIdentifier` is declared
at `Security.framework/Headers/SecCode.h:497`. What is missing is only the first half: getting a
trustworthy pid.

`SecCodeCreateWithAuditToken` is **private**, declared in `SecCodePriv.h`, not in the public SDK.
`xpc_connection_get_audit_token` is likewise absent from the public XPC headers (grep of
`$SDK/usr/include/xpc/` returns nothing), which matches Apple DTS guidance in
[forums thread 716635](https://developer.apple.com/forums/thread/716635) and
[681053](https://developer.apple.com/forums/thread/681053). The public route to a `SecCode` from a
token is `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributeAudit`
(`SecCode.h:127`).

### 2.3 Apple's blessed transport is XPC, and only XPC

`SecCode.h:200-213` declares `SecCodeCreateWithXPCMessage(xpc_object_t message, …)`, guarded by
`#if TARGET_OS_OSX`. The family Apple has built out is XPC-only:

| API | Since | What it does |
|---|---|---|
| `SecCodeCreateWithXPCMessage` | macOS 11 | A `SecCode` from an XPC message, no raw audit token |
| `xpc_connection_set_peer_code_signing_requirement` | macOS 12 | XPC enforces a requirement before your handler runs |
| `-[NSXPCConnection setCodeSigningRequirement:]` | macOS 13 | Same, Obj-C |
| `xpc_connection_set_peer_lightweight_code_requirement` | macOS 14.4 | Same, lightweight |

There is no socket equivalent. "The program as the credential" is a first-class macOS idea **only for
XPC**, and Port42's door is HTTP over TCP, reached by `curl`, by a browser, and by any language's
HTTP client. Moving the door to XPC would mean every caller links `libxpc` and speaks Mach, which
ends the "a shell script with curl is a caller" property entirely and does not serve the remote lane
at all.

### 2.4 The one technique that does work over TCP loopback, measured

Probe: `scratchpad/fdscan.c`. A TCP loopback listener that, on each accept, enumerates every pid
(`proc_listpids`), lists each one's descriptors (`proc_pidinfo(PROC_PIDLISTFDS)`), and matches the
4-tuple with `proc_pidfdinfo(…, PROC_PIDFDSOCKETINFO, …)`. This is what `lsof -i` does. Run
unprivileged, as uid 501, against three real clients:

```
accept #0 peer_port=63884 -> pid=74408 (curl)    scan=0.2ms
accept #1 peer_port=63885 -> pid=74410 (Python)  scan=0.1ms
accept #2 peer_port=65113 -> pid=33382 (curl)    scan=0.2ms
```

It works, it needs no root for same-uid peers, and it is fast: sub-millisecond, because
`proc_listpids` returns newest-first and a just-connected client is near the front. `lsof` confirms
the same visibility at the shell:
`Port42 22638 gordon 124u IPv4 … TCP 127.0.0.1:62562->127.0.0.1:4242 (ESTABLISHED)`.

So this is more viable than "theoretical". It is still the wrong mechanism:

- **`libproc.h` is undocumented API.** It ships in the SDK; Apple documents none of it.
- **It is a TOCTOU race by construction.** The 4-tuple is read after the connection exists and
  resolved against a pid table that can change. A pid can exit and its number be reused between
  accept and resolve. Audit tokens exist precisely because a pid is not an identity; this technique
  produces a pid.
- **It cannot see other users' or sandboxed processes' descriptor tables** without privilege, so it
  answers only for the same-uid case, which is exactly the case where it buys least (§6).
- **It resolves to the process holding the socket**, which for every documented Port42 caller is
  `curl`.

### 2.5 Verdict table

| | TCP loopback (what Port42 uses) | `AF_UNIX` | XPC |
|---|---|---|---|
| Peer uid | **No.** `LOCAL_PEERCRED` returns success with `uid = 0` (measured) | Yes, `LOCAL_PEERCRED` (measured, `uid=501`) | Yes |
| Peer pid | No supported API. `libproc` FD scan works, undocumented, racy (measured) | Yes, `LOCAL_PEERPID` / `LOCAL_PEEREPID` (measured) | Yes, `xpc_connection_get_pid`, public |
| Peer audit token | No | Yes, `LOCAL_PEERTOKEN`, 32 bytes (measured); public header, undocumented | Private (`xpc_connection_get_audit_token`), but not needed |
| Peer code signature / Team ID | No supported path | Indirect: token or pid → `SecCodeCopyGuestWithAttributes` → `SecCodeCopySigningInformation` (measured working) | **Yes, and Apple-engineered**: `SecCodeCreateWithXPCMessage`, `xpc_connection_set_peer_code_signing_requirement` |

Also ruled out for TCP loopback, from the API research:

- **Endpoint Security**: requires `com.apple.developer.endpoint-security.client`, granted by Apple on
  request to approved developers. No event found that maps an established socket 4-tuple to a
  process. Unresolved rather than proven absent.
- **`NEFilterFlow.sourceAppAuditToken`**: exists since macOS 10.15 and is entitlement-gated (content
  filter, System Extension, Apple approval), but
  [loopback traffic does not reach `NEFilterDataProvider`](https://developer.apple.com/forums/thread/668813)
  without an explicit `NENetworkRule` for 127.0.0.1, and `sourceAppAuditToken` is
  [reported empty for some senders](https://developer.apple.com/forums/thread/738848). Not a path.
- **Shelling out to `lsof`/`netstat`**: the same `libproc` mechanism, plus fork cost and parsing.

---

## 3. What breaks

An unsigned process running `curl` is a first-class caller today, by design:
`ClientRegistry.swift:42-44` names the `manual` kind as existing "for the user's own scripts and for
any caller with no human present (cron, a background job)". Under a signature the question is not
whether that caller is inconvenienced. It is what it would be *identified as*.

### 3.1 The caller population, measured on this machine

| Caller | `codesign -dv` result |
|---|---|
| `/usr/bin/curl`, what Port42's own docs teach | `com.apple.curl`, Apple `Software Signing`, `TeamIdentifier=not set`, `flags=0x0` |
| `/bin/zsh` | `com.apple.zsh`, Apple, no Team ID |
| `/usr/bin/python3` | `com.apple.dt.xcode_select.tool-shim`, Apple, no Team ID |
| Claude Code 2.1.283 | `com.anthropic.claude-code`, Team `Q6L2SF6YDW`, Developer ID, hardened runtime |
| Codex (`~/.nvm/.../bin/codex`) | **"code object is not signed at all"** |
| `port42` CLI, notarized `dist/Port42.app` | `Identifier=a.out`, `adhoc,linker-signed`, no Team ID |
| `scripts/scenarios/p42.py`, the committed scenario harness | a Python script; the signed thing is `python3`, i.e. Apple |
| A browser guest (`gateway/guestpage.go`) | no program at all on this machine |

Five consequences:

1. **Claude Code's real signature is unreachable anyway.** The documented call is a `curl` from a
   Bash tool invocation, so the process on the socket is `curl`, whose parent is a shell, whose parent
   is `claude`. A signature check sees `com.apple.curl`. Walking the parent chain to find `claude` is
   not authentication: a parent pid is not a credential, `ppid` is reassigned on exit, and the child
   can be reparented. A check that admits `com.apple.curl` admits every `curl` on the machine,
   invoked by anyone, for anything.
2. **`anchor apple` admits the world.** Measured in §2.2: `/bin/zsh` passes both `anchor apple` and
   `anchor apple generic`. Any allow-list broad enough to include the interpreters Port42's callers
   actually are includes every Apple binary on the machine. This is
   [T1218 System Binary Proxy Execution](https://attack.mitre.org/techniques/T1218/): a signature
   check that validates the binary and not what it was told to execute is a confused deputy.
3. **Codex is unsigned, and the plan makes it an equal first-run path.** `plan-shell-only.md` Phase 1:
   "Claude Code and Codex are equal first-run paths (GM, 2026-09-24)." One of the two products the
   first run is built around has no signing identity at all. Any signature scheme has to special-case
   it on day one, which is the whole scheme's exception.
4. **Port42's own CLI has no identity to key on.** See the verdict; `build.sh:383` signs a path that
   `build.sh:326` renamed. The `installed` client kind exists specifically for this binary, and it is
   `a.out`, ad-hoc. Fix the build regardless.
5. **The browser guest has no program.** Scenario 4's guest lane is a web page. There is nothing to
   sign, so the guest lane is credential-based whatever happens locally.

### 3.2 Is a hybrid coherent?

A hybrid is coherent as a **strengthening qualifier on a token**, and not as an alternative to one.

Coherent shape: the credential stays the thing that names the caller; a signature, where one exists,
is recorded at enrolment and re-checked at use, so a token minted for `com.anthropic.claude-code`
is refused when presented by something else. That is **binding a credential to a program**, and it is
the only version that adds anything. It needs a transport that can see the peer, which loopback TCP
cannot, so it needs the unix socket first.

Incoherent shapes, named so they are not reached for:

- **Signature instead of token.** Fails on identity resolution (§3.1.1): `curl` is not a caller.
- **Signature as a bypass.** "A Developer-ID-signed program needs no token" turns every signed binary
  on the machine into an authorized caller, and hands the strongest authority to the population
  least under Port42's control.
- **Tiering grants by signature.** "Signed callers may use the terminal, unsigned may not" ranks
  Apple's `curl` above Port42's own CLI (measured) and above Codex, which is backwards.

Under a hybrid, the `paired`/`manual`/`installed`/`child` kinds do not change: each still enrols by a
named act, and the signature is a second field on the row that may be null. The population that
would carry a real one, measured above, is one program out of eight.

---

## 4. Does it apply remotely

**No. It is local-only, and stops being meaningful the moment the caller is not on this machine.**

Phase 4 (`plan-shell-only.md`) authenticates a remote caller through libp2p's Noise handshake, which
proves possession of a private key and yields a **peer id**. That is an identity for a *host or a
key*, not for a program. `PortObject.swift:41` already carries `peerID` for this reason, and
`invite-over-libp2p.md` makes the point directly: the invite "stops being a credential and becomes an
enrolment coupon that binds a peer id."

Three reasons a remote signature is not available even in principle:

1. **The program runs on the other machine**, where this machine's kernel can tell you nothing about
   it. Every macOS mechanism in §2 reads local kernel state.
2. **A remote claim about one's own signature is unverifiable**, being exactly the self-asserted
   `sender_id` the tree already deleted as an identity (`Principal.swift:104-116`,
   `gateway.go:361-376`).
3. **Remote attestation is a different, much larger primitive** (a hardware root of trust and an
   attestation service). Nothing in the roadmap reaches for it, and it would not be a code signature.

So a signature scheme would apply to the local door and not to the remote one, giving Port42 **two
authentication models** in a system whose whole design direction is one. `host-mesh.md` warns about
exactly this shape: "a membership model retrofitted onto per-port grants is the kind of thing that
ends up as a special case in every authorization path." The same applies to a program-shaped identity
retrofitted beside a peer-shaped one.

The Phase 4 sequencing point from `README.md` is therefore answered: **Phase 4's peer id does not
conflict with this item, because this item cannot reach Phase 4's traffic.** Keying grants on a peer
id can proceed without waiting for a decision here.

---

## 5. Against the threat model

The tree already states the threat model and the limit, in two places:

> This does not defeat a process running as the user, and no local-socket design will. A token file is
> readable by anything with the user's uid. What P1 buys is that every caller is named, enrolled by a
> deliberate act, and individually revocable.
> Source: `membrane/slice-02-cross-instance.md:824-826`

> A unix socket with kernel peer credentials, the only real fix for same-uid impersonation. Any
> process running as the user can read any token file, which §9 already concedes.
> Source: `plan-caller-identity-fixes.md:79-80`

The attacker is a process running as the user. It can read `~/.port42/<instance>/tokens/*` (mode 0600,
uid 501, which it is) and present any of them. Against that attacker, what does a signature buy?

| Attack | Signature helps? | Why |
|---|---|---|
| Read another tool's token file and present it | **No.** The stolen token names a client; the thief presents it over `curl`, which is `com.apple.curl`, which is what the honest caller also is. Indistinguishable. | §3.1.1 |
| Impersonate a specific enrolled client | **No**, same reason. | §3.1.1 |
| Enrol itself and accumulate grants | **No.** Enrolment is gated by a human act (`ClientRegistry.swift:14-18`), not by a signature. | |
| A malicious *port*'s JS escaping to machine capabilities | **No.** A port's JS is not a process; its Principal comes from `Principal.forPortBridge` (`Principal.swift:136-151`), which never touches the gateway. | |
| A drive-by page on the internet calling `/call` | **No**, and already handled: no CORS headers on `/call` (`gateway/main.go:50-52`), and the guest page is served same-origin for that reason. | |
| A *different* program presenting a token minted for this one | **Yes, this is the one.** And it needs a unix socket, and it is not "the signature is the credential", it is "the credential is bound to the program". | §3.2 |

So against the stated threat model the answer is **little**, and the one case it does cover is
covered better by a different framing.

### What the item was actually reaching for

Read as a wish rather than a mechanism, "the program as the credential" is three wishes, and two are
reachable without any signature:

1. **"A token file lying on disk is not an identity."** The reachable version is a
   **non-transferable credential**: bind the secret to something the thief does not get by reading a
   file. A per-connection challenge-response over a unix socket with `LOCAL_PEERPID` (measured
   working) means the token alone is not sufficient, and the pid is checked against the enrolled
   client's live process. This is the `plan-caller-identity-fixes.md:79` item, and it is about the
   transport, not the signature.
2. **"I should not have to configure a token for a program I installed."** This is an *enrolment
   ergonomics* wish, and it is already solved for the cases Port42 controls: `child` clients enrol at
   spawn and `installed` at install, both without a prompt
   (`ClientRegistry.swift:39-53`). The friction that remains is for callers Port42 did not install,
   which a signature would not reduce, because a stranger's signature means nothing until a human
   vouches for it. That is the pairing verb dropped at D5, not a signature.
3. **"The permission card should say which program is asking."** This is real and is a *display*
   problem, not an authentication one. `Principal.displayName` is fixed at mint time
   (`Port42Client.name`, `ClientRegistry.swift:29-30`), so a card says the name the user or Port42
   gave, and never what is actually running. A signature could enrich that label. So could recording
   the enrolling program's path at mint time, with no new mechanism and no new trust claim, as long
   as the card does not present it as verified. Overlaps roadmap item 3, "one guided permission flow".

---

## 6. Recommendation

**Drop "the program as the credential" from the roadmap as written. Replace it with two smaller items
that are reachable and that carry what it was reaching for.**

- **Move the local door to a unix socket**, keeping the TCP listener for the browser guest lane only.
  Measured: over `AF_UNIX`, uid, pid and a 32-byte audit token are all available with public
  `getsockopt` options. This is the prerequisite for anything peer-aware and is worth doing on its own
  for the uid check alone. It requires the gateway to be the thing that checks, and the peer fact to
  be forwarded to the app as a gateway assertion, which is sound because the gateway's host
  credential is already unforgeable-by-anything-on-disk (`gateway/credentials.go:37-45`).
- **Then, optionally, bind a credential to its program**: record a signing identity at enrolment
  where one exists, re-check it on use, refuse a mismatch. Null for unsigned callers, which stay
  first-class. This is a hardening of the credential, not a replacement for it.

**Two defects to fix now, independent of any of the above:**

- `build.sh:383` signs `$MACOS/port42`; the bundled name is `port42-cli` (`build.sh:326`). The shipped
  CLI is ad-hoc signed inside a notarized bundle.
- Anything that later reads kernel peer credentials must assert the socket family and the returned
  length. `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` on a TCP socket returns success with `uid = 0`.

**Not blocking Phase 4.** The research order flagged this item first because "Phase 4 is about to key
grants on a peer id. If identity changes afterwards, authorization is redone." That concern does not
apply: a code signature cannot reach a remote caller at all (§4), so a peer-id-keyed grant is not
something this item would later contradict. Phase 4 can proceed.

---

## 7. What could not be determined

- **Whether Apple sanctions `LOCAL_PEERTOKEN`.** It is in the public SDK (`sys/un.h:93`) and it works
  (measured), but no Apple documentation page, sample or forum guidance was found endorsing it.
  Settled by a DTS query or a Feedback response.
- **Availability versions** for `kSecGuestAttributeAudit` and `kSecGuestAttributePid`. The developer
  documentation pages returned titles without bodies. Settled by reading the availability annotations
  in the SDK header directly on the target deployment SDK.
- **Whether `SecCodeCreateWithPID` carries a compiler `API_DEPRECATED` annotation** or is
  guidance-deprecated only. The race is well documented
  ([audit tokens explained](https://knight.sc/reverse%20engineering/2020/03/20/audit-tokens-explained.html));
  the annotation was not verified.
- **Whether Endpoint Security has any event that maps a live socket 4-tuple to a process.** Not
  proven absent, only not found. Settled by reading `EndpointSecurity/ESTypes.h` in the SDK. Moot
  unless the entitlement is obtainable, which it is not for a non-security-vendor developer.
- **Sequoia-era permission requirements for `libproc` FD inspection of other users' or sandboxed
  processes.** Measured working for same-uid, unprivileged. Not measured cross-uid.
- **Whether `proc_listpids` newest-first ordering is guaranteed or incidental.** The 0.1-0.2ms scan
  times measured depend on it. A guaranteed-worst-case scan would be a full sweep of every pid.
- **1Password's browser-signature mechanism**, the closest shipping analogue. Their published
  material states the browser's code signature is verified but
  [deliberately does not disclose how](https://support.1password.com/1password-browser-connection-security/);
  their CLI-to-app path over a unix socket is documented as GID-based plus an
  installed-by-root parent check, not signature-based.
- **Docker Desktop's and `securityd`'s peer authentication on their live data-path sockets.** Only the
  privileged-helper signature-matching layer is publicly documented for Docker.

## 8. Probes

Four probes produced the measurements. They live in the session scratchpad and are not committed; each
is short enough to retype from the numbers above, and each is described where its output appears.

| Probe | Question it answers | Section |
|---|---|---|
| `peercred.c` | Which `SOL_LOCAL` options work on `AF_INET` vs `AF_UNIX` | §2.1 |
| `sigfrompid.c` | Does the public pid → `SecCode` → Team ID path work | §2.2 |
| `fdscan.c` | Can a TCP listener resolve its peer's pid unprivileged, and how fast | §2.4 |
| `codesign -dv` sweep | What the real caller population is signed as | §3.1 |
