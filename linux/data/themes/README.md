# Flaccy themes

A theme is a folder. Flaccy for Linux reads every folder in

    ~/.local/share/flaccy/themes/

and lists it in Preferences → Appearance beside the themes it ships with (**Open Themes Folder** on that page opens the folder wherever your install keeps it). The quickest way to start is **Copy … to Change It**: it writes the theme you are wearing into this folder as files you can edit, and puts the copy on.

    my-theme/
      theme.toml     what the theme is: colors, fonts, shapes, layout   (required)
      style.css      anything else, as GTK CSS                          (optional)
      fonts/         .ttf / .otf files the theme uses                   (optional)
      anything else  pictures and so on that style.css points at        (optional)

The folder's name is the theme's id. Save a file and Flaccy shows the change at once; nothing needs restarting. To share a theme, send the folder.

## theme.toml

Only `name` is required. Everything left out stays as Flaccy has it.

```toml
format = 1
name = "My Theme"
author = "Me"
description = "One line that shows under the theme in Preferences."
appearance = "dark"            # "dark", "light", or "any" (the default) to follow the Mode setting

[fonts]
interface = "JetBrains Mono, monospace"   # a list: the first one installed is used
headings = "Charter, serif"               # titles only

[shape]
corners = "sharp"              # "sharp", "standard", "round", or a number from 0 to 2
covers = "square"              # "rounded", "square" or "circle"
shadows = false                # the shadow under covers

[layout]
albums = "list"                # "grid", "wall", "list" or "carousel"
cover_size = 172               # the edge of a grid or wall cover, 96 to 320
glow = false                   # the colored wash behind the window
```

### Colors

A theme has one or more color schemes; the person picks between them under **Colors**. A scheme needs only an accent. Flaccy works every other color out of it, for dark and for light.

```toml
[[scheme]]
name = "Rose"
accent = "#ff4d6d"             # or "artwork" to follow the cover of what is playing
muted = false                  # true keeps the surfaces nearly gray

[[scheme]]
name = "Green Screen"
accent = "#3dff7f"
appearance = "dark"            # this scheme alone is dark only
[scheme.dark]                  # exact colors for dark; use [scheme.light] for light
window = "#040705"             # behind everything
view = "#060a07"               # lists
sidebar = "#050806"
headerbar = "#070c08"          # also dialogs
card = "#0b130d"               # raised surfaces
popover = "#0a110c"            # menus
text = "#b9ffcf"
accent = "#2fe36c"             # buttons, the play button, selections
accent_text = "#5dff97"        # links and highlighted words
on_accent = "#021006"          # text and icons on the accent
wash_a = "#103820"             # the two colors of the window glow
wash_b = "#0a2a40"
```

Colors are written `#rrggbb`. State only the ones you care about.

### Variants

A variant is a second arrangement of the same theme, chosen under **Variant**. It can change anything `[fonts]`, `[shape]` and `[layout]` can.

```toml
[[variant]]
name = "List"

[[variant]]
name = "Wall"
[variant.layout]
albums = "wall"
cover_size = 220
```

## style.css

`style.css` is applied on top of Flaccy's own stylesheet and can restyle anything. It is [GTK CSS](https://docs.gtk.org/gtk4/css-overview.html): most of web CSS, without layout properties.

- Use the theme's colors by name so every scheme works: `@accent_bg_color`, `@accent_color`, `@accent_fg_color`, `@window_bg_color`, `@window_fg_color`, `@view_bg_color`, `@headerbar_bg_color`, `@sidebar_bg_color`, `@card_bg_color`, `@flaccy_wash_a`, `@flaccy_wash_b`. `alpha(@accent_bg_color, 0.3)` makes one translucent.
- `url("paper.png")` is read from the theme's folder.
- A font file in `fonts/` can be named in `[fonts]` or in `font-family` like an installed one.
- `font-size` in `px` follows the Interface Scale setting.

The parts worth knowing:

| Class | What it is |
| --- | --- |
| `.flaccy-window` | the window; its `background-image` is the glow |
| `.flaccy-sidebar > row` | a row of the library sidebar (`:selected`, `:hover`) |
| `.transport`, `.play-pill` | the bar along the bottom, and its play button |
| `.cover`, `.cover-large`, `.cover-thumb` | covers at each size |
| `.album-grid`, `.album-tile`, `.album-title` | the Albums grid, one tile, a title |
| `.album-wall`, `.wall-tile`, `.wall-caption` | the wall, one cover, the caption shown on hover |
| `.album-list > row`, `.list-cover`, `.album-pane` | the list, its small covers, the pane beside it |
| `coverflow`, `.flow-cover`, `.flow-title` | the carousel, its covers, the title under it |
| `.chip` | a filter chip (`:checked` when on) |
| `.title-1` … `.title-4`, `.heading`, `.caption`, `.dim` | text sizes and the dimmed text |
| `.np-root`, `.np-card-title`, `.lyric-line`, `.lyric-line-current` | Now Playing and its lyrics |
| `headerbar`, `button`, `entry`, `popover`, `row`, `separator` | GTK's own parts |

To find the class of anything else, start Flaccy with `GTK_DEBUG=interactive flaccy`: the inspector shows every widget's classes and lets you try CSS live.

## When something is wrong

Preferences → Appearance lists what it could not use, under the theme: a misspelt key, a color that is not one, a line of `style.css` GTK refused, each named with where it is. The rest of the theme still applies. A folder that cannot be read at all (no `theme.toml`, not valid TOML, written for a newer Flaccy) is listed under **Your Own Themes** with the reason.

The themes Flaccy ships with are written the same way and make good examples: copy one from Preferences and read its files.
