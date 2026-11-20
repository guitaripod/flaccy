//! Brings every widget in line with the engine: the switch, the curve, the
//! band cells, the preamp rail, the status line, the output button, and the
//! level meters on the frame clock.

use super::copy::{self, Status};
use super::render::{self, Rgb};
use super::{demo, output, Screen};
use crate::eq::output::{Output, OutputKind};
use adw::prelude::*;
use flaccy_shared::equalizer::graphic::GraphicSolver;
use flaccy_shared::equalizer::plot_model::{PlotContent, PlotMode};
use flaccy_shared::equalizer::profile::EqualizerProfile;
use gtk::glib;
use std::rc::Rc;

/// The symbolic icon an output kind is shown with.
pub fn output_icon_name(kind: Option<OutputKind>) -> &'static str {
    match kind {
        Some(OutputKind::Headphones) => "flaccy-headphones-symbolic",
        Some(OutputKind::Bluetooth) => "flaccy-bluetooth-symbolic",
        Some(OutputKind::Usb) => "flaccy-audio-interface-symbolic",
        Some(OutputKind::Display) => "flaccy-video-symbolic",
        Some(OutputKind::Other) => "flaccy-audio-interface-symbolic",
        Some(OutputKind::Speaker) | None => "flaccy-speaker-symbolic",
    }
}

/// Which line the status shows for a state of the equalizer.
pub fn status_for(running: bool, comparing: bool, flat: bool) -> Status {
    if !running {
        Status::Off
    } else if comparing {
        Status::Comparing
    } else if flat {
        Status::Flat
    } else {
        Status::Processing
    }
}

fn status_class(status: Status) -> &'static str {
    match status {
        Status::Off | Status::Flat => "eq-status-lossless",
        Status::Processing => "eq-status-accent",
        Status::Comparing => "eq-status-caution",
    }
}

const STATUS_CLASSES: [&str; 3] = ["eq-status-lossless", "eq-status-accent", "eq-status-caution"];

