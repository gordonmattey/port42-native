# Run your own relay

When you share a port, the other person's Port42 reaches yours through a relay. Port42 uses
`relay1.port42.ai` by default. Anyone can run their own, and invites you create then list it.

The relay stores nothing. It pairs instances by key and forwards their traffic, which is encrypted
end to end (Noise IK) before it arrives, so the relay cannot read it. It needs one public hostname with
TLS and WebSockets, nothing else: no database, no disk, no UDP.

## Add it to Port42

Whichever way you run it, you end with an address. In Port42 open **Settings**, **Relays**, and add:

    wss://your-relay-host/v1

The dot beside it turns green when Port42 reaches it. Invites you create from then on list it.

## On Railway, with no server of your own

1. Open the **Deploy on Railway** link on the relay page and sign in to Railway.
2. Deploy. Railway builds the relay from this repo and gives it an address such as
   `port42-relay-production.up.railway.app`, with TLS already on.
3. Add `wss://that-address/v1` in Settings, as above.

Without the link: in Railway choose **New project**, **Deploy from GitHub repo**, pick this repo, and
set the service's **Root directory** to `gateway`. The build and health check come from
`gateway/railway.json`.

## With Docker, on any server

    docker run -d --restart unless-stopped -p 8080:8080 ghcr.io/gordonmattey/port42-relay

Then put TLS in front of port 8080 (see below).

## As a single binary

Download the one for your machine from the relay release (Linux and macOS: `.tar.gz`, Windows: `.zip`;
x86 and ARM for each), check it against `SHA256SUMS`, and run it:

    ./port42-relay        # listens on $PORT, default 8080
    port42-relay.exe      # on Windows; set PORT with `set PORT=9000` first to change it

## TLS in front

Port42 connects with `wss://`, so the relay needs a certificate. Caddy does it in one line and fetches
the certificate itself:

    caddy reverse-proxy --from your-relay-host --to localhost:8080

Port 443 gets through restrictive networks best. The relay pings every client every 20 seconds, so
proxies that close idle connections leave it alone.

## Check it

    curl https://your-relay-host/health

answers `ok` when the relay is up.

## For maintainers: publishing

Push a tag `relay-v<version>` (for example `relay-v1.0.0`). The `relay` workflow builds the image for
x86 and ARM, pushes it to `ghcr.io/<owner>/port42-relay` with that version and `latest`, and attaches the
binaries to the tag's release. The macOS binaries built there are unsigned; `scripts/relay-dist.sh`
signs them with the Developer ID locally. The Railway template is made once, in Railway, from this repo
with the root directory `gateway`.
