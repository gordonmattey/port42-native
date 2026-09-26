# Phase 4 transport: gotchas in WebRTC, Nostr introductions and port mapping

Research for `plan-nautilus-phase4.md`, 2026-09-26. The design under test: WebRTC data channels (pion
in the Go gateway, the browser's own `RTCPeerConnection`), introductions over public Nostr relays,
public STUN, router port mapping when available, and no server run by Port42. Four parallel desk
reviews of specs, source and published reports. Nothing here is measured by us; each claim carries its
label: **D** documented (spec, source, official docs, published study), **R** reported (vendor claim,
blog, issue), **I** inference.

## Conclusion

**The no-server design works for most connections and fails for a predictable minority, and its
introductions depend on relays that are turning this traffic away.**

- **Estimated direct-connection rate with STUN only: 75 to 88% (I).** With a working port mapping on
  the host and IPv6 where both sides have it: 85 to 93% (I). The residue is guests on networks that
  block UDP (offices, some guest Wi-Fi), which only a relay over TCP/TLS on port 443 reaches, and
  cellular guests on IPv4 to a host whose ISP puts it behind carrier NAT. Published figures are old
  for browsers (22 to 30% of WebRTC sessions needed TURN, 2015 to 2017, R) or include techniques a
  browser cannot use (Tailscale "well north of 90%", Iroh about 90%, Holepunch about 95%, all R; the
  libp2p DCUtR study measured 70% of punches once prerequisites worked, D).
- **Public Nostr relays are locking down exactly this pattern** (anonymous throwaway keys, frequent
  ephemeral events). A game using Trystero had two outages from relay refusals and moved to Firebase
  plus TURN (R). strfry, which runs the largest relays, ships a plugin whose stated purpose is
  rejecting "ephemeral floods (e.g. relayed WebRTC signaling)" (D). Relays also churn: Trystero
  pruned about 60 from its default list in six months (D, git history), and a study found about 20%
  of relays down more than 40% of the time (D).
- **No browser P2P product was found that runs without its own relay and publishes success rates.**
  PairDrop's docs say cross-network transfers need your own TURN server (D).

So "no server of ours" is achievable as a mode and not as the only path. See the options in the plan's
decision 3.

## Gotchas that change the design

### The invite

1. **Preview bots and mail scanners can redeem a one-time link** (blocker if the page connects on
   load). Instagram and LinkedIn preview servers ran page JavaScript for 20 seconds or more (R);
   iMessage builds previews on the sender's device, reportedly in a web view (R), so the host's own
   phone could burn the link; mail gateways (Safe Links, Proofpoint, Mimecast) are widely reported to
   burn one-time links (R). **Change:** the page never redeems on load. Redemption needs a click, and
   the host confirms the guest (a short code shown on both screens, or an approve prompt, as VS Code
   Live Share does for anonymous guests, D).
2. **Whoever serves the page can read the coupon** (serious). The fragment never reaches a server,
   but the page's own scripts see it (I). **Today's `invite.html` loads PostHog**, a third-party
   script. **Change:** the invite page loads no third-party script, sets a strict CSP and
   `Referrer-Policy: no-referrer`, and clears the fragment with `history.replaceState` once read (D).
3. **Safari deletes a guest's stored key after 7 days without a visit** (serious). ITP clears
   IndexedDB; home-screen web apps are exempt (D). "Same guest after a refresh" holds; "same guest next
   week" does not on Safari or in private windows. **Change:** the plan says so, and a lapsed guest
   needs a new invite.

### Nostr introductions

4. **Relays refuse, rate-limit, or require payment, auth or proof of work** (blocker without a
   fallback). Per-IP limits as low as 8 events a minute (D, noteguard example config); several popular
   relays are paid (D, NIP-11). **Change:** a fallback relay the invite always lists (options in the
   plan), one bundled offer and one bundled answer instead of trickled candidates.
5. **Delivery is fire-and-forget** (serious). Ephemeral events are not stored (D); an offer sent while
   the host's socket is reconnecting is lost (I). **Change:** the guest resends until answered; the
   host subscribes from 60 seconds back and dedupes by session id; a fresh peer connection per attempt.
6. **Timestamps must be real** (serious). strfry drops ephemeral events older than 60 seconds (D).
   **Change:** never backdate (NIP-59 gift wrap's advice to tweak timestamps conflicts, D); the guest
   page detects a skewed clock and says so.
7. **Anyone can flood the host with offers** (serious). Each costs a signature check and a decryption
   (I). **Change:** a Nostr key per invite, a secret inside the ciphertext checked before any peer
   connection is allocated, a cap on pending connections, and revoking an invite drops its filter.
8. **Relays see both parties' IPs, keys and timing** (serious for a long-lived key). NIP-44 hides
   content only, with no forward secrecy (D). **Change:** per-invite and per-guest keys, never the
   instance's main key on Nostr; the offer and answer are also signed inside the ciphertext with the
   Port42 Ed25519 key.
9. **The Go library is archived** (minor). nbd-wtf/go-nostr was archived 2026-01-24 at v0.52.3; its
   successor has no tagged releases (D). **Change:** pin or vendor. Browser side: a tree-shaken
   nostr-tools (the full bundle is 59 KB gzipped, D).

### WebRTC

10. **Message size** (serious). Chrome and Safari advertise 256 KiB and throw above it (R); pion
    accepts 1 GiB by default, so a guest could make the gateway reassemble a 1 GiB message (D, I).
    **Change:** our own framing in chunks of 16 KiB or less (libp2p's choice "to support all major
    browsers", D), and pion's maximum set to 256 KiB.
11. **Backpressure** (serious). Chrome closes a channel past a 16 MB send buffer (R). **Change:** every
    sender waits on the buffered-amount-low signal; per-session memory caps in the gateway.
12. **iPhone guests stop when the screen locks or Safari goes to the background** (serious). All
    low-level networking stops on suspension (D, Apple DTS). **Change:** sessions resume: reconnect
    on visibility, resubscribe, request ids so a retried call is not applied twice.
13. **The identity binding must be exact** (serious). Signing both fingerprints is sound and matches
    RFC 8827 and libp2p (D). Browsers make ECDSA or RSA certificates, never Ed25519 (R), and a new one
    per connection (I). **Change:** one canonical signed payload (algorithm and value of both
    fingerprints, both keys, nonce, role, session id), verified before the remote description is
    applied, SDP with more than one fingerprint refused. A Noise handshake over the first data channel
    (libp2p's approach) is the stronger alternative.
14. **One fixed UDP port** (serious for port mapping). pion can put every session on one port and
    advertise a mapped address (`SetICEUDPMux`, `SetICEAddressRewriteRules`, D). Without it there is
    no stable port to map.
15. **Pre-authentication crashes** (serious once a port is mapped). pion/stun before v3.1.3 panics on
    one malformed packet, no authentication needed (CVE-2026-54909, D); pion/dtls before v3.1.4 has a
    parser panic (D). A panic in any goroutine kills the whole gateway (I). **Change:** pinned versions
    at or above the fixes, panics recovered at the transport boundary or the transport in its own
    process, and a fuzz test on the open port.
16. **Refresh and disconnect** (minor). pion's defaults: disconnected at 5 s, failed at 25 s (D); a
    refreshed tab leaves a zombie connection until then (I). **Change:** an explicit goodbye on
    `pagehide`, and an application close handshake.

### macOS

17. **Local Network privacy** (serious for first run). LAN candidates, mDNS and SSDP all need the
    permission, and a helper process is attributed to the app that launched it (D, TN3179). Without
    `NSLocalNetworkUsageDescription` sends fail silently; denied, they fail as "host unreachable" (R).
    Go before 1.24 omitted the UUID the permission is keyed on (D); **our gateway builds with Go 1.25
    and has it** (checked with `otool -l` on the Dev2 bundle). **Change:** the Info.plist key, and
    the prompt expected at first share with copy that explains it.

### Port mapping

18. **Often unavailable, and useless behind carrier NAT** (serious). Fixed-wireless and satellite
    homes (about 12.5% of US broadband households by late 2025, R) and several German cable ISPs sit
    behind carrier NAT (R); CISA advises disabling UPnP (D); FRITZ!Box needs a per-device opt-in (R).
    **Change:** optional. A mapped address is used only if it is public and equals the STUN-reflected
    address.
19. **Routers lie** (minor for connectivity). Mappings listed but not forwarding, `0.0.0.0` as the
    external address, permanent-only leases (D, Tailscale's portmapper source). **Change:** never a
    permanent lease; 7200-second leases renewed at half-life; the mapping persisted and deleted at
    next launch; which candidate won each connection logged.
20. **Library** (minor). `tailscale.com/net/portmapper` handles PCP, NAT-PMP and UPnP with the quirks
    above but pulls in the Tailscale module; `jackpal/go-nat-pmp` plus `huin/goupnp` is lighter and
    has no PCP (D). Try PCP and NAT-PMP by unicast first and SSDP multicast last.

### IPv6

21. **Likely a larger lever than port mapping.** Over half of US traffic to Google is IPv6, about 88%
    on T-Mobile US (R). Home routers should filter UDP endpoint-independently, so simultaneous open
    should work (D, RFC 6092; libp2p saw poor IPv6 punching in practice, R). **Change:** gather IPv6
    candidates and list a dual-stack STUN server; measure before building UPnP.

### The shared port itself

22. **Confused deputy** (serious). The host's copy of a shared port keeps its machine grants while a
    guest drives it (I). Live Share shares terminals read-only by default and only the host can start
    one (D). This supports suspending a shared port's machine grants while a guest holds it, over the
    disclosure-only option.
23. **Both sides learn each other's IP** (disclosure). Signal relays calls to hide it (R); a design
    with no relay cannot. **Change:** the invite dialog says so; the host's LAN and VPN interface
    addresses are filtered from its candidates.

## What only measurement settles

For step 4.0, in this order:

1. **The no-server direct rate.** Home Mac host; guests on iPhone Safari over three US carriers (IPv4
   and IPv6), a café, a hotel and an office network; each with the port mapping on and off.
2. **Nostr introductions.** Accept rate, refusal reasons and offer-to-answer time for a fresh key on
   30 relays; the rate at which they start refusing; the share of an invite's relays alive after 1,
   7 and 30 days.
3. **IPv6.** Whether Chrome and Safari offer a reflected IPv6 candidate while hiding host candidates,
   and whether pion pairs with it.
4. **Preview bots.** The live link pasted into iMessage, WhatsApp, Slack, Teams, LinkedIn and Gmail,
   and an Outlook tenant with Safe Links: every page load and redemption attempt logged.
5. **WebRTC limits.** 16, 64, 256 and 257 KiB messages each way against each browser; a 3 MB port over
   16 KiB chunks at 20 and 150 ms round trip; an iPhone locked for 5, 30 and 120 seconds.
6. **macOS.** The prompt on a clean macOS 15 and 26 account, its wording, and behavior when denied.
7. **The gateway's cost.** Binary size, idle CPU and memory with 0, 1 and 10 peers.
8. **Robustness.** Malformed STUN and DTLS at the open port; a flood of 1,000 offers a minute while a
   real guest connects.
