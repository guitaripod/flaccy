//! The wash of the hero's colors behind the top of Home. It paints the baked
//! backdrop texture (`ArtworkCache::request_backdrop`, a few dozen texels
//! already blurred off the main thread) as one textured rectangle, faded
//! toward the bottom with a gradient mask. There is no CSS `filter` and no
//! animation: the node is built when the picture or the size changes and the
//! frame clock is not involved.

use gtk::prelude::WidgetExt;
use gtk::subclass::prelude::ObjectSubclassIsExt;
use gtk::{gdk, glib};

mod imp {
    use gtk::prelude::*;
    use gtk::subclass::prelude::*;
    use gtk::{gdk, glib, graphene, gsk};
    use std::cell::RefCell;

    #[derive(Default)]
    pub struct HomeBackdrop {
        pub paintable: RefCell<Option<gdk::Paintable>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for HomeBackdrop {
        const NAME: &'static str = "FlaccyHomeBackdrop";
        type Type = super::HomeBackdrop;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for HomeBackdrop {}

    impl WidgetImpl for HomeBackdrop {
        fn measure(&self, _orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            (0, 0, -1, -1)
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let widget = self.obj();
            let (width, height) = (widget.width() as f32, widget.height() as f32);
            let paintable = self.paintable.borrow();
            let Some(paintable) = paintable.as_ref() else {
                return;
            };
            if width <= 0.0 || height <= 0.0 {
                return;
            }
            let bounds = graphene::Rect::new(0.0, 0.0, width, height);
            snapshot.push_mask(gsk::MaskMode::Alpha);
            snapshot.append_linear_gradient(
                &bounds,
                &graphene::Point::new(0.0, 0.0),
                &graphene::Point::new(0.0, height),
                &[
                    gsk::ColorStop::new(0.0, gdk::RGBA::new(0.0, 0.0, 0.0, 1.0)),
                    gsk::ColorStop::new(0.45, gdk::RGBA::new(0.0, 0.0, 0.0, 0.7)),
                    gsk::ColorStop::new(1.0, gdk::RGBA::new(0.0, 0.0, 0.0, 0.0)),
                ],
            );
            snapshot.pop();
            let intrinsic_w = paintable.intrinsic_width().max(1) as f32;
            let intrinsic_h = paintable.intrinsic_height().max(1) as f32;
            let scale = (width / intrinsic_w).max(height / intrinsic_h);
            let (drawn_w, drawn_h) = (intrinsic_w * scale, intrinsic_h * scale);
            snapshot.push_clip(&bounds);
            snapshot.save();
            snapshot.translate(&graphene::Point::new(
                (width - drawn_w) / 2.0,
                (height - drawn_h) / 2.0,
            ));
            paintable.snapshot(snapshot, drawn_w as f64, drawn_h as f64);
            snapshot.restore();
            snapshot.pop();
            snapshot.pop();
        }
    }
}

glib::wrapper! {
    pub struct HomeBackdrop(ObjectSubclass<imp::HomeBackdrop>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl HomeBackdrop {
    pub fn new() -> Self {
        glib::Object::new()
    }

    pub fn set_paintable(&self, paintable: Option<&gdk::Paintable>) {
        *self.imp().paintable.borrow_mut() = paintable.cloned();
        self.queue_draw();
    }
}
