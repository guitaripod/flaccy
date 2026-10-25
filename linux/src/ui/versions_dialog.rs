use crate::app::{ConfirmReplace, ReplaceChoice, ReplacePrompt};
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::track_revision::copy;
use std::cell::RefCell;
use std::rc::Rc;

const KEEP_BOTH: &str = "keep-both";
const REPLACE: &str = "replace";

/// The question an import asks when it holds newer versions of songs the
/// library already has. Replace is the suggested answer; closing the dialog
/// keeps both, which never loses anything.
pub fn confirm_replace(ui: &Rc<Ui>) -> ConfirmReplace {
    let ui = Rc::clone(ui);
    Rc::new(move |prompt, respond| {
        let dialog = adw::AlertDialog::builder()
            .heading(heading(&prompt))
            .body(copy::REPLACE_BODY)
            .close_response(KEEP_BOTH)
            .default_response(REPLACE)
            .build();
        dialog.add_response(KEEP_BOTH, copy::KEEP_BOTH);
        dialog.add_response(REPLACE, copy::REPLACE);
        dialog.set_response_appearance(REPLACE, adw::ResponseAppearance::Suggested);
        let pending = RefCell::new(Some(respond));
        dialog.connect_response(None, move |_, response| {
            let Some(respond) = pending.borrow_mut().take() else {
                return;
            };
            respond(if response == REPLACE {
                ReplaceChoice::Replace
            } else {
                ReplaceChoice::KeepBoth
            });
        });
        dialog.present(Some(&ui.window));
    })
}

fn heading(prompt: &ReplacePrompt) -> String {
    match (&prompt.title, prompt.count) {
        (Some(title), 1) => copy::fill(copy::REPLACE_HEADING_ONE, &[title]),
        _ => copy::fill(copy::REPLACE_HEADING_MANY, &[&prompt.count.to_string()]),
    }
}