impl Screen {
    pub(super) fn schedule_refresh(self: &Rc<Self>) {
        if !self.window.is_mapped() || self.refresh_queued.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(screen) = weak.upgrade() {
                screen.refresh_queued.set(false);
                screen.refresh(true);
            }
        });
    }

    pub(super) fn current_output(&self) -> Option<Output> {
        self.demo_output
            .borrow()
            .clone()
            .or_else(|| self.engine.output())
    }

    pub(super) fn clamped_selection(&self, profile: &EqualizerProfile) -> usize {
        let count = match Self::mode_of(profile) {
            PlotMode::Simple => GraphicSolver::CENTRES.len(),
            PlotMode::Advanced => profile.bands.len().max(1),
        };
        let selected = self.selected.get().min(count - 1);
        self.selected.set(selected);
        selected
    }

    pub(super) fn is_running_for_display(&self) -> bool {
        self.engine.state().is_enabled && !self.engine.is_output_bound_to_off()
    }

    fn plot_content(&self, profile: &EqualizerProfile, running: bool) -> PlotContent {
        PlotContent {
            mode: Self::mode_of(profile),
            targets: profile.targets.clone(),
            bands: profile.bands.iter().map(|band| band.clamped()).collect(),
            selected_index: self.clamped_selection(profile),
            is_enabled: running,
            is_comparing: self.engine.is_comparing(),
        }
    }

    /// Pushes the profile in force into the curve at once, so the next pointer
    /// event of a drag works against the numbers the last one set.
    pub(super) fn sync_curve(&self) {
        let profile = self.profile();
        let running = self.is_running_for_display();
        self.curve.update(self.plot_content(&profile, running), false);
    }

    pub(super) fn refresh(&self, animated: bool) {
        self.syncing.set(true);
        let profile = self.profile();
        let running = self.is_running_for_display();
        let mode = Self::mode_of(&profile);

        self.enable_switch.set_active(running);
        self.enable_label.set_text(if running { "On" } else { "Off" });
        self.mode_group.set_active(if mode == PlotMode::Simple { 0 } else { 1 });

        let content = self.plot_content(&profile, running);
        let selected = content.selected_index;
        self.curve.update(content, animated);

        match mode {
            PlotMode::Simple => {
                self.lower.set_visible_child_name("simple");
                self.strip.configure(&profile.targets, selected);
                self.hint_label.set_text(copy::SIMPLE_HINT);
            }
            PlotMode::Advanced => {
                self.lower.set_visible_child_name("advanced");
                let bands: Vec<_> = profile.bands.iter().map(|band| band.clamped()).collect();
                self.table.configure(&bands, selected);
                self.hint_label.set_text(copy::ADVANCED_HINT);
            }
        }

        self.profile_label.set_text(&profile.name);
        self.deck.sync(self, &self.weak);
        self.compare_button.set_label(if self.engine.is_comparing() {
            "Hearing original"
        } else {
            "Hold to compare"
        });
        self.update_output();
        self.update_preamp(&profile);
        self.update_status(&profile, running);
        self.syncing.set(false);
    }

    fn update_output(&self) {
        let output = self.current_output();
        self.output_label
            .set_text(output.as_ref().map_or("Output", |output| output.name.as_str()));
        self.output_icon
            .set_icon_name(Some(output_icon_name(output.as_ref().map(|output| output.kind))));
        let keeps = self.engine.keeps_own_profile_for_output();
        self.output_button.set_tooltip_text(Some(if self.engine.is_output_bound_to_off() {
            "The equalizer is off for this output"
        } else if keeps {
            "This output remembers its own profile"
        } else {
            "Choose the profile for this output"
        }));
        self.remember_action.set_state(&keeps.to_variant());
        self.remember_action.set_enabled(self.engine.output_id().is_some());
        output::rebuild_menu_if_changed(self);
    }

    fn update_preamp(&self, profile: &EqualizerProfile) {
        let preamp = profile.preamp();
        self.preamp_value.set_text(&format!("{} dB", copy::decibels(preamp)));
        if !self.preamp_active.get() {
            self.preamp_scale.set_value(preamp);
        }
        self.auto_button.set_label(if profile.is_auto_preamp { "Auto" } else { "Manual" });
        self.auto_button.set_active(profile.is_auto_preamp);
        self.preamp_scale.update_property(&[gtk::accessible::Property::ValueText(&format!(
            "{} dB",
            copy::decibels(preamp)
        ))]);
    }

    fn update_status(&self, profile: &EqualizerProfile, running: bool) {
        let status = status_for(running, self.engine.is_comparing(), profile.is_flat());
        self.status_label.set_text(copy::status(status));
        for class in STATUS_CLASSES {
            self.status_label.remove_css_class(class);
            self.status_icon.remove_css_class(class);
        }
        self.status_label.add_css_class(status_class(status));
        self.status_icon.add_css_class(status_class(status));
        self.status_icon.set_icon_name(Some(match status {
            Status::Off | Status::Flat => "flaccy-check-circle-symbolic",
            Status::Processing => "flaccy-equalizer-symbolic",
            Status::Comparing => "flaccy-show-symbolic",
        }));
    }

    pub(super) fn update_meter(&self) {
        let meter = if demo::is_active() {
            Some(demo::meter())
        } else {
            self.engine.meter()
        };
        let peak = meter.map_or(0.0, |meter| meter.peak);
        let decibels = render::peak_decibels(peak);
        let color: Rgb = render::meter_color(decibels);
        self.meter_left.set(decibels, color);
        self.meter_right.set(decibels - 0.6, color);
        let text = match meter {
            Some(_) => format!(
                "<span foreground=\"{}\">{decibels:.1} dB</span>",
                render::rgb_css(render::text_tone(color, super::curve::CurveView::is_dark()))
            ),
            None => "\u{2014}".to_string(),
        };
        if *self.last_peak_text.borrow() != text {
            self.peak_label.set_markup(&text);
            *self.last_peak_text.borrow_mut() = text;
        }
        let reduced = meter.is_some_and(|meter| meter.guard_reduced);
        if reduced != self.guard_active.replace(reduced) {
            self.status_label.set_tooltip_text(
                reduced.then_some("Peak guard is catching overs. Lower the preamp or return to Auto."),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_status_follows_the_switch_then_compare_then_flatness() {
        assert_eq!(status_for(false, true, false), Status::Off);
        assert_eq!(status_for(true, true, false), Status::Comparing);
        assert_eq!(status_for(true, false, true), Status::Flat);
        assert_eq!(status_for(true, false, false), Status::Processing);
    }

    #[test]
    fn every_output_kind_has_an_icon() {
        assert_eq!(output_icon_name(None), "flaccy-speaker-symbolic");
        assert_eq!(output_icon_name(Some(OutputKind::Headphones)), "flaccy-headphones-symbolic");
        assert_eq!(output_icon_name(Some(OutputKind::Display)), "flaccy-video-symbolic");
    }
}
