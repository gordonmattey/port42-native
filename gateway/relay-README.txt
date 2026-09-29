PORT42 RELAY
============

When you share a port, the other person's Port42 reaches yours through a relay. Port42 uses
relay1.port42.ai by default. This is the same relay, for running your own.

The relay stores nothing. It pairs Port42 instances by key and forwards their traffic, which is
encrypted end to end before it arrives, so the relay cannot read it. It needs one public hostname
with TLS and WebSockets. No database, no disk, no UDP.

Full guide, including one-click hosting on Railway:
https://github.com/gordonmattey/port42-native/blob/main/docs/run-a-relay.md


1. RUN IT
---------

macOS and Linux:

    ./port42-relay

Windows (PowerShell):

    .\port42-relay.exe

It listens on port 8080 and serves /v1 (the relay) and /health. To use another port, set PORT first:

    PORT=9000 ./port42-relay                 macOS and Linux
    $env:PORT = "9000"; .\port42-relay.exe   Windows PowerShell

Before running a download, check it came from Port42's own build (the file name is the one you got):

    shasum -a 256 -c SHA256SUMS --ignore-missing                              macOS and Linux
    gh attestation verify port42-relay-<version>-<os>-<arch>.tar.gz --repo gordonmattey/port42-native

The second line checks the signed build provenance GitHub attached to the release. On Windows use
Get-FileHash and compare with SHA256SUMS, and the same gh command. The macOS builds are signed and
notarized. The Windows builds are not signed yet, so SmartScreen warns about them as it does about any
unsigned program; only run one whose checksum and attestation you have just verified.


2. PUT TLS IN FRONT
-------------------

Port42 connects with wss://, so the relay needs a certificate on a public hostname. Point a domain at
the machine, then Caddy (https://caddyserver.com) does TLS in one line and fetches the certificate
itself:

    caddy reverse-proxy --from relay.example.com --to localhost:8080

Open ports 80 and 443 in the firewall (80 is only for the certificate). Port 443 gets through
restrictive networks best.


3. ADD IT TO PORT42
-------------------

In Port42 open Settings, Relays, and add:

    wss://relay.example.com/v1

The dot beside it turns green when Port42 reaches it. Invites you create from then on list it.


4. CHECK IT
-----------

    curl https://relay.example.com/health

answers "ok" when the relay is up.


5. KEEP IT RUNNING
------------------

Linux with systemd: save as /etc/systemd/system/port42-relay.service, then
`sudo systemctl enable --now port42-relay`.

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

Docker does this for you with --restart unless-stopped (see the full guide).


IF THE DOT STAYS GREY
---------------------

- /health does not answer: the relay is not running, or the firewall blocks it.
- /health answers over http but not https: TLS is not set up (step 2).
- The address in Settings must start with wss:// and end with /v1.
- A proxy that closes idle connections: the relay pings every client every 20 seconds, which keeps
  most proxies open; raise the proxy's idle timeout above that if it still drops.


LIMITS
------

Built in, per relay: 32 open sessions per sharing instance, 4 per guest, 30 new connections per minute
per IP, 10 per minute to one instance, messages up to 64 KB, idle sessions closed after 5 minutes.


UPDATING
--------

Stop it, replace the binary with the new release, start it again. Sessions reconnect on their own.
