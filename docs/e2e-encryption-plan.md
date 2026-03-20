# E2E Encryption Plan

DONE ✅

## Overview

Per-channel AES-256-GCM symmetric encryption. Messages are encrypted before
leaving the app. The gateway sees only encrypted blobs and routing metadata.
CryptoKit provides all primitives (no external dependencies).

## Architecture

```
Alice's App                        Gateway                      Bob's App
    |                                 |                             |
    | payload = JSON(senderName,      |                             |
    |   senderType, content, replyTo) |                             |
    |                                 |                             |
    | nonce = random 12 bytes         |                             |
    | sealed = AES-GCM.seal(          |                             |
    |   payload, key, nonce)          |                             |
    |                                 |                             |
    | envelope.payload.content =      |                             |
    |   base64(nonce + ciphertext     |                             |
    |          + tag)                  |                             |
    | envelope.payload.senderName =   |                             |
    |   "" (empty, encrypted inside)  |                             |
    | envelope.payload.encrypted =    |                             |
    |   true                          |                             |
    |                                 |                             |
    |-- send envelope --------------->|                             |
    |                                 |-- forward envelope -------->|
    |                                 |                             |
    |                                 |     look up channel key     |
    |                                 |     data = base64decode()   |
    |                                 |     nonce = data[0..<12]    |
    |                                 |     box = SealedBox(nonce,  |
    |                                 |       ciphertext, tag)      |
    |                                 |     payload = AES-GCM.open  |
    |                                 |       (box, key)            |
    |                                 |     -> senderName, content  |
    |                                 |                             |
```

## What gets encrypted

The entire SyncPayload (senderName, senderType, content, replyToId) is
serialized to JSON and encrypted as one blob. This means the gateway cannot
see who sent the message or what it says.

The SyncEnvelope routing fields remain plaintext because the gateway needs
them: type, channelId, senderId (device ID, not display name), messageId,
timestamp.

## Wire format change

Current SyncPayload on the wire:
```json
{
  "senderName": "Gordon",
  "senderType": "human",
  "content": "hello world",
  "replyToId": null
}
```

Encrypted SyncPayload on the wire:
```json
{
  "senderName": "",
  "senderType": "human",
  "content": "BASE64_ENCRYPTED_BLOB",
  "replyToId": null,
  "encrypted": true
}
```

The `encrypted` flag lets receivers know to decrypt. Unencrypted messages
(from older clients or channels without keys) still work as before.

## Key management

- Key generation: `SymmetricKey(size: .bits256)` via CryptoKit
- Storage: base64-encoded string in Channel.encryptionKey column (SQLite)
- Sharing: included in invite link as `key` query parameter
- Channels created before encryption: no key, messages sent unencrypted
- New channels: key auto-generated on creation

## Build sequence

### Step 1: ChannelCrypto service (pure crypto, no dependencies)

New file: `Sources/Port42Lib/Services/ChannelCrypto.swift`

Functions:
- `generateKey() -> String` (base64 encoded)
- `encrypt(payload: SyncPayload, keyBase64: String) -> String` (base64 blob)
- `decrypt(blob: String, keyBase64: String) -> SyncPayload?`

Test cases:
- encrypt then decrypt roundtrip returns identical payload
- decrypt with wrong key returns nil
- decrypt with corrupted data returns nil
- encrypt produces different output each time (random nonce)
- empty content encrypts and decrypts correctly
- unicode content (emoji, CJK) roundtrips correctly
- generated keys are valid 256-bit keys

### Step 2: Channel model + migration

Changes:
- Add `encryptionKey: String?` to Channel model
- Add GRDB migration "v_encryption" adding encryptionKey column
- Channel.create() auto-generates a key

Test cases:
- new channel has non-nil encryptionKey
- existing channels (pre-migration) have nil encryptionKey
- channel with key persists and loads correctly from DB
- channel key is valid base64 and correct length

### Step 3: Encrypt on send

Changes:
- SyncPayload gets `encrypted: Bool?` field
- SyncService.sendMessage looks up channel key, encrypts if present
- SyncService.sendTyping unchanged (typing is metadata, not encrypted)

Test cases:
- message to channel with key produces encrypted payload
- message to channel without key sends plaintext (backward compat)
- encrypted envelope has empty senderName (no metadata leak)
- encrypted envelope has `encrypted: true`

### Step 4: Decrypt on receive

Changes:
- SyncService.handleIncomingMessage checks `encrypted` flag
- If encrypted, decrypts payload using channel key
- If decryption fails (wrong key / no key), logs warning, drops message

Test cases:
- encrypted message from peer decrypts correctly
- message with `encrypted: true` but no local key is dropped
- message with `encrypted: true` but wrong key is dropped
- unencrypted message still works (backward compat)
- full roundtrip: encrypt on send -> decrypt on receive

### Step 5: Invite link key exchange

Changes:
- ChannelInvite.generateLink adds `key` param
- ChannelInvite.parse / ChannelInviteData gets `encryptionKey: String?`
- AppState.joinChannelFromInvite stores the key with the channel

Test cases:
- invite link for channel with key includes `key` param
- invite link for channel without key omits `key` param
- parse extracts key correctly
- joining from invite stores key in channel record
- joining existing channel (already have key) does not overwrite

### Step 6: Integration verification

Manual test:
- Create channel on Device A (key auto-generated)
- Copy invite link (contains key)
- Join on Device B from link (key stored)
- Send message A -> B (encrypted, decrypted correctly)
- Send message B -> A (encrypted, decrypted correctly)
- Verify gateway logs show only encrypted blobs
