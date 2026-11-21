//! The file that holds the Swift themes to the Rust ones. This writes what
//! Rust makes of every built-in theme, of a set of awkward documents, of
//! seed colors and of carousel layouts into one JSON file that FlaccyCore's
//! `ThemeGoldenTests` replays; the test here fails when the file on disk is
//! not what Rust would write now. Rewrite it with
//! `FLACCY_WRITE_THEME_GOLDEN=1 cargo test theme::golden`.

use super::builtin;
use super::color::{hex, parse_hex, Rgb};
use super::look::{derive, Choice, Look, Palette};
use super::pack::{parse, AlbumsView, Appearance, CoverShape, Pack, Style};
use flaccy_shared::flow_geometry::{Flow, Glide};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::rc::Rc;

const DOCUMENTS: [(&str, &str); 22] = [
    ("a name alone", "name = \"Plain\""),
    ("no name", "author = \"me\""),
    ("a blank name", "name = \"   \""),
    ("a newer format", "format = 2\nname = \"Later\""),
    ("a format with a fraction", "format = 1.5\nname = \"Between\""),
    ("not toml", "name = "),
    ("an open string", "name = \"Open\ndescription = \"x\""),
    ("a key set twice", "name = \"Twice\"\nname = \"Again\""),
    ("a missing equals", "name \"Nope\""),
    (
        "every mistake at once",
        "name = \"Typo\"\ncolour = \"red\"\nappearance = \"night\"\n[layout]\nalbums = \"gird\"\ncover_size = 900\nglow = \"yes\"\n[shape]\ncorners = 7\ncovrs = \"square\"\n[[scheme]]\nname = \"One\"\naccent = \"pink\"\n[scheme.dark]\nwindow = \"#12\"\n[[scheme]]\nname = \"One\"\n",
    ),
    ("a scheme written as one table", "name = \"Single\"\n[scheme]\nname = \"Only\"\naccent = \"#123456\"\n"),
    ("tables written as values", "name = \"Flat\"\nfonts = \"Inter\"\nlayout = 3\nvariant = \"wall\"\n"),
    (
        "numbers of every kind",
        "name = \"Numbers\"\n[shape]\ncorners = 0.3\n[layout]\ncover_size = 171.6\n[[variant]]\nname = \"Low\"\n[variant.shape]\ncorners = -1\n[variant.layout]\ncover_size = 12\n[[variant]]\nname = \"High\"\n[variant.shape]\ncorners = 2.5\n",
    ),
    (
        "wrong types everywhere",
        "name = \"Types\"\nauthor = 7\ndescription = true\n[fonts]\ninterface = 12\nheadings = [\"a\"]\n[shape]\ncorners = true\ncovers = 1\nshadows = \"no\"\n[layout]\nalbums = false\ncover_size = \"big\"\nglow = 1\n[[scheme]]\nname = 3\naccent = 0xff\nmuted = \"yes\"\nappearance = 1\n",
    ),
    (
        "names that need ids",
        "name = \"Ids\"\n[[scheme]]\nname = \"Amber Glow\"\n[[scheme]]\nid = \"  Hi-Fi  '77! \"\nname = \"Second\"\n[[scheme]]\nname = \"¡¡¡\"\n[[scheme]]\nid = \"amber glow\"\nname = \"Fourth\"\n[[variant]]\n[[variant]]\nname = \"Variant 1\"\n",
    ),
    (
        "dotted keys and inline tables",
        "name = \"Dotted\"\nfonts.interface = \"Inter, sans-serif\"\nshape = { corners = \"round\", covers = \"circle\" }\nlayout.albums = \"CAROUSEL\"\nlayout.glow = false\n",
    ),
    (
        "a windows file with comments",
        "# made on windows\r\nname = \"Windows\"  # trailing\r\n[layout]\r\nalbums = 'wall'\r\n\r\n[[scheme]]\r\nname = \"Day\"\r\naccent = \"#0F8\"\r\n",
    ),
    (
        "long strings",
        "name = \"\"\"Long\"\"\"\ndescription = \"\"\"\nTwo lines \\\n   made one.\"\"\"\nauthor = '''Some\"one'''\n",
    ),
    (
        "exact colors in both modes",
        "name = \"Exact\"\n[[scheme]]\nname = \"Both\"\naccent = \"ARTWORK\"\nmuted = true\n[scheme.dark]\nwindow = \"#000000\"\nheaderbar = \"#101010\"\naccent = \"#ffee00\"\ntext = \"#e0fff8\"\n[scheme.light]\ncard = \"#ffffff\"\npopover = \"#fafafa\"\non_accent = \"#000\"\naccent_text = \"#102030\"\nwash_a = \"#abcdef\"\nwash_b = \"#fedcba\"\nsidebar = \"#eeeeee\"\nview = \"#fdfdfd\"\n",
    ),
    (
        "a scheme with its own mode",
        "name = \"Modes\"\nappearance = \"light\"\n[[scheme]]\nname = \"Day\"\naccent = \"#8c1c13\"\n[[scheme]]\nname = \"Night\"\naccent = \"#e0b070\"\nappearance = \"dark\"\n[[scheme]]\nname = \"Either\"\naccent = \"#2dd4bf\"\nappearance = \"any\"\n",
    ),
    ("a date nobody asked for", "name = \"Dated\"\nmade = 2026-11-21\n[layout]\nalbums = \"list\"\n"),
    ("a table reopened", "name = \"Twice\"\n[layout]\nalbums = \"list\"\n[shape]\ncovers = \"square\"\n[layout]\nglow = false\n"),
];

