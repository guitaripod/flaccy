extension ThemeLibrary {

    /// The theme.toml of every theme that ships in the app, in gallery order.
    /// Written by scripts/embed-themes.py from linux/data/themes, their one
    /// home; a Rust test fails when this copy differs from them.
    static let builtinDocuments: [(id: String, document: String)] = [
        ("flaccy", #"""
format = 1
name = "Flaccy"
author = "Flaccy"
description = "Covers on a soft wash of the album that is playing."

[[scheme]]
id = "adaptive"
name = "Adaptive"
accent = "artwork"

[[scheme]]
id = "rosewater"
name = "Rosewater"
accent = "#ff4d6d"

[[scheme]]
id = "aurora"
name = "Aurora"
accent = "#2dd4bf"

[[scheme]]
id = "nocturne"
name = "Nocturne"
accent = "#6e8bff"

[[scheme]]
id = "verdant"
name = "Verdant"
accent = "#34d399"

[[scheme]]
id = "sunset"
name = "Sunset"
accent = "#fb8b24"

[[scheme]]
id = "mono"
name = "Mono"
accent = "#9ca3af"
muted = true
"""#),
        ("phosphor", #"""
format = 1
name = "Phosphor"
author = "Flaccy"
description = "A terminal for your records: one typeface, hard corners, a list where the wall of covers was."
appearance = "dark"

[fonts]
interface = "JetBrains Mono, Cascadia Code, Fira Code, DejaVu Sans Mono, monospace"

[shape]
corners = "sharp"
covers = "square"
shadows = false

[layout]
albums = "list"
glow = false

[[scheme]]
id = "green"
name = "Green"
accent = "#3dff7f"
[scheme.dark]
window = "#040705"
view = "#060a07"
sidebar = "#050806"
headerbar = "#070c08"
card = "#0b130d"
popover = "#0a110c"
text = "#b9ffcf"
accent = "#2fe36c"
accent_text = "#5dff97"
on_accent = "#021006"

[[scheme]]
id = "amber"
name = "Amber"
accent = "#ffb000"
[scheme.dark]
window = "#070502"
view = "#0a0703"
sidebar = "#080603"
headerbar = "#0c0904"
card = "#130e06"
popover = "#110d05"
text = "#ffdf9e"
accent = "#f5a700"
accent_text = "#ffc23d"
on_accent = "#140c00"

[[scheme]]
id = "ice"
name = "Ice"
accent = "#7fd4ff"
[scheme.dark]
window = "#03060a"
view = "#04080d"
sidebar = "#04070b"
headerbar = "#060a10"
card = "#0a1119"
popover = "#091017"
text = "#d3ecff"
accent = "#62c4f5"
accent_text = "#8fd9ff"
on_accent = "#02101a"

[[variant]]
id = "list"
name = "List"

[[variant]]
id = "grid"
name = "Grid"
[variant.layout]
albums = "grid"
"""#),
        ("marquee", #"""
format = 1
name = "Marquee"
author = "Flaccy"
description = "One album under the lights at a time, flipped through like a jukebox."
appearance = "dark"

[shape]
corners = "round"

[layout]
albums = "carousel"
cover_size = 172

[[scheme]]
id = "neon"
name = "Neon"
accent = "#ff3ea5"
[scheme.dark]
window = "#0b0612"
view = "#0d0716"
sidebar = "#0e0818"
headerbar = "#110a1c"
card = "#1a1029"
popover = "#170e24"
wash_a = "#5a1a6e"
wash_b = "#12306b"

[[scheme]]
id = "arcade"
name = "Arcade"
accent = "#2ee6ff"
[scheme.dark]
window = "#04080f"
view = "#050a13"
sidebar = "#060b15"
headerbar = "#080e19"
card = "#0e1828"
popover = "#0c1523"
wash_a = "#0f4a78"
wash_b = "#4a1f7a"

[[scheme]]
id = "ember"
name = "Ember"
accent = "#ff6a2b"
[scheme.dark]
window = "#0d0705"
view = "#100806"
sidebar = "#110906"
headerbar = "#150b08"
card = "#21120c"
popover = "#1c0f0a"
wash_a = "#7a2a10"
wash_b = "#5a1030"

[[variant]]
id = "carousel"
name = "Carousel"

[[variant]]
id = "grid"
name = "Grid"
[variant.layout]
albums = "grid"
"""#),
        ("gallery", #"""
format = 1
name = "Gallery"
author = "Flaccy"
description = "Nothing but the covers, edge to edge."

[shape]
corners = 0.5
covers = "square"
shadows = false

[layout]
albums = "wall"
cover_size = 184
glow = false

[[scheme]]
id = "black"
name = "Black"
accent = "#f2f2f2"
muted = true
appearance = "dark"
[scheme.dark]
window = "#000000"
view = "#000000"
sidebar = "#060606"
headerbar = "#000000"
card = "#111111"
popover = "#141414"
accent = "#f2f2f2"
accent_text = "#ffffff"
on_accent = "#000000"

[[scheme]]
id = "white"
name = "White"
accent = "#141414"
muted = true
appearance = "light"
[scheme.light]
window = "#ffffff"
view = "#ffffff"
sidebar = "#f6f6f6"
headerbar = "#ffffff"
card = "#f1f1f1"
popover = "#ffffff"
accent = "#141414"
accent_text = "#000000"
on_accent = "#ffffff"

[[variant]]
id = "wall"
name = "Wall"

[[variant]]
id = "large"
name = "Large Wall"
[variant.layout]
cover_size = 264
"""#),
        ("liner-notes", #"""
format = 1
name = "Liner Notes"
author = "Flaccy"
description = "Paper, ink and a serif, read like the booklet inside the sleeve."

[fonts]
headings = "Charter, Bitstream Charter, Source Serif 4, Noto Serif, DejaVu Serif, Georgia, serif"

[shape]
corners = 0.4
shadows = false

[layout]
albums = "list"
glow = false

[[scheme]]
id = "oxblood"
name = "Oxblood"
accent = "#8c1c13"
appearance = "light"
[scheme.light]
window = "#f4efe4"
view = "#f8f4ea"
sidebar = "#eee8da"
headerbar = "#f4efe4"
card = "#fbf8f0"
popover = "#fbf8f0"
text = "#231f1a"
accent = "#8c1c13"
accent_text = "#7a1810"
on_accent = "#fbf8f0"

[[scheme]]
id = "ink"
name = "Ink"
accent = "#1d3557"
appearance = "light"
[scheme.light]
window = "#f1f0ea"
view = "#f6f5ef"
sidebar = "#e9e8e0"
headerbar = "#f1f0ea"
card = "#fafaf5"
popover = "#fafaf5"
text = "#1b1e24"
accent = "#1d3557"
accent_text = "#1a2f4d"
on_accent = "#fafaf5"

[[scheme]]
id = "lamplight"
name = "Lamplight"
accent = "#e0b070"
appearance = "dark"
[scheme.dark]
window = "#1b1814"
view = "#1f1c17"
sidebar = "#191612"
headerbar = "#1b1814"
card = "#27231d"
popover = "#27231d"
text = "#ece3d2"
accent = "#d9a55f"
accent_text = "#e6bb80"
on_accent = "#1b1408"

[[variant]]
id = "list"
name = "List"

[[variant]]
id = "grid"
name = "Grid"
[variant.layout]
albums = "grid"
cover_size = 164
"""#),
        ("hi-fi", #"""
format = 1
name = "Hi-Fi"
author = "Flaccy"
description = "Records as records: round sleeves on warm dark wood, lit like a receiver's dial."
appearance = "dark"

[shape]
corners = 1.3
covers = "circle"

[layout]
albums = "grid"
cover_size = 172
glow = false

[[scheme]]
id = "dial"
name = "Dial Amber"
accent = "#ffb454"
[scheme.dark]
window = "#17120e"
view = "#1b1510"
sidebar = "#14100c"
headerbar = "#1a140f"
card = "#261d16"
popover = "#231b14"
text = "#f3e7d8"
accent = "#f2a445"
accent_text = "#ffc27a"
on_accent = "#1f1305"

[[scheme]]
id = "cherry"
name = "Cherry"
accent = "#ff5a5f"
[scheme.dark]
window = "#170f10"
view = "#1b1213"
sidebar = "#140d0e"
headerbar = "#1a1112"
card = "#281a1c"
popover = "#241719"
text = "#f6e6e4"
accent = "#ee4f55"
accent_text = "#ff8a8d"
on_accent = "#ffffff"

[[scheme]]
id = "tape"
name = "Tape Blue"
accent = "#6fb6d9"
[scheme.dark]
window = "#0f1417"
view = "#12181b"
sidebar = "#0d1215"
headerbar = "#11171a"
card = "#1a2327"
popover = "#172024"
text = "#e2edf1"
accent = "#62aacd"
accent_text = "#93cde8"
on_accent = "#06151c"

[[variant]]
id = "grid"
name = "Grid"

[[variant]]
id = "carousel"
name = "Carousel"
[variant.layout]
albums = "carousel"
"""#),
    ]
}
