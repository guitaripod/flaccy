use super::builtin;
use super::pack::{parse, slug, Pack};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::rc::Rc;

pub const DOCUMENT_NAME: &str = "theme.toml";
pub const STYLESHEET_NAME: &str = "style.css";
pub const FONTS_FOLDER: &str = "fonts";

const FONT_EXTENSIONS: [&str; 4] = ["ttf", "otf", "ttc", "otc"];

/// A folder in the themes folder that could not be used, and why.
#[derive(Clone, Debug, PartialEq)]
pub struct Problem {
    pub folder: String,
    pub reason: String,
}

/// Every theme the app can wear: the built-in ones first, then the person's
/// own in folder order.
#[derive(Default)]
pub struct Library {
    pub packs: Vec<Rc<Pack>>,
    pub problems: Vec<Problem>,
}

impl Library {
    /// The theme with this id, or Flaccy's own when there is none: a theme
    /// folder that was deleted or renamed must not leave the app unstyled.
    pub fn find(&self, id: &str) -> Rc<Pack> {
        self.packs
            .iter()
            .find(|pack| pack.id == id)
            .or_else(|| {
                self.packs
                    .iter()
                    .find(|pack| pack.id == builtin::DEFAULT_ID)
            })
            .or_else(|| self.packs.first())
            .cloned()
            .expect("the built-in themes are always present")
    }

    pub fn has(&self, id: &str) -> bool {
        self.packs.iter().any(|pack| pack.id == id)
    }
}

fn read_user_pack(folder: &Path, id: &str) -> Result<Pack, String> {
    let document =
        fs::read_to_string(folder.join(DOCUMENT_NAME)).map_err(|error| match error.kind() {
            io::ErrorKind::NotFound => format!("There is no {DOCUMENT_NAME} in this folder."),
            _ => format!("{DOCUMENT_NAME} could not be read: {error}."),
        })?;
    let mut pack = parse(id, &document)?;
    match fs::read_to_string(folder.join(STYLESHEET_NAME)) {
        Ok(css) => pack.css = Some(css).filter(|css| !css.trim().is_empty()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => pack
            .warnings
            .push(format!("{STYLESHEET_NAME} could not be read: {error}")),
    }
    pack.dir = Some(folder.to_path_buf());
    Ok(pack)
}

fn user_folders(themes_dir: &Path) -> Vec<(String, PathBuf)> {
    let Ok(entries) = fs::read_dir(themes_dir) else {
        return Vec::new();
    };
    let mut folders: Vec<(String, PathBuf)> = entries
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            (!name.starts_with('.')).then(|| (name, entry.path()))
        })
        .collect();
    folders.sort();
    folders
}

/// Reads the built-in themes and every folder of `themes_dir`. A folder named
/// like a built-in theme does not replace it; it is listed as a problem so the
/// person can rename it.
pub fn load(themes_dir: &Path) -> Library {
    let mut library = Library {
        packs: builtin::packs(),
        problems: Vec::new(),
    };
    for (name, folder) in user_folders(themes_dir) {
        if library.has(&name) {
            library.problems.push(Problem {
                folder: name.clone(),
                reason: format!(
                    "Flaccy already has a theme with the id \"{name}\". Rename the folder."
                ),
            });
            continue;
        }
        match read_user_pack(&folder, &name) {
            Ok(pack) => library.packs.push(Rc::new(pack)),
            Err(reason) => library.problems.push(Problem {
                folder: name,
                reason,
            }),
        }
    }
    library
}

/// The font files a theme brings along in its `fonts` folder.
pub fn font_files(pack: &Pack) -> Vec<PathBuf> {
    let Some(dir) = &pack.dir else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(dir.join(FONTS_FOLDER)) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| {
                    FONT_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str())
                })
        })
        .collect();
    files.sort();
    files
}

