# The interaction model: every gesture and key in the shell

Status: the rules as built, written down 2026-09-30 (Gordon: "the key and mouse actions system needs to make
sense and be consistent"; "let's make sure we write the rules out somewhere"). A design card on the board
takes it further. Change this file when a gesture or key changes.

## The rules that hold everywhere

1. **A plain drag or resize moves only what is in your hand.** Nothing else on the desktop moves unless a
   modifier asks for it.
2. **⌘ is navigation and app commands**: the zoom ladder, spaces, the switcher, imagine. The one
   exception: added to a ⇧ resize or move, it unsnaps.
3. **⇧ is "the stronger version" of what you are doing**: while resizing, the neighbors make room (snapped
   to the edge you drag; ⌘ as well unsnaps them); while moving, the ports joined to it come along; with
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
| A port's edge or corner | ⇧ drag | Resizes it, and the neighbors make room by snapping (the rows below); when one is at its smallest against any edge, the drag stops there. Afterwards "Put the layout back" undoes it in one click. Pressing or letting go of ⇧ mid-drag switches. |
| A port's edge or corner | ⇧ drag, touching a neighbor | Snaps it (#251): the port touched keeps its far edge and gives up width (or height, above or below) to stay joined to the edge being dragged, and follows it back when the edge returns. Smaller than its smallest, it slides instead. |
| A port's edge or corner | ⇧ drag, with edges lined up | Edges level with the one dragged move with it (#251): drag a port's bottom down and the port beside it whose bottom was level follows, and the row below keeps its gap. Only ports joined end to end, not across the desktop. |
| A port's title bar | ⇧ drag | Moves it with the ports joined to it (beside, above or below, within a few gaps): they move as one. A port it runs into snaps as in a ⇧ resize. ⇧⌘: it moves alone, and what it runs into slides. The move stops before pushing one off the screen; "Put the layout back" undoes it. ⇧ can go down at any point of the move, even with the pointer still: room is made from where the port is then, so a port picked up on top of another and moved clear pushes that one too. |
| A port's edge or corner | ⇧ pressed mid-drag | Takes effect at once, from where the port is then: a port that started over another, pulled clear and then given ⇧ pushes that one instead of going over it (#251). |
| A port's edge or corner | ⇧⌘ drag | Unsnapped: the neighbors it would cover slide out of the way at their own size, and shrink only once they reach the edge of the desktop. Pressing or letting go of ⌘ mid-drag switches. |
| A port's title bar | magnifier | Zoom in on it. Zoomed in, the arrows zoom back out. |
| The desktop | pinch in / out | Zoom in toward a port / out toward the galaxy. |
| The right edge | touch it, or sweep toward it | Opens the rail at once; it shuts the moment the pointer is off it. It also opens for a drag, for a moment after a drop onto it, when a popped-up port goes back, and when a running port newly needs you. |
| A Running card | click | Shows the port on the desktop (keeps it). |
| A Running card | magnifier, pinch, or ⌘↓ over it | Pops the port up for a look; a click on it keeps it, zooming out puts it back in its slot. |
| A peek | magnifier / ✕ / click / flick left | Look / skip / keep / skip. Zoomed into it, a click keeps it. |
| A browser port | the page | The person's own; touching it takes it back from a companion that was acting on it. |

## New ports

A new port goes in the largest empty area of the desktop that holds it at its own size. If none does, it
goes in the largest empty area there is and shrinks to fill it, down to the smallest a port can be (where
it shows its card). Only when there is no room at all does it land on top of the others. Nothing already
on the desktop moves.

## Keys

| Key | Does |
|---|---|
| ⌘↑ | Zoom out one level, from anywhere, even with a port holding the keyboard. |
| ⌘↓ | Zoom in, toward what the pointer is over or what is selected. A port holding the keyboard keeps it. |
| ⌘G | The galaxy, and back to the space. |
| ⌘K | The switcher. |
| ⌘I | Imagine. |
| ⌘N | A new space, and into it. |
| ⌘` / ⇧⌘` | The next / previous port on this desktop. |
| ⌘1 to ⌘9 | The Nth space. |
| Tab | Exposé, on the desktop. |
| Esc | Close a box, leave exposé, or step back from a zoomed port (not in a terminal, which needs Esc). |
| Esc, on a permission card | Deny. A click outside the card answers nothing. Return never allows: Allow is a click, or Space with keyboard navigation on. On the cross-space card (#238) each right and the space box is a checkbox, see ticked and the rest unticked. |
| Space, held | Dictate: hold, speak, let go (sends, unless turned off). Up to two minutes. |

## Several displays (#189)

With a space on each display (hold a space in the galaxy, then "Show on <display>"), every key and
gesture above acts in the window it happens in: ⌘K, ⌘I, ⌘N, ⌘G, the ladder, ⌘1 to ⌘9, Tab, Esc and pinch move
that display's window only. The window last clicked or typed in is the one in use: switching space from
anywhere (the switcher, a port link, an agent) changes it, and a new port lands there. Holding Space to
dictate works in any window. A port shown on two displays at once is live in the window in use; the
other display says where it is, and a click there brings it over. When a space rests or is deleted, the
window showing it closes; waking the space opens it in the main window. If the main window showed it while
another window was in use, the main window takes a working space no window shows, or the galaxy.

## Open

- The "hold ⇧ to make room" hint shows above the dock while resizing, and is easy to miss (Gordon,
  2026-09-30). Make it more obvious.
- ⌥ is unassigned.
