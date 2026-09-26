# Bug: a port made with port.create does not appear until it is focused

Reported 2026-09-26 by GM ("this has been happening"), reproduced by a companion (lucky-ibis) in prod. App 0.5.54, repo `nautilus` at dafefc8.

## What happens

`port.create` returns success and `ports.list` reports the port as `tiled` in the currently selected space, with a position on the desktop. Nothing appears on screen. The port shows up as soon as the caller sends `port.manage(action: "focus")`.

## Repro

1. From a companion terminal in the selected space (here `port42-app`, `D2ED12EF-…`), create a browser port:
   `port.create({type:"browser", url:"http://127.0.0.1:4299/index-nautilus.html", title:"port42.ai · nautilus homepage v1"})`
   → `{id: "8E002778-2A63-434F-914A-2608AC9F2442", token: "51222e11:2"}`
2. `ports.list` → `status: "tiled"`, `spaceId: D2ED12EF-…`, `x: 53`, `y: 345`.
3. `space.current()` → `D2ED12EF-…` (`port42-app`), the same space. The tile is not visible to the user.
4. `port.manage({id, action:"focus", token:"51222e11:2"})` → `{ok:true, token:"51222e11:3"}`. The tile appears.

## Expected

A port created into the selected space with the default presentation (`tiled`) is on screen when `port.create` returns, the way scenario 1 describes ("A port appears each time").

## Notes

- Seen with a browser port. Not yet checked whether web and terminal ports do the same, or whether it depends on the desktop being zoomed out, another port being focused, or the free-spot placement landing off the visible area (`x: 53, y: 345` should be on screen).
- The token advancing from `:2` to `:3` on focus shows the focus was a state change, so the tile existed but was not raised or not rendered.
- Workaround for callers: follow `port.create` with `port.manage focus`.
- Scenario 1 and the `/imagine` flow both depend on a new port being visible without an extra call. Worth a harness check that asserts the tile is on screen, beyond `status: tiled`.

## Second occurrence, same port

After it was visible, `port.exec({js:"location.reload()", token:"51222e11:5"})` returned `ok` with token `:6`. The tile then disappeared again for GM. `ports.list` still reported `status: tiled`, same `x: 53, y: 345`, same space as `space.current()`, token `:7` (one more write happened in between, source unknown). `port.manage focus` with `:7` brought it back (`:8`). So it is not only a create-time problem. A browser port can drop off screen while its record says tiled, and focus restores it.

## Clue: a write lands right after every reload

Both reloads were followed within seconds by one more write the caller did not make: `:6` then `:7`, and later `:40` then `:41` (`port.exec location.reload()` returned `:40`, and `ports.list` three seconds later showed `:41`). The first time, the tile vanished in that window. A browser page reload likely fires a navigation or title update that writes the port record, and that write may be what drops the tile off screen. Worth logging the source of that write.