/// `document` with its top-level `name` replaced, leaving every other line and
/// comment as the author wrote it.
fn renamed(document: &str, name: &str) -> String {
    let escaped = name.replace('\\', "\\\\").replace('"', "\\\"");
    let mut done = false;
    let mut in_table = false;
    let mut lines: Vec<String> = Vec::new();
    for line in document.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with('[') {
            in_table = true;
        }
        let is_name = !done
            && !in_table
            && trimmed
                .strip_prefix("name")
                .is_some_and(|rest| rest.trim_start().starts_with('='));
        if is_name {
            lines.push(format!("name = \"{escaped}\""));
            done = true;
        } else {
            lines.push(line.to_string());
        }
    }
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

fn copy_folder(from: &Path, to: &Path) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_folder(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// A folder name no theme in `themes_dir` or among the built-ins has yet.
fn free_folder(themes_dir: &Path, wanted: &str, library: &Library) -> String {
    let mut candidate = wanted.to_string();
    let mut round = 2;
    while library.has(&candidate) || themes_dir.join(&candidate).exists() {
        candidate = format!("{wanted}-{round}");
        round += 1;
    }
    candidate
}

/// Writes a copy of `pack` into the themes folder for the person to change:
/// the same documents under a "My …" name, with a guide to every key beside
/// them. Returns the new theme's id and folder.
pub fn make_editable_copy(
    pack: &Pack,
    themes_dir: &Path,
    library: &Library,
) -> Result<(String, PathBuf), String> {
    let name = format!("My {}", pack.name);
    let base = Some(slug(&name))
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| "my-theme".to_string());
    let id = free_folder(themes_dir, &base, library);
    let folder = themes_dir.join(&id);
    let failed = |error: io::Error| {
        format!(
            "The copy could not be written to {}: {error}.",
            folder.display()
        )
    };

    let document = match (&pack.dir, builtin::source(&pack.id)) {
        (Some(dir), _) => {
            copy_folder(dir, &folder).map_err(failed)?;
            fs::read_to_string(dir.join(DOCUMENT_NAME)).map_err(failed)?
        }
        (None, Some(source)) => {
            fs::create_dir_all(&folder).map_err(failed)?;
            fs::write(
                folder.join(STYLESHEET_NAME),
                stylesheet_for_copy(source.css),
            )
            .map_err(failed)?;
            source.document.to_string()
        }
        (None, None) => return Err(format!("{} has no files to copy.", pack.name)),
    };
    fs::write(folder.join(DOCUMENT_NAME), renamed(&document, &name)).map_err(failed)?;
    fs::write(
        folder.join("README.md"),
        include_str!("../../data/themes/README.md"),
    )
    .map_err(failed)?;
    Ok((id, folder))
}

