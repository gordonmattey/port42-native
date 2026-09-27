# Plan: pairing and scoped tokens

Asked by GM on 2026-09-27: `port42 pair` lets any process or app on this Mac ask Port42 for access,
the person accepts in the app, and that process is paired. Every credential gets a scope: the galaxy,
one space, or one port. Today a credential can do anything its permission cards allow, anywhere. In v1,
built after the Phase 4 merge (GM, 2026-09-27), because both change the client registry, which Phase
4 has changed. Status: design; decisions 1 to 3 made by GM (2026-09-27), 4 open.

## What exists

- **Enrolment by a named act.** A companion terminal enrols itself at spawn (`child`), the `port42`
  CLI at install (`installed`), a script by hand in Settings (`manual`). Each gets its own token in its
  own file. The registry already has a fourth kind, `paired`, with nothing that creates one.
- **Why pairing was dropped (FR5, 2026-07-30).** Pairing needs one verb a caller with no credential can
  call, and any process could then raise an "allow?" card. FR5 closed that: a caller with no credential
  can do nothing. This plan reopens it at GM's call, so the pairing verb below is built to FR5's
  standard: local only, rate limited, expiring, and approved only against a code the person reads in
  their own terminal.
- **Permission cards.** A local caller is authorized by capability (terminal, files, screen and the
  rest), asked of the person once per caller. Every port method is open to any enrolled client.
- **Phase 4's remote gate** (`RemoteAccess`, on `nautilus-phase4`). A caller from another machine is
  denied by default. One table classifies every registry method: acts on the port named by an argument
  (and needs a right on it: see, use, edit, wake agents), is a listing (filtered to the ports it holds),
  or is never reachable. `RemoteAccessTests` fails until every method is classified. Rights live in the
  `grants` table.

## Scopes

A credential carries one scope, stored on its client row:

| Scope | Reaches |
|---|---|
| **Galaxy** | Everything, as today: every space and port, and the machine through permission cards |
| **Space** *S* | Ports in *S* (home or adopted), *S*'s chat, making ports in *S*; listings show only *S* |
| **Port** *P* | *P* alone: read it, drive it, edit it, its chat; listings show only *P* |

Enforcement reuses Phase 4's table. A scoped caller passes the same gate as a remote one, with its scope
in place of grants: a method classified `.port(param)` needs that port inside the scope, a listing is
filtered to the scope, and `.never` methods are refused with `not_granted`. Space-level methods (making a
port in a space, posting to a space's chat, `whoami`, `space.current`) get a `.space(param)` class in
the same table. The gate runs before the permission card, as the remote gate does, so a scoped caller
never raises a card for something outside its scope.

## Pairing

1. In any terminal or app on this Mac: `port42 pair --name "my script"`, optionally `--space <name>` or
   `--port <id>` to ask for a narrower scope. It prints a six-digit code, such as `48 29 13`, and waits.
2. Port42 shows a card: who is asking (the name it gave, and what Port42 can verify: the program's
   path and the app it runs in, from the connection's process), the scope it asks for, and the code.
3. The person checks the code matches their terminal, may narrow the scope, and accepts or denies.
4. On accept the waiting command receives its token, writes it to its own file (mode 600), and prints
   how to use it. On deny, or after 2 minutes, it is told no.

The unauthenticated verb is `pair.request`, the only one. It is accepted only on the loopback door,
at most one pending request per process and three a minute in all, and it can do nothing but show the
card. A request that is not answered expires. Settings, Access lists paired clients with their scope,
to narrow or revoke. Pairing an agent on another machine is Phase 4's invite, not this.

## Decisions for GM

1. **DECIDED (GM): companion terminals stay galaxy in v1.** A companion has the right to join any space,
   and any port. Teams, imagine and cross-space mentions depend on it. Worked out after v1.
2. **DECIDED (GM): a space or port scope reaches ports and port chat only.** Terminal, files, screen,
   clipboard, AppleScript and REST are the desktop's (GM, 2026-07-28: "the desktop is a port, port 0"),
   so they need galaxy scope.
3. **DECIDED (GM): approval checks a code.** Six digits shown as three pairs with no hyphen, `48 29 13`,
   like Phase 4's invite code. The person matches the code in their terminal to the card, so a process
   cannot get a card approved by showing up at the right moment.
4. **How a paired process uses its token (recommended: an environment variable).** `port42 pair`
   prints `export PORT42_TOKEN_FILE=…`, the variable every Port42 caller already reads, so the same
   program keeps using it. The alternative is `port42 --as <name>` on each call.

## Steps (after the Phase 4 merge)

1. **Scope on the client row** (migration v63) and the scope gate, reusing `RemoteAccess` with the
   `.space` class added. Tests: each scope against a port, space and machine method of every class, and
   listings filtered.
2. **`pair.request` and the approval card.** Tests: loopback only, the rate limit, expiry, a wrong
   code refused, the token reaching only the requester.
3. **`port42 pair`** in the CLI: request, print the code, wait, write the token file, print the
   export line. Tests in Go against a fake door.
4. **Settings, Access:** each client's kind and scope, narrow and revoke; manual tokens get a scope at
   creation.
5. **Docs:** the ports and devices skills, `port42 help`, and the page on connecting a tool.
