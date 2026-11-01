use crate::ui::frame_look::Crop;
use gtk::gdk;
use gtk::glib;
use gtk::graphene;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use std::cell::{Cell, RefCell};

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct VideoSurface {
        pub paintable: RefCell<Option<(gdk::Paintable, Vec<glib::SignalHandlerId>)>>,
        pub crop: Cell<Crop>,
        pub on_shape: RefCell<Option<Box<dyn Fn()>>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for VideoSurface {
        const NAME: &'static str = "FlaccyVideoSurface";
        type Type = super::VideoSurface;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for VideoSurface {
        fn dispose(&self) {
            self.obj().set_paintable(None);
        }
    }

    impl WidgetImpl for VideoSurface {
        fn measure(&self, _orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            (0, 0, -1, -1)
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let obj = self.obj();
            let (width, height) = (obj.width() as f64, obj.height() as f64);
            let paintable = self.paintable.borrow();
            let Some((paintable, _)) = paintable.as_ref() else {
                return;
            };
            if width <= 0.0 || height <= 0.0 || paintable.intrinsic_width() <= 0 {
                return;
            }
            let crop = self.crop.get();
            if crop.is_none() {
                paintable.snapshot(snapshot, width, height);
                return;
            }
            let (kept_width, kept_height) = crop.kept();
            let (full_width, full_height) = (width / kept_width, height / kept_height);
            snapshot.push_clip(&graphene::Rect::new(0.0, 0.0, width as f32, height as f32));
            snapshot.translate(&graphene::Point::new(
                (-crop.left * full_width) as f32,
                (-crop.top * full_height) as f32,
            ));
            paintable.snapshot(snapshot, full_width, full_height);
            snapshot.pop();
        }
    }
}

glib::wrapper! {
    /// The music video's picture with the black bars burnt into the upload
    /// trimmed away. Its size is decided by the stage; it only draws.
    pub struct VideoSurface(ObjectSubclass<imp::VideoSurface>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for VideoSurface {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl VideoSurface {
    pub fn set_paintable(&self, paintable: Option<&gdk::Paintable>) {
        let imp = self.imp();
        if imp.paintable.borrow().as_ref().map(|(current, _)| current) == paintable {
            return;
        }
        if let Some((old, handlers)) = imp.paintable.borrow_mut().take() {
            for handler in handlers {
                old.disconnect(handler);
            }
        }
        if let Some(paintable) = paintable {
            let weak = self.downgrade();
            let contents = paintable.connect_invalidate_contents(move |_| {
                if let Some(surface) = weak.upgrade() {
                    surface.queue_draw();
                }
            });
            let weak = self.downgrade();
            let size = paintable.connect_invalidate_size(move |_| {
                if let Some(surface) = weak.upgrade() {
                    surface.shape_changed();
                }
            });
            *imp.paintable.borrow_mut() = Some((paintable.clone(), vec![contents, size]));
        }
        self.shape_changed();
    }

    pub fn paintable(&self) -> Option<gdk::Paintable> {
        self.imp()
            .paintable
            .borrow()
            .as_ref()
            .map(|(paintable, _)| paintable.clone())
    }

    pub fn set_crop(&self, crop: Crop) {
        if self.imp().crop.replace(crop) != crop {
            self.shape_changed();
        }
    }

    /// Whether a frame has arrived to draw.
    pub fn has_frame(&self) -> bool {
        self.paintable()
            .is_some_and(|paintable| paintable.intrinsic_width() > 0)
    }

    /// The shape of the picture once its bars are trimmed, or `None` before
    /// the first frame.
    pub fn aspect(&self) -> Option<f64> {
        let paintable = self.paintable()?;
        let aspect = paintable.intrinsic_aspect_ratio();
        (aspect > 0.0).then(|| self.imp().crop.get().aspect(aspect))
    }

    /// Runs `f` whenever the picture's shape changes: a new stream, a new
    /// frame size, or a new crop.
    pub fn connect_shape(&self, f: impl Fn() + 'static) {
        *self.imp().on_shape.borrow_mut() = Some(Box::new(f));
    }

    fn shape_changed(&self) {
        self.queue_draw();
        if let Some(f) = self.imp().on_shape.borrow().as_ref() {
            f();
        }
    }
}