/// A built-in's stylesheet as it is handed over for editing; one with no rules
/// of its own becomes a short note on what the file is for.
fn stylesheet_for_copy(css: &str) -> String {
    if css.trim().is_empty() {
        "/* Anything written here is applied on top of Flaccy's own look.\n   \
         README.md beside this file lists the classes worth knowing. */\n"
            .to_string()
    } else {
        css.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static SEQUENCE: AtomicU32 = AtomicU32::new(0);

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "flaccy-theme-store-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(dir: &Path, relative: &str, text: &str) {
        let path = dir.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    #[test]
    fn a_missing_themes_folder_still_has_the_builtins() {
        let library = load(Path::new("/nonexistent/flaccy/themes"));
        assert_eq!(library.packs.len(), builtin::SOURCES.len());
        assert!(library.problems.is_empty());
        assert_eq!(library.find("gone").id, builtin::DEFAULT_ID);
        assert_eq!(library.find("phosphor").id, "phosphor");
    }

    #[test]
    fn reads_the_persons_themes_and_names_the_broken_ones() {
        let dir = scratch();
        write(
            &dir,
            "sunny/theme.toml",
            "name = \"Sunny\"\n[layout]\nalbums = \"wall\"",
        );
        write(&dir, "sunny/style.css", ".cover { opacity: 0.9; }");
        write(&dir, "sunny/fonts/Display.TTF", "");
        write(&dir, "sunny/fonts/notes.txt", "");
        write(&dir, "broken/theme.toml", "name = ");
        write(&dir, "empty/readme.txt", "");
        write(&dir, "phosphor/theme.toml", "name = \"Mine\"");
        write(&dir, ".hidden/theme.toml", "name = \"Hidden\"");
        write(&dir, "loose.toml", "name = \"Loose\"");

        let library = load(&dir);
        let sunny = library.find("sunny");
        assert_eq!(sunny.name, "Sunny");
        assert!(!sunny.builtin);
        assert_eq!(sunny.css.as_deref(), Some(".cover { opacity: 0.9; }"));
        assert_eq!(sunny.dir.as_deref(), Some(dir.join("sunny").as_path()));
        assert_eq!(
            font_files(&sunny),
            vec![dir.join("sunny/fonts/Display.TTF")]
        );
        assert_eq!(library.packs.len(), builtin::SOURCES.len() + 1);

        let problems: Vec<(&str, &str)> = library
            .problems
            .iter()
            .map(|problem| (problem.folder.as_str(), problem.reason.as_str()))
            .collect();
        assert_eq!(problems.len(), 3, "{problems:?}");
        assert!(problems[0].0 == "broken" && problems[0].1.contains("not valid TOML"));
        assert!(problems[1].0 == "empty" && problems[1].1.contains("no theme.toml"));
        assert!(problems[2].0 == "phosphor" && problems[2].1.contains("already has a theme"));
        assert!(library.find("phosphor").builtin);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn a_builtin_copies_out_as_a_theme_that_loads_under_a_new_name() {
        let dir = scratch();
        let library = load(&dir);
        let (id, folder) = make_editable_copy(&library.find("phosphor"), &dir, &library).unwrap();
        assert_eq!(id, "my-phosphor");
        assert!(folder.join("README.md").is_file());
        assert!(folder.join(STYLESHEET_NAME).is_file());

        let reloaded = load(&dir);
        let copy = reloaded.find("my-phosphor");
        assert_eq!(copy.name, "My Phosphor");
        assert!(copy.warnings.is_empty(), "{:?}", copy.warnings);
        assert_eq!(copy.schemes, reloaded.find("phosphor").schemes);
        assert_eq!(copy.style, reloaded.find("phosphor").style);

        let (second, _) = make_editable_copy(&reloaded.find("phosphor"), &dir, &reloaded).unwrap();
        assert_eq!(second, "my-phosphor-2");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn a_persons_theme_copies_with_everything_in_its_folder() {
        let dir = scratch();
        write(
            &dir,
            "sunny/theme.toml",
            "# mine\nname = \"Sunny\"\n[[scheme]]\nname = \"Day\"\n",
        );
        write(&dir, "sunny/assets/paper.png", "png");
        let library = load(&dir);
        let (id, folder) = make_editable_copy(&library.find("sunny"), &dir, &library).unwrap();
        assert_eq!(id, "my-sunny");
        assert_eq!(
            fs::read_to_string(folder.join("assets/paper.png")).unwrap(),
            "png"
        );
        let document = fs::read_to_string(folder.join(DOCUMENT_NAME)).unwrap();
        assert_eq!(
            document,
            "# mine\nname = \"My Sunny\"\n[[scheme]]\nname = \"Day\"\n"
        );
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn the_guide_teaches_a_theme_that_reads_clean() {
        let guide = include_str!("../../data/themes/README.md");
        let document: String = guide
            .split("```toml\n")
            .skip(1)
            .filter_map(|rest| rest.split("```").next())
            .collect::<Vec<_>>()
            .join("\n");
        let pack = parse("guide", &document).unwrap();
        assert_eq!(pack.warnings, Vec::<String>::new());
        assert_eq!(pack.schemes.len(), 2);
        assert_eq!(pack.variants.len(), 2);
        assert!(pack.style.interface_font.is_some() && pack.style.heading_font.is_some());
        assert!(pack.schemes[1].dark.wash_b.is_some());
    }

    #[test]
    fn renaming_touches_only_the_themes_own_name() {
        let document = "format = 1\nname=\"Old\"\n[[scheme]]\nname = \"Keep\"\n";
        assert_eq!(
            renamed(document, "A \"New\" One"),
            "format = 1\nname = \"A \\\"New\\\" One\"\n[[scheme]]\nname = \"Keep\"\n"
        );
    }
}
