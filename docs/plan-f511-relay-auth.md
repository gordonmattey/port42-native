# F-511 Relay Auth: Sign in with Apple

DONE

but doesnt work for Deevloper Id build for some reason.



## Problem

The gateway trusts whatever `sender_id` a client sends in the `identify` message. Anyone who knows or guesses a user's UUID can impersonate them. There is no cryptographic proof of identity.

## Solution

Use Sign in with Apple as the identity layer. Apple provides an opaque, stable user ID tied to the person's Apple account. The gateway verifies Apple-signed JWTs to prove identity. No Apple details (email, real name) are shared.

**Architecture decision: gateway verifies, app stores.** The gateway verifies Apple JWTs and maps Apple user IDs to peers. The app stores the Apple user ID on AppUser so it can provide it across sessions. The Apple sign-in happens once during setup, right after the user enters their name.

## Design Principles

- **Gateway verifies identity.** The gateway checks Apple JWTs and maps Apple user IDs to peers.
- **App stores Apple user ID.** The `appleUserID` field on AppUser persists the opaque Apple ID across sessions.
- **User signs in once during setup.** The Apple sign-in sheet appears right after entering their name. All subsequent gateway connects use silent re-auth.
- **Display names are user-chosen**, not from Apple. Apple ID is invisible to everyone.
- **Two auth paths**: humans use Apple ID, agents use channel join tokens (F-514).
- **Localhost is trusted.** Local gateway connections skip auth (no Apple sign-in popup during local dev).
- **Identity is portable.** Same Apple ID on Mac and future iOS app gives same gateway identity.

## Protocol

### Current (insecure)

```
Client                          Gateway
  |--- identify {sender_id} ---->|   gateway trusts blindly
  |<--- welcome -----------------|
```

### New (remote gateway)

```
Client                          Gateway
  |--- WebSocket connect ------->|
  |<-- challenge {nonce} --------|   32-byte random hex
  |                               |
  |   [client: SHA256(nonce),     |
  |    pass hash to Apple,        |
  |    Apple signs JWT with it]   |
  |                               |
  |-- identify {                  |
  |     sender_id,                |
  |     sender_name,              |
  |     identity_token (JWT),     |
  |     auth_type: "apple"        |
  |   } ----------------------->|
  |                               |
  |   [gateway verifies:]         |
  |   1. JWT sig vs Apple JWKS    |
  |   2. SHA256(nonce) == JWT nonce|
  |   3. aud == com.port42.app    |
  |   4. iss == appleid.apple.com |
  |   5. not expired              |
  |   6. extract sub (Apple ID)   |
  |                               |
  |<-- welcome {sender_id} ------|
  |                               |   gateway maps Apple ID -> peer
  |-- join {channel_id} -------->|
```

### Localhost (unchanged)

```
Client                          Gateway (localhost)
  |--- identify {sender_id} ---->|   no challenge, no JWT
  |<--- welcome -----------------|   trusted (same machine)
```

The client decides which path based on the gateway URL. If it contains "localhost" or "127.0.0.1", it sends identify immediately (as today). Otherwise it waits for the challenge.

### Auth paths

| Peer type | Auth method | When |
|-----------|-------------|------|
| Human (remote gateway) | Sign in with Apple JWT | Every WebSocket connect (silent after first) |
| Human (local gateway) | None (localhost trusted) | Identify as today |
| Local companion | Rides on owner's connection | No separate auth |
| External agent (future) | F-514 channel join token | On channel join |

## What changes where

### App side

1. **AppUser model** gains `appleUserID: String?` field (DB migration)
2. **AppleAuthService** (new file) calls `ASAuthorizationAppleIDProvider` to get a JWT
3. **SetupView** triggers Apple sign-in after name entry, stores Apple user ID
4. **SyncService** handles `challenge` message and sends JWT in `identify`
5. **Entitlements** add `com.apple.developer.applesignin`

### Gateway side (most of the work)

The gateway is entirely in-memory (no database). It gains:

1. **Challenge/response** in the WebSocket handshake
2. **Apple JWT verification** (new file, fetches Apple's JWKS)
3. **Identity mapping** in memory (Apple user ID -> peer, survives reconnects within gateway session, lost on gateway restart)

### Nothing changes

- Channel model, Message model
- DatabaseService schema (except the AppUser migration)
- Local functionality (swims, local channels, companions)

## Nonce Flow Detail

1. Gateway generates 32 random bytes, hex-encodes them (64-char string)
2. Sends `{"type": "challenge", "nonce": "a1b2c3..."}`
3. Client receives nonce, computes `SHA256(nonce)` as hex string
4. Client passes the HASH (not raw nonce) to `ASAuthorizationAppleIDRequest.nonce`
5. Apple bakes the hash into the identity token JWT's `nonce` claim
6. Client sends the JWT back in the identify message
7. Gateway computes `SHA256(original_nonce)`, compares with JWT's `nonce` claim
8. Match confirms the token was freshly issued for this connection

## Envelope Changes

New optional fields on Envelope (Go) and SyncEnvelope (Swift):

```
nonce           string   // gateway -> client (challenge)
identity_token  string   // client -> gateway (Apple JWT)
auth_type       string   // "apple" (future: "token", etc.)
```

All backward compatible (omitempty/optional).

## Implementation Steps

### Step 1: Apple Developer portal setup

Enable "Sign in with Apple" capability for bundle ID `com.port42.app` in the Apple Developer portal. This is a prerequisite before any code works.

### Step 2: Entitlements

Add to both `Port42.entitlements` and `Port42.release.entitlements`:

```xml
<key>com.apple.developer.applesignin</key>
<array>
    <string>Default</string>
</array>
```

### Step 3: AppUser migration (`DatabaseService.swift`)

Add migration to append `appleUserID` column:

```swift
migrator.registerMigration("addAppleUserID") { db in
    try db.alter(table: "users") { t in
        t.add(column: "appleUserID", .text)
    }
}
```

Add `appleUserID: String?` to `AppUser` struct.

### Step 4: AppleAuthService (`Sources/Port42Lib/Services/AppleAuthService.swift`, new file)

```swift
import AuthenticationServices
import CryptoKit

@MainActor
final class AppleAuthService: NSObject, ObservableObject {

    /// Get an identity token from Apple with the given nonce.
    /// First call shows Apple sign-in sheet. Subsequent calls are silent.
    func authenticate(nonce: String) async throws -> (identityToken: String, appleUserID: String) {
        let hashedNonce = SHA256
            .hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = []  // no email, no name
        request.nonce = hashedNonce

        let controller = ASAuthorizationController(authorizationRequests: [request])
        // ... delegate setup, present, await result
        // Return the identityToken as a UTF-8 string and the Apple user ID
    }

    /// Silent re-auth for subsequent gateway connects.
    /// Uses the stored appleUserID to get a fresh token without UI.
    func silentAuth(nonce: String) async throws -> String {
        // Same as authenticate but uses existing credential
        // ASAuthorizationAppleIDProvider.getCredentialState first
        // If authorized, request with nonce returns token silently
    }
}
```

- No Keychain storage needed for the token itself
- Apple user ID stored on AppUser in the DB
- Conforms to `ASAuthorizationControllerPresentationContextProviding` for the window anchor

### Step 5: SetupView changes (`SetupView.swift`)

After the user submits their name and the AppUser is created, trigger Apple sign-in:

```swift
private func submitName() {
    // ... existing name validation and AppUser creation ...

    // Trigger Apple sign-in
    Task {
        do {
            let result = try await appleAuth.authenticate(nonce: UUID().uuidString)
            // Store Apple user ID on AppUser
            var user = appState.currentUser!
            user.appleUserID = result.appleUserID
            try appState.db.saveUser(user)
            appState.currentUser = user
        } catch {
            // Apple sign-in failed or cancelled, continue without it
            // User can still use local features, just won't auth to remote gateway
            NSLog("[Port42] Apple sign-in skipped: \(error)")
        }
    }

    // Continue with analytics consent...
}
```

The setup boot sequence would show a line like:
```
Linking Apple identity... OK
```

### Step 6: Gateway challenge/response (`gateway.go`)

- Add `Nonce`, `IdentityToken`, `AuthType` fields to `Envelope`
- After WebSocket accept, generate nonce, send `challenge` message
- Store pending nonce keyed by connection (map[*websocket.Conn]string)
- Wait for `identify` as before
- If `identity_token` present, verify it (step 7)
- If no `identity_token`, allow as unauthenticated (log warning, backward compat)
- Clean up nonce after use

### Step 7: Apple JWT verification (`gateway/apple_auth.go`, new file)

```go
type AppleAuthVerifier struct {
    bundleID string
    keys     jose.JSONWebKeySet  // cached
    fetched  time.Time
}

func NewAppleAuthVerifier(bundleID string) *AppleAuthVerifier
func (v *AppleAuthVerifier) Verify(identityToken string, expectedNonce string) (appleUserID string, err error)
```

- Fetch Apple's JWKS from `https://appleid.apple.com/auth/keys`
- Cache keys in memory, refresh when older than 24h
- Parse JWT, verify signature against Apple's public keys
- Check `iss == "https://appleid.apple.com"`
- Check `aud == bundleID` (configurable, default `com.port42.app`)
- Check `exp` not passed
- Compute `SHA256(expectedNonce)`, compare with JWT `nonce` claim
- Return the `sub` claim (opaque Apple user ID)
- New dependency: `github.com/golang-jwt/jwt/v5`

### Step 8: Gateway identity mapping (`gateway.go`)

In-memory only (the gateway has no database, everything is in-memory):

- `Gateway` struct gets: `appleIDs map[string]string` (apple_user_id -> peer_id)
- On successful Apple auth, store the mapping
- On peer disconnect, keep the mapping (for reconnect recognition)
- Mapping is lost on gateway restart (acceptable for now, persistence is future work)

### Step 9: SyncService changes (`SyncService.swift`)

Add fields to `SyncEnvelope`:
```swift
var nonce: String?
var identityToken: String?
var authType: String?

// CodingKeys:
case nonce
case identityToken = "identity_token"
case authType = "auth_type"
```

New property:
```swift
private var appleAuth: AppleAuthService?
```

Update `configure()` to accept `appleAuth` parameter.

Change connect flow:
- Currently: connect -> immediately send identify -> start receive loop
- New: connect -> start receive loop -> on receiving `challenge`, do Apple auth -> send identify

```swift
case "challenge":
    guard let nonce = envelope.nonce else { break }
    Task {
        do {
            let token = try await appleAuth?.silentAuth(nonce: nonce)
            send(SyncEnvelope(
                type: "identify",
                senderId: userId,
                senderName: userName,
                identityToken: token,
                authType: "apple"
            ))
        } catch {
            print("[sync] Apple auth failed: \(error), connecting without auth")
            send(SyncEnvelope(type: "identify", senderId: userId, senderName: userName))
        }
    }
```

Localhost detection (skip waiting for challenge):
```swift
public func connect() {
    // ... existing setup ...

    let isLocal = gatewayURL?.contains("localhost") == true
                || gatewayURL?.contains("127.0.0.1") == true

    if isLocal {
        // Send identify immediately (no challenge expected)
        send(SyncEnvelope(type: "identify", senderId: userId, senderName: userName))
    }
    // else: wait for challenge message in receiveLoop

    receiveLoop()
}
```

### Step 10: AppState wiring (`AppState.swift`)

- Create `AppleAuthService()` instance
- Pass to `sync.configure(... appleAuth: appleAuth)`
- No other changes

## Setup Flow (Updated)

| Step | What happens |
|------|-------------|
| 1. Boot sequence | Terminal POST lines animate |
| 2. Name prompt | User types their display name |
| 3. AppUser created | P256 keys generated, stored in Keychain |
| 4. Apple sign-in | Apple sign-in sheet appears, user authenticates |
| 5. Apple ID stored | `appleUserID` saved on AppUser in DB |
| 6. Analytics consent | User opts in or out |
| 7. Auth setup | Claude Code auto-detect or API key entry |
| 8. Swim session | First swim begins |

If Apple sign-in is cancelled or fails, setup continues normally. The user just won't have Apple auth for remote gateways.

## When does the user see Apple sign-in?

| Scenario | What happens |
|----------|-------------|
| First launch | Apple sign-in sheet appears once during setup (after name entry) |
| Every subsequent launch with remote gateway | Silent Apple auth. No UI. |
| Local development with `--peer` | Localhost, no challenge, no Apple sign-in |
| Joining someone else's channel | Gateway connect triggers challenge. Silent auth (Apple ID already linked). |

## Test Plan

### Unit tests (Go)

| Test | Verifies |
|------|----------|
| Challenge sends unique nonces | Two connections get different nonces |
| Nonce consumed after use | Same nonce can't verify twice |
| Valid JWT passes | Correct sig, aud, nonce, exp accepted |
| Wrong nonce rejects | JWT with different nonce is rejected |
| Wrong audience rejects | JWT for different app is rejected |
| Expired JWT rejects | Old token is rejected |
| JWKS caching | Keys fetched once, not re-fetched within cache window |
| Backward compat | Identify without token accepted (unauthenticated, warning logged) |

### Unit tests (Swift)

| Test | Verifies |
|------|----------|
| SyncEnvelope new fields | nonce, identityToken, authType encode/decode correctly |
| Nonce SHA256 hashing | Known input produces expected hex hash |
| Localhost detection | "localhost" and "127.0.0.1" URLs skip challenge |
| AppUser appleUserID | Migration adds column, field persists across save/load |

### Manual tests

| # | Test | Steps | Expected |
|---|------|-------|----------|
| 1 | Setup includes Apple sign-in | Fresh install, run through setup | Apple sign-in sheet appears after name entry |
| 2 | Local dev unchanged | `./build.sh --run` | App connects to local gateway, no challenge |
| 3 | Peer testing unchanged | `./build.sh --run --peer` | Both instances work, no Apple sign-in |
| 4 | First remote connect | Set up ngrok, connect to remote gateway | Silent auth (Apple ID already linked during setup) |
| 5 | Impersonation blocked | Use wscat to send fake identify to remote gateway (no JWT) | Gateway accepts as unauthenticated (warning logged). With `--require-auth` flag, rejects. |
| 6 | Replay blocked | Capture valid JWT, disconnect, reconnect, send old JWT with new nonce | Gateway rejects (nonce mismatch) |
| 7 | Peer joins via invite | Copy invitation, paste in peer's Cmd+K | Peer authenticates with Apple, joins channel |
| 8 | Offline works | Disconnect network | Local channels, swims, companions all work |

## Security Properties

| Property | How |
|----------|-----|
| No impersonation (remote) | Apple signs the JWT, gateway verifies against Apple's JWKS |
| No replay | Fresh nonce per connection, baked into JWT |
| Portable identity | Apple user ID is account-based, works on any device |
| No secrets on gateway | Gateway fetches Apple's public keys, stores nothing secret |
| Privacy | Apple user ID is opaque, no email/name requested, display name is user-chosen |
| Localhost trusted | Local connections skip auth (same machine, no network exposure) |
| Agent security | Agents ride on owner's authenticated connection or use join tokens |

## What this does NOT do (future work)

- **Persistent identity store on gateway**: gateway forgets Apple ID mappings on restart (everything in the gateway is in-memory). Add file-backed persistence later for cross-restart channel membership.
- **Auto-rejoin channels**: app still sends join messages on connect. Later, gateway can auto-rejoin based on persisted Apple ID -> channel mappings.
- **iOS app support**: the architecture supports it (iOS app connects to remote gateway, authenticates with Apple ID, same Apple user ID gives same identity) but no iOS code yet.
- **Require auth**: gateway accepts unauthenticated connections for backward compat. Add `--require-auth` flag later to enforce Apple auth.
- **Token revocation/expiry**: F-514 join tokens are reusable, no expiry. Add revocation later.
- **Certificate pinning**: relies on TLS for transport security.

## Dependencies

### Go
- `github.com/golang-jwt/jwt/v5` for JWT parsing and verification

### Swift
- `AuthenticationServices` framework (built into macOS/iOS, no package dependency)
- `CryptoKit` (built into macOS/iOS, already used for ChannelCrypto)

### Apple Developer Portal
- "Sign in with Apple" capability enabled for `com.port42.app`
