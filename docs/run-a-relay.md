# Run your own Port42 relay

When you share a port, the other person's Port42 reaches yours through a relay. Port42 uses
`relay1.port42.ai` by default, and that works without any setup. Run your own when you want sharing
to go through a machine you control, or to keep working if the default is down.

**What the relay is.** One small program. It pairs Port42 instances by key and forwards their traffic.
That traffic is encrypted end to end (Noise IK) before it reaches the relay, so the relay cannot read
it, and it stores nothing: no database, no disk, no logs of content. It needs one public hostname with
TLS and WebSockets. No UDP, no open ports beyond 443.

**Pick a way to run it:**

| You have | Use | Effort |
|---|---|---|
| No server | [Railway](#on-railway-no-server-needed) | A few clicks; Railway's pricing applies |
| A server with Docker | [Docker](#with-docker) | One command, plus TLS |
| A server, a Mac or a PC | [The binary](#as-a-single-binary) | Download and run, plus TLS |

Then [add it to Port42](#add-it-to-port42).

## On Railway (no server needed)

Railway builds the relay from this repository and gives it a public address with TLS already on.

1. Sign in at [railway.com](https://railway.com).
2. **New project**, then **Deploy from GitHub repo**, and choose `gordonmattey/port42-native`.
3. In the new service's **Settings**, set **Root directory** to `gateway`, and **Config file path**
   to `/gateway/railway.json` (Railway does not look for it inside the root directory). The build
   (from `relay.Dockerfile`) and the health check come from that file.
4. Under **Networking**, **Generate domain**. You get an address such as
   `port42-relay-production.up.railway.app`.
5. [Add it to Port42](#add-it-to-port42) as `wss://port42-relay-production.up.railway.app/v1`.

## With Docker

```
docker run -d --name port42-relay --restart unless-stopped -p 8080:8080 ghcr.io/gordonmattey/port42-relay
```

The image is about 3 MB and runs on x86 and ARM. `--restart unless-stopped` brings it back after a
crash or a reboot. Then [put TLS in front](#tls-in-front) of port 8080.

To update: `docker pull ghcr.io/gordonmattey/port42-relay`, then remove and re-run the container.

## As a single binary

Download the file for your machine from the
[relay releases](https://github.com/gordonmattey/port42-native/releases) (tags starting `relay-v`):

| Machine | File |
|---|---|
| Linux, x86 | `port42-relay-<version>-linux-amd64.tar.gz` |
| Linux, ARM (Raspberry Pi 4 or 5, Graviton) | `port42-relay-<version>-linux-arm64.tar.gz` |
| Mac, Apple silicon | `port42-relay-<version>-darwin-arm64.tar.gz` |
| Mac, Intel | `port42-relay-<version>-darwin-amd64.tar.gz` |
| Windows, x86 | `port42-relay-<version>-windows-amd64.zip` |
| Windows, ARM | `port42-relay-<version>-windows-arm64.zip` |

Check it against `SHA256SUMS` from the same release (`shasum -a 256 -c SHA256SUMS --ignore-missing`,
or `Get-FileHash` on Windows), unpack it, and run it:

```
./port42-relay                                 # macOS and Linux
.\port42-relay.exe                             # Windows PowerShell
```

It listens on port 8080. Another port: `PORT=9000 ./port42-relay`, or on Windows
`$env:PORT = "9000"; .\port42-relay.exe`.

The macOS builds are signed with Port42's Developer ID. The Windows builds are not signed yet, so
SmartScreen may warn on first run: choose **More info**, then **Run anyway**.

### Keep it running (Linux)

Save as `/etc/systemd/system/port42-relay.service`, with the binary at `/usr/local/bin/port42-relay`:

```
[Unit]
Description=Port42 relay
After=network-online.target

[Service]
ExecStart=/usr/local/bin/port42-relay
Environment=PORT=8080
Restart=always
DynamicUser=yes

[Install]
WantedBy=multi-user.target
```

Then `sudo systemctl enable --now port42-relay`. Logs: `journalctl -u port42-relay`.

To update: replace the binary and `sudo systemctl restart port42-relay`. Port42 instances reconnect on
their own.

## TLS in front

Port42 connects with `wss://`, so a relay on your own machine needs a certificate on a public hostname
(Railway does this for you). Point a domain at the machine, then [Caddy](https://caddyserver.com) does
TLS in one line and fetches the certificate itself:

```
caddy reverse-proxy --from relay.example.com --to localhost:8080
```

Open ports 80 and 443 in the firewall; 80 is only for issuing the certificate. Any reverse proxy that
passes WebSockets works as well (nginx, Cloudflare Tunnel).

## Add it to Port42

In Port42 open **Settings**, **Relays**, and add your address:

```
wss://relay.example.com/v1
```

The dot beside it turns green when Port42 reaches it. Invites you create from then on list it; invites
already sent keep the relays they were made with.

## Check it

```
curl https://relay.example.com/health
```

answers `ok` when the relay is up.

## If the dot stays grey

- **`/health` does not answer:** the relay is not running, or a firewall blocks it.
- **`/health` answers over `http` but not `https`:** TLS is not set up (see above).
- **The address:** it must start with `wss://` and end with `/v1`.
- **A proxy closes idle connections:** the relay pings every client every 20 seconds, which keeps most
  proxies open. Raise the proxy's idle timeout above 20 seconds if it still drops.

Port42 retries a relay it has lost on its own, waiting up to 30 seconds between tries.

## Limits

Built in, per relay: 32 open sessions per sharing instance, 4 per guest, 30 new connections a minute
from one IP, 10 a minute to one instance, messages up to 64 KB, and a session idle for 5 minutes is
closed. A small machine is enough: the relay only forwards bytes.

## For maintainers: publishing a release

Push a tag `relay-v<version>`, for example `relay-v1.0.0`. The `relay` workflow
(`.github/workflows/relay.yml`) then:

- builds the image for x86 and ARM and pushes it to `ghcr.io/<owner>/port42-relay` as that version and
  `latest`;
- builds the six binaries with `scripts/relay-dist.sh` and attaches them, with `SHA256SUMS`, to the
  tag's release.

The macOS binaries built there are unsigned; run `scripts/relay-dist.sh <version>` on a Mac with the
Developer ID and replace them on the release. After the first publish, make the image public in the
package's settings on GitHub, or `docker run` asks for a login.

A one-click "Deploy on Railway" button needs a template, made once in Railway from this repository with
the root directory `gateway`; its link then goes at the top of the Railway section above.
