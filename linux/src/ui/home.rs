use crate::ui::Ui;
use gtk::prelude::*;
use std::rc::Rc;

pub fn build(_ui: &Rc<Ui>) -> gtk::Widget {
    gtk::Label::new(Some("Home")).upcast()
}
