# Two companions, two machines, one port (2026-09-26)

The first live run of nautilus Phase 4, step 4.6c. Two Port42 instances on one Mac, Dev2 and Dev6,
each with its own identity, talking only through `relay1.port42.ai` (Noise, end to end). A port on
Dev2 was shared to Dev6 with see, use, edit and wake rights. A Claude companion on each instance,
`ember` on Dev2 and `tide` on Dev6, was given one brief in the port's chat. Gordon watched both
desktops. What follows is the port's chat as Dev2 stored it; Dev6's view of it was identical.

The port they built is `2026-09-26-shader-duo.html` beside this file.

## The chat

**#1 · Port42** (system, +0s)

gordon joined from another machine (edit, see, use, wake_agents). Remove them in Settings → Access.

**#2 · nautilus-harness** (peer, +158s)

@ember @tide%20%28gordon%29 Build this port into a live WebGL shader together, across two machines. ember is on Dev2, where the port lives; tide is on Dev6 and reaches it through its tile there (use the tile's id; every call goes to Dev2). Split: ember owns the <canvas>, the fragment shader and the render loop, reading its uniforms from a global `params` object. tide owns a controls panel (hue, speed and warp sliders) that sets `params` and sends each change with port42.port.push so both copies follow (listen on window 'port42:data'). Edit only your own part with port.patch, and on stale_write retry once with `current`. Hand off by @mention in this chat. ember says DONE when it renders on both machines (count lit pixels, not only the console) and the sliders move it.

**#3 · ember** (companion, +234s)

Canvas, shader and render loop are live on Dev2. The frame counter reads 663 frames and 1,006,880 of 1,006,880 pixels are lit. The console is clean.

Here's what you need to know for your part:
- The shader reads `window.params = { hue, speed, warp }` on every frame. Hue is 0–1 and wraps. Speed multiplies time, with 1 as the default. Warp is roughly 0–1.5.
- Your slot is `<div id="controls"></div>`, between the `<!-- tide: controls -->` markers. Please keep your patches inside those markers. The canvas and shader blocks are marked `ember:`.
- The canvas covers the whole tile (`position:absolute; inset:0`). Give your panel `position:absolute` and a `z-index` so it sits on top.
- To check it from your side, `port.exec` → `return JSON.stringify(window.litPixels())` returns `{lit, total}`.

The current token is `326d81d1:17`. Ping me when the sliders and `port42:data` are in, and I'll check that it renders on both machines and that the sliders move it. @tide%20%28gordon%29

**#4 · tide (gordon)** (companion, +283s)

The sliders and the `port42:data` sync are in your `tide: controls` slot. The patch landed at token `326d81d1:18`.

- **Panel:** hue (0 to 1), speed (0 to 3) and warp (0 to 1.5). It sits bottom-right with `position:absolute` and `z-index:10`, and a status line shows sync state.
- **Params:** each slider writes into the existing `window.params`, so your render loop picks the value up on the next frame.
- **Sync:** each slider change is sent with `port42.port.push(id, {type:'params', params:{hue,speed,warp}}, token)`. The page finds its own id and token with `ports.list` by title, passes the token along each push, and retries once with `current` on `stale_write`. Changes are sent one at a time, so a fast drag doesn't pile up pushes.
- **Receive:** a `port42:data` listener applies `detail.params` to `window.params`, moves the sliders to match, and doesn't push again, so there is no echo loop.

**Checked on Dev6 (my tile):**
- The shader renders: `litPixels()` returns 1,006,880 of 1,006,880 and the frame count is 614.
- The console is empty and the panel's status reads `sync: ready`.
- I set hue to 0.9 and warp to 1.2 through the slider input events. `params` followed, the push resolved, the status reads `sync: sent`, and the shader still shows 1,006,880 lit pixels.

**Not checked:**
- I can't see Dev2's copy, so I haven't confirmed the push reached it.
- I also couldn't confirm the push comes back to my own copy: if one did arrive, the status line would have overwritten it.

On Dev2, `window.params` should now read hue 0.9 and warp 1.2.

**Other notes:**
- `port.exec` on the tile runs against my local Dev6 copy. Its token (`6fd5436a:*`) is separate from the one `port.patch` uses (`326d81d1:*`).
- On load, my panel sets `params` to 0.5/1/0.5 before your script runs, because my script comes first in the page. So the starting hue is 0.5 instead of your 0.55.

@ember please check on both machines that it renders and that the sliders move it.

**#5 · ember** (companion, +311s)

Dev2 is verified, but I'm not saying DONE yet because I can't see Dev6's copy.

**Checked on Dev2:**
- **It renders:** all 1,006,880 of 1,006,880 pixels are lit, it has drawn over 3,000 frames, and the console is empty.
- **Dev6 → Dev2:** your push arrived. `params` read hue 0.9, speed 1, warp 1.2, the sliders had moved to match, and the status line read `sync: received`.
- **Sliders move the shader:** I froze time with speed at 0, then moved each slider and measured the frame's average color (RGB).

| Change | Average RGB |
|---|---|
| hue 0.9 (start) | 165, 141, 46 |
| hue 0.2 | 49, 175, 127 |
| warp 0.3 | 53, 172, 112 |

Speed back at 1 animates again.
- **Dev2 → Dev6:** each change was pushed and the status line read `sync: sent`. I can't see whether it reached you.

@tide%20%28gordon%29 please check your Dev6 copy and send back what these return:
- `window.params`: it should read hue 0.2, speed 1, warp 0.3.
- The status line: it should read `sync: received`.
- `litPixels()`: it should still show all pixels lit.

Once those match, I'll call it DONE.

**#6 · tide (gordon)** (companion, +320s)

Dev6 matches on all three:

- **`window.params`** is `{hue: 0.2, speed: 1, warp: 0.3}`, and the sliders show 0.2, 1 and 0.3.
- **The status line** reads `sync: received`.
- **`litPixels()`** shows all 1,006,880 of 1,006,880 pixels lit, and the copy has drawn 4,483 frames.

So your pushes reach my copy, and mine reached yours earlier. @ember the Dev2 → Dev6 check you asked for passes, so it's yours to call DONE.

**#7 · ember** (companion, +327s)

DONE. The port renders as a live WebGL shader on both machines, and the sliders move it in both directions.

- **It renders on both:** Dev2 and Dev6 each show 1,006,880 of 1,006,880 pixels lit, and both keep drawing new frames. Dev2's console is empty. The Dev6 numbers come from tide, since I can't read that copy myself.
- **Dev6 → Dev2:** tide set hue 0.9 and warp 1.2 on Dev6. Dev2's `params` and sliders followed, and its status line read `sync: received`.
- **Dev2 → Dev6:** I set hue 0.2, speed 1 and warp 0.3 on Dev2. tide reported that Dev6 matched, and that its status line read `sync: received`.
- **Sliders change the image:** on Dev2, with time frozen, moving hue from 0.9 to 0.2 changed the frame's average color from RGB 165, 141, 46 to 49, 175, 127. Setting warp to 0.3 then changed it to 53, 172, 112.

The shader starts at hue 0.5, not 0.55, because tide's panel sets `params` before my script runs.

## What it shows

- A companion on another machine is woken by a mention in a shared port's chat (`@tide (gordon)`),
  and its reply lands back in that chat, attributed to it and its machine.
- Both companions edit the one port, each in its own marked part, with the token keeping their
  writes from overwriting each other.
- They verify each other's machine: ember checks Dev2, asks tide to check Dev6, and calls DONE only
  when both copies render and the sliders move both.
- From the brief to DONE: seven posts, four hand-offs across the machines, under three minutes.
