# The interaction model: every gesture and key in the shell

Status: the rules as built, written down 2026-09-30 (Gordon: "the key and mouse actions system needs to make
sense and be consistent"; "let's make sure we write the rules out somewhere"). A design card on the board
takes it further. Change this file when a gesture or key changes.

## The rules that hold everywhere

1. **A plain drag or resize moves only what is in your hand.** Nothing else on the desktop moves unless a
   modifier asks for it.
2. **⌘ is navigation and app commands**: the zoom ladder, spaces, the switcher, imagine.
3. **⇧ is "the stronger version" of what you are doing**: while resizing, the neighbors make room; with
   ⌘`, cycling goes backward.
4. **⌥ is free.** Nothing uses it today (the resize quick look was removed). Keep it for a later need.
5. **Esc steps back one level**, except where a terminal needs Esc for itself.
6. **Click keeps, magnifier looks.** On anything on loan (a peek, a running port popped up), the magnifier
   (or a pinch, or ⌘↓) zooms in for a look, a click keeps it, and zooming out without one puts it back.

## Mouse and trackpad

| Where | Gesture | Does |
|---|---|---|
| A port's title bar | drag | Moves the port. Dropped on the rail: top is Paused, the middle is Running (in the slot shown), the trash closes it. The rail opens for the whole drag. |
| A port's edge or corner | drag | Resizes it; it covers what it overlaps. |
| A port's edge or corner | ⇧ drag | Resizes it; the neighbors it would cover slide out of the way at their own size, and shrink only once they reach the edge of the desktop. Afterwards "Put the layout back" undoes it in one click. Pressing or letting go of ⇧ mid-drag switches. |
| A port's title bar | magnifier | Zoom in on it. Zoomed in, the arrows zoom back out. |
| The desktop | pinch in / out | Zoom in toward a port / out toward the galaxy. |
| The right edge | touch it, or sweep toward it | Opens the rail at once; it shuts the moment the pointer is off it. It also opens for a drag, for a moment after a drop onto it, when a popped-up port goes back, and when a running port newly needs you. |
| A Running card | click | Shows the port on the desktop (keeps it). |
| A Running card | magnifier, pinch, or ⌘↓ over it | Pops the port up for a look; a click on it keeps it, zooming out puts it back in its slot. |
| A peek | magnifier / ✕ / click / flick left | Look / skip / keep / skip. Zoomed into it, a click keeps it. |
| A browser port | the page | The person's own; touching it takes it back from a companion that was acting on it. |

## Keys

| Key | Does |
|---|---|
| ⌘↑ | Zoom out one level, from anywhere, even with a port holding the keyboard. |
| ⌘↓ | Zoom in, toward what the pointer is over or what is selected. A port holding the keyboard keeps it. |
| ⌘G | The galaxy, and back to the space. |
| ⌘K | The switcher. |
| ⌘I | Imagine. |
| ⌘` / ⇧⌘` | The next / previous port on this desktop. |
| ⌘1 to ⌘9 | The Nth space. |
| Tab | Exposé, on the desktop. |
| Esc | Close a box, leave exposé, or step back from a zoomed port (not in a terminal, which needs Esc). |
| Space, held | Dictate: hold, speak, let go (sends, unless turned off). Up to two minutes. |

## Open

- The "hold ⇧ to make room" hint shows above the dock while resizing, and is easy to miss (Gordon,
  2026-09-30). Make it more obvious.
- Whether ⇧ while moving should push neighbors too, for the same meaning on both.
- ⌥ is unassigned.
