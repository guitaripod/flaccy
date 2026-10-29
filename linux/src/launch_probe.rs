//! Whether Home may draw its first frame before the first library load
//! returns. Launch asks the database whether any song is indexed, one row and
//! no load, so a person with thousands of songs never sees the get-started
//! state flash past while they are read. The Linux counterpart of the Apple
//! clients' `LibraryStartupProbe` and `Library.isRestoringIndexedLibrary`.

/// What Home does with its first frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HomeGate {
    Wait,
    Render,
}

/// Home holds its first frame only while a library is known to be coming and
/// the first load has not come back. A person with no earlier library sees the
/// get-started state at once, and after the first load nothing is held again.
pub fn home_gate(had_indexed: bool, settled: bool) -> HomeGate {
    if had_indexed && !settled {
        HomeGate::Wait
    } else {
        HomeGate::Render
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_known_library_waits_for_its_first_load() {
        assert_eq!(home_gate(true, false), HomeGate::Wait);
    }

    #[test]
    fn a_settled_first_load_releases_the_page() {
        assert_eq!(home_gate(true, true), HomeGate::Render);
    }

    #[test]
    fn a_new_person_is_never_held() {
        assert_eq!(home_gate(false, false), HomeGate::Render);
        assert_eq!(home_gate(false, true), HomeGate::Render);
    }
}
