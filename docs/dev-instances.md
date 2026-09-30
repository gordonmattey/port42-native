# Dev instances: who uses which

Every build stops and relaunches its instance, so two people on one instance wreck each other's tests.
Each has an owner. Build and test only on yours; the daily driver (Port42, 4242) is never a test bed.

| Instance | Gateway | Owner | For |
|---|---|---|---|
| Dev | 4243 | Gordon | His own work |
| Dev5 | 4247 | Gordon | Locked to him for now (2026-09-29) |
| Dev6, Dev7 | 4248, 4249 | Dev lead | Features, and sharing tests between two instances |
| Dev3 | 4245 | Squad (cosmic-hare) | Each batch, checked before it is handed over |
| Dev8 | 4250 | Squad specialists | Their own fixes, checked as a person would use them |
| Dev4 | 4246 | watch-dev | Watch |
| Dev9 | 4251 | Architect | Spikes |
| Dev11 | 4253 | Gordon | Release smoke tests: a fresh instance, set up by hand |
| Dev2 | 4244 | Spare | Ask first, e.g. growth trying a feature before it ships |

`./build.sh --devN --run` builds and launches one.

## Locks

A lock says who holds an instance right now; `build.sh` refuses anyone else's build of it and names the
holder.

    scripts/dev-lock.sh dev5 gordon "testing the rail"   # take it
    scripts/dev-lock.sh dev5 --release                   # give it back
    scripts/dev-lock.sh                                   # who holds what

Say who you are when you build: `PORT42_DEV_OWNER=<name> ./build.sh --devN --run`. Locks live in
`~/.port42/dev-locks/`, one file per instance: the holder, why, since when.

**Your own token comes with the lock.** Taking a lock also enrols a client named after you on that
instance, and the script prints its token path, `~/.port42/port42devN/tokens/<name>`. Call the instance
with it (`PORT42_TOKEN_FILE=<that path> port42 --port <gateway> ...`), so every call you make while
testing is attributed to you; never mint a token by hand or borrow another tool's. The instance writes the
token when it runs (at once if it is already running, from your own build). `--release` revokes the
client again. The request passes through `~/.port42/port42devN/enrol/`, which only dev instances read.

**A lock is refused while someone else's app holds the instance.** If the instance's gateway port is
held by an app from another build folder (or by anything else), the script names it and its pid and
refuses: two apps on one gateway fight each other. Stop it, or ask whoever built it.

## Testing what you ship

A fix or feature a person has to try is built and checked on its builder's own instance before it is
handed over, and the hand-off says what was checked and what was not.
