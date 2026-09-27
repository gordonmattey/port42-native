port42-relay: the relay that lets Port42 instances reach each other to share ports.

It stores nothing. It pairs instances by key and forwards their end-to-end encrypted traffic.

Run it:

    ./port42-relay                 # listens on $PORT, default 8080; serves /v1 and /health
    port42-relay.exe               # on Windows

Put it behind TLS on a public hostname (a reverse proxy such as Caddy does this in one line), then in
Port42 open Settings, Relays, and add:

    wss://your-host/v1

Invites you create from then on list your relay. Full guide: docs/run-a-relay.md in the Port42 repo.
