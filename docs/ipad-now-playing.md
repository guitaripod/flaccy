# Now Playing on iPad: listening and browsing together

Asked for (Marcus, 2026-11-20): "Why can't the Now Playing when the sidebar is in top be just what the iOS app does? Now you can't have lyrics and browse at the same time. Think of all the UX paths like this in the app and think how iPadOS enhances the iOS experience because more space. But also keep in mind the thumb placements when used in hand."

## Look

On an 11-inch held sideways (1194 × 834) with the sidebar in the top bar, Now Playing is a column along the trailing edge, 30% of the window (360–440 pt), beside the library. Opening lyrics or the queue in it called `onFocusRequest`, and `RootContainerViewController.setPlayerFocused(true)` slid the player over the whole window and hid the library: the cover on one side, the words on the other. The same happened with the sidebar docked, and on a mini held sideways once the column had the turn. That arrangement was the iPhone Duo's focus (halves that end at a fold), applied to the iPad's column as well. So on the device with the most room, lyrics and browsing were exclusive, while the column itself is exactly an iPhone's width.

## Think: every path, iPhone floor first

| Path | iPhone | iPad before | iPad now |
| --- | --- | --- | --- |
| Lyrics or the queue while a column stands beside the library (sidebar in the top bar, docked, or a mini sideways with the column's turn) | inside the full player | spread over the window, library hidden | inside the column, as on the phone; the library stays beside it to browse, open albums and drag songs into Up Next |
| The immersive player | the full player | only by opening lyrics | the column's expand button or ⇧⌘F spreads it: cover and controls on a wide window, or cover beside lyrics or the queue; its button, ⇧⌘F or Escape bring it back |
| Going somewhere from a spread player (artist or album name, ⌘1–⌘6, ⌘F) | the player collapses and the page pushes | the page was pushed behind the spread player | the column comes back first, then the page opens beside it |
| Editing a playlist or dragging songs with the queue in view | not possible | not possible | the queue in the column beside the open playlist or album |
| A window too narrow for the column (upright 11-inch or mini, ⅔, ½, ⅓, 834 × 600) | mini player → full player | the same | the same: the phone's model is the floor and stays; a bottom pane for tall windows was considered and rejected (the library would become two short panes, and held upright the phone's model is what the hands want) |
| A mini sideways with the sidebar docked | — | the sidebar and the column take turns | unchanged; putting the sidebar in the top bar gives the column the room, now with lyrics inside it |
| Search with the keyboard up beside the column | — | the column stays | unchanged: the hands are on the keyboard |
| A spread player on the Duo (halves at a fold) | — | spread with lyrics | unchanged |

**Thumbs.** The column sits on the trailing edge; its transport, the lyrics and queue buttons and the volume all sit in its lower half, inside the right thumb's reach (at most ~254 pt from the edge on an 11-inch, where a column needs at least 1120 pt of window, so it only exists in a window that spans the screen). Expand and hide are rare and live in the column's top corner; the spread player keeps its way back in the same corner and starts its cover and lyrics below it. A 13-inch in Windowed Apps can hold a 1120-pt window against its left edge, which puts the transport up to ~436 pt from the right edge: recorded as a known limit rather than mirroring the column.

## The model

1. **The column is the iPhone's player.** Lyrics and the queue open inside it and never take the library away.
2. **Spreading is the person's choice.** The expand button beside the column's hide button, ⇧⌘F, and back by the same button, ⇧⌘F or Escape (View > Back to the Column, a menu command, so spreading never takes the keyboard from a search field and Escape still works after a sheet). A column put away, or a queue that runs out, while it is spread leaves from beside the library and ends as the mini player, never as an empty full-screen player.
3. **Everywhere else the phone's model holds**: the mini player opens the full player.

## Decision rules (`AdaptiveLayout`, unit-tested)

- `usesSplit(size:style: .column)`: a column only where the library keeps 760 pt beside it and the window is at least 560 pt tall.
- `columnWaits(width:sidebarWidth:turn:)`: a docked sidebar and the column take turns where the library would drop under 540 pt.
- `centerStateSpreadsPane(style:)`: lyrics or the queue spread a pane only for halves that end at a fold.
- `usesFocusArrangement(isSpread:showsArtwork:)`: a spread player shows cover-beside-words pages only while lyrics or the queue show; showing the cover it takes the whole-window layout of its size.
- `compactKeepsPlayerExpanded(wasSpread:hasTrack:)`: a pane that stops being a pane stays open over the window only if it was spread and a song is still current.
- `playerLayout(size:horizontalFold:focus:hasFold:)` then picks focus, landscape or portrait as before.

## Verified

- `AdaptiveLayoutTests` (38) and the app's unit tests on an iPhone Air simulator.
- Simulator captures (iPad Pro 11 and iPad mini, 27.3): 1194 × 834 with the sidebar in the top bar and docked, lyrics and queue in the column, spread with the cover and with lyrics or the queue; mini 1158 × 756; ⅔, ½, 834 × 600 and the upright mini unchanged; light and dark.
- The real iPad Pro M1 sideways with its own library: `--exercise-column` logged `COLUMN EXERCISE PASSED in a (1194.0, 834.0) window` and captures show lyrics in the column beside Home, the spread and the queue in the column.

## Not in this

The lyrics' floating buttons (meaning, share, sleep) lie over the first visible line in a phone-width player; that is the iPhone's design too, and a fade or a top inset for them is a separate change for every client.