const SEEDS: [&str; 12] = [
    "#ff4d6d", "#2dd4bf", "#6e8bff", "#34d399", "#fb8b24", "#9ca3af", "#fff040", "#101010", "#ffffff", "#000000",
    "#7a3b12", "#3dff7f",
];

fn color(value: Rgb) -> Value {
    json!(hex(value))
}

fn palette(palette: &Palette) -> Value {
    json!({
        "accent": color(palette.accent_bg),
        "on_accent": color(palette.accent_fg),
        "accent_text": color(palette.accent_text),
        "wash_a": color(palette.wash_a),
        "wash_b": color(palette.wash_b),
        "card": color(palette.surface),
        "window": color(palette.window),
        "headerbar": color(palette.headerbar),
        "sidebar": color(palette.sidebar),
        "view": color(palette.view),
        "popover": color(palette.popover),
        "text": palette.text.map(color),
    })
}

fn appearance(value: Appearance) -> &'static str {
    match value {
        Appearance::Any => "any",
        Appearance::Dark => "dark",
        Appearance::Light => "light",
    }
}

fn look(look: &Look) -> Value {
    json!({
        "scheme": look.scheme().id,
        "variant": look.variant.map(|index| look.pack.variants[index].id.clone()),
        "interface_font": look.interface_font,
        "heading_font": look.heading_font,
        "corners": look.corners,
        "covers": look.covers.id(),
        "shadows": look.shadows,
        "albums": look.albums.id(),
        "cover_size": look.cover_size,
        "glow": look.glow,
        "appearance": appearance(look.appearance()),
        "follows_artwork": look.follows_artwork(),
        "dark": palette(&look.palette(true, None)),
        "light": palette(&look.palette(false, None)),
        "dark_with_cover": palette(&look.palette(true, Some((0x1f, 0x6f, 0xeb)))),
    })
}

/// Every look a theme can resolve to with nothing of the person's own on it:
/// each scheme with each variant.
fn looks(pack: &Rc<Pack>) -> Vec<Value> {
    let variants: Vec<String> = if pack.variants.is_empty() {
        vec![String::new()]
    } else {
        pack.variants.iter().map(|variant| variant.id.clone()).collect()
    };
    pack.schemes
        .iter()
        .flat_map(|scheme| {
            variants.iter().map(|variant| {
                let choice = Choice {
                    pack: pack.id.clone(),
                    scheme: scheme.id.clone(),
                    variant: variant.clone(),
                };
                look(&Look::resolve(pack, &choice, &Style::default()))
            })
        })
        .collect()
}

fn theme(pack: &Rc<Pack>) -> Value {
    json!({
        "id": pack.id,
        "name": pack.name,
        "author": pack.author,
        "description": pack.description,
        "appearance": appearance(pack.appearance),
        "warnings": pack.warnings,
        "schemes": pack.schemes.iter().map(|scheme| json!({"id": scheme.id, "name": scheme.name})).collect::<Vec<_>>(),
        "variants": pack.variants.iter().map(|variant| json!({"id": variant.id, "name": variant.name})).collect::<Vec<_>>(),
        "looks": looks(pack),
    })
}

fn documents() -> Vec<Value> {
    DOCUMENTS
        .iter()
        .map(|(name, document)| match parse("case", document) {
            Ok(pack) => json!({"name": name, "document": document, "theme": theme(&Rc::new(pack))}),
            Err(reason) => json!({"name": name, "document": document, "refused": reason}),
        })
        .collect()
}

fn derived() -> Vec<Value> {
    SEEDS
        .iter()
        .flat_map(|seed| {
            [(false, true), (false, false), (true, true), (true, false)].map(|(muted, dark)| {
                let rgb = parse_hex(seed).expect("a seed is a color");
                json!({"seed": seed, "muted": muted, "dark": dark, "palette": palette(&derive(rgb, muted, dark))})
            })
        })
        .collect()
}

