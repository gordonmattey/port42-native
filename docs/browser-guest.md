# A guest in a browser: no install, and what it changes

**Opened 2026-07-31** (GM: *"I mean a web app as another host"*). Checked against current libp2p
sources rather than recalled; links at the bottom.

## The finding

**A web app can be a real peer.** js-libp2p and go-libp2p both implement browser-to-server
transports, so a browser can dial the Go gateway directly:

| transport | state | catch |
|---|---|---|
| **WebTransport** | fully implemented and a default transport in go-libp2p; works browser to server today | **Chromium only** |
| **WebRTC Direct** | implemented in both stacks, documented | the server must publish its TLS certificate fingerprint in its multiaddr |

**On iPhone this means WebRTC.** Every iOS browser is WebKit underneath, so WebTransport is not
available there whatever the browser says on the tin. Worth knowing before building toward the wrong
one.

## Why this is bigger than a convenience

**It fits the model rather than bending it.** We already established that a guest does not receive
pixels: they get `getHtml` then `patch` / `push` deltas and render them in their own webview, so the
port's JavaScript runs on the guest's machine. **A browser is exactly that renderer.** A shared port
is HTML and JS; a browser runs HTML and JS.

So a browser guest is not a degraded client. It is the same guest with a different shell around it:

- it is a peer with its own identity
- its bridge calls travel to the host like any other guest's
- the compound actor `<peerBrowser>/<portX>` is unchanged, and the spike already showed grants key on
  that pair without pooling

**And it removes the install from the invite flow.** An hour ago accepting an invite meant
downloading Port42 first. "Click the link, the port opens in your browser" is a different feature.

## What it does NOT do

**It is not a substitute for milestone C's measurement, and conflating them would give a false
green.** A browser traverses NAT with WebRTC's own ICE and STUN. Milestone C's falsifier is
specifically about two go-libp2p nodes hole-punching to each other with DCUtR. A phone browser
connecting successfully tells you WebRTC works, which was never in question.

Two different numbers, two different mechanisms. C still needs two native peers on two networks.

## What it changes in the plan

**The invite.** If a guest may have no Port42 at all, the link cannot assume an app to deep-link
into. The landing page stops being a download prompt and becomes a possible destination, which
reopens what the invite carries: a browser guest still needs an identity and a credential, and it has
nowhere to persist them except the browser.

**Identity for a browser guest is the open problem.** A native peer derives its PeerID from the
P-256 identity in the Keychain. A browser has no Keychain. Options, none decided:

- a key generated in the browser and held in local storage, so the guest is a new peer per browser
  and per device, which is honest but means re-enrolling on every device
- a key derived from the invite itself, which makes the link the credential and therefore makes
  one-time use essential
- no persistence at all: an ephemeral peer for the life of the tab, re-invited each time

**The certificate question.** WebRTC Direct needs the host's TLS certificate fingerprint in its
multiaddr. On a LAN with a self-signed certificate that is manageable, because the fingerprint
travels in the invite rather than needing a CA. Over the internet it is the same story. This is worth
a spike before it is assumed.

## Open

1. Which transport do we target first? WebRTC, if iPhone matters, and iPhone is exactly the case GM
   raised.
2. What does a browser guest persist, if anything?
3. Does a no-install guest get the same capabilities as a native one? It is a peer either way, and
   grants are asked per capability, so the honest answer is probably yes, with the difference being
   that it cannot host anything of its own.
4. Does this change what the iOS app is for? If a browser can render and drive a shared port, the
   native iOS app's job becomes hosting and identity rather than viewing.

## Sources

- [WebRTC with js-libp2p](https://libp2p.io/docs/webrtc-browser-connectivity/)
- [WebTransport in libp2p](https://libp2p.io/docs/webtransport/)
- [WebRTC browser-to-server](https://blog.libp2p.io/libp2p-webrtc-browser-to-server/)
- [WebRTC transport concepts](https://docs.libp2p.io/concepts/transports/webrtc/)