/// The person's own choices over a theme, and a choice the theme does not have.
fn own_choices() -> Vec<Value> {
    let pack = builtin::packs().into_iter().find(|pack| pack.id == "phosphor").expect("phosphor ships");
    let cases = [
        ("gone", "gone", Style::default()),
        (
            "amber",
            "grid",
            Style {
                interface_font: Some("Inter".to_string()),
                corners: Some(1.6),
                covers: Some(CoverShape::Circle),
                albums: Some(AlbumsView::Carousel),
                cover_size: Some(999),
                glow: Some(true),
                ..Style::default()
            },
        ),
        (
            "ice",
            "",
            Style {
                cover_size: Some(10),
                shadows: Some(true),
                heading_font: Some("Charter".to_string()),
                ..Style::default()
            },
        ),
    ];
    cases
        .into_iter()
        .map(|(scheme, variant, own)| {
            let choice = Choice {
                pack: pack.id.clone(),
                scheme: scheme.to_string(),
                variant: variant.to_string(),
            };
            json!({
                "scheme": scheme,
                "variant": variant,
                "own": {
                    "interface_font": own.interface_font,
                    "heading_font": own.heading_font,
                    "corners": own.corners,
                    "covers": own.covers.map(CoverShape::id),
                    "shadows": own.shadows,
                    "albums": own.albums.map(AlbumsView::id),
                    "cover_size": own.cover_size,
                    "glow": own.glow,
                },
                "look": look(&Look::resolve(&pack, &choice, &own)),
            })
        })
        .collect()
}

fn flow() -> Vec<Value> {
    let rooms = [
        (1350.0, 600.0, 0.0, 829),
        (1350.0, 600.0, 5.0, 829),
        (1350.0, 600.0, 5.37, 829),
        (1350.0, 600.0, 828.0, 829),
        (390.0, 320.0, 2.5, 6),
        (1024.0, 420.0, 0.5, 2),
        (300.0, 100.0, 0.0, 1),
        (4000.0, 2000.0, 40.75, 100),
        (800.0, 400.0, 0.0, 0),
    ];
    rooms
        .into_iter()
        .map(|(width, height, position, count)| {
            let flow = Flow::fitting(width, height);
            let slots: Vec<Value> = flow
                .slots(width, height, position, count)
                .into_iter()
                .map(|slot| json!({"index": slot.index, "x": slot.x, "y": slot.y, "side": slot.side, "opacity": slot.opacity}))
                .collect();
            json!({
                "width": width, "height": height, "position": position, "count": count,
                "side": flow.side, "gap": flow.gap, "pitch": flow.pitch(), "slots": slots,
            })
        })
        .collect()
}

/// Where a glide from 0 to 3 is after every tenth frame at 60 frames a second.
fn glide() -> Vec<Value> {
    let mut glide = Glide::default();
    let mut frames = 0;
    let mut marks = Vec::new();
    while glide.step(3.0, 1.0 / 60.0) {
        frames += 1;
        if frames % 10 == 0 {
            marks.push(json!({"frame": frames, "position": glide.position, "velocity": glide.velocity}));
        }
    }
    marks.push(json!({"frame": frames + 1, "position": glide.position, "velocity": glide.velocity}));
    marks
}

fn golden() -> String {
    let builtin: Vec<Value> = builtin::packs().iter().map(theme).collect();
    let all = json!({
        "builtin": builtin,
        "documents": documents(),
        "derived": derived(),
        "own_choices": own_choices(),
        "flow": flow(),
        "glide": glide(),
    });
    let mut text = serde_json::to_string_pretty(&all).expect("the golden file is plain JSON");
    text.push('\n');
    text
}

fn flaccy_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

#[test]
fn the_golden_file_is_what_rust_makes_of_every_theme() {
    let path = flaccy_root().join("Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/theme-golden.json");
    let fresh = golden();
    if std::env::var_os("FLACCY_WRITE_THEME_GOLDEN").is_some() {
        std::fs::write(&path, &fresh).expect("the golden file can be written");
    }
    let stored = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        stored == fresh,
        "{} is out of date: run FLACCY_WRITE_THEME_GOLDEN=1 cargo test theme::golden, then the Swift tests",
        path.display()
    );
}

#[test]
fn the_swift_copy_of_every_builtin_document_is_current() {
    let path = flaccy_root().join("Core/FlaccyCore/Sources/FlaccyCore/Themes/BuiltinThemeDocuments.swift");
    let swift = std::fs::read_to_string(&path).unwrap_or_default();
    for source in &builtin::SOURCES {
        assert!(
            swift.contains(&format!("(\"{}\", #\"\"\"\n{}\"\"\"#)", source.id, source.document)),
            "{} does not hold {}'s theme.toml as it is now: run scripts/embed-themes.py",
            path.display(),
            source.id
        );
    }
}
