//! The equalizer as the rest of the app sees it: the saved state, the output it
//! is following, and the element that puts the curve into the audio.
//!
//! Mirrors `Features/Equalizer/EqualizerEngine.swift`. Every change is published as a new
//! immutable config; the element's kernel ramps to it, so nothing clicks. A
//! screen that wants the live spectrum asks for analysis, which keeps the
//! element processing (passing audio through) while the screen is open.

use super::element::FlaccyEq;
use super::output::{self, Output};
use super::store::{self, EqualizerStore};
use super::{EqConfig, EqShared};
use crate::events::{AppEvent, EventHub};
use flaccy_shared::equalizer::graphic::GraphicSolver;
use flaccy_shared::equalizer::presets::EqualizerPresets;
use flaccy_shared::equalizer::profile::{new_id, EqualizerBand, EqualizerKind, EqualizerProfile};
use flaccy_shared::equalizer::profile_text::EqualizerProfileText;
use flaccy_shared::equalizer::spectrum::SpectrumAnalyzer;
use flaccy_shared::equalizer::state::EqualizerState;
use gst::prelude::*;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

/// The name an edited built-in profile is copied under.
const CUSTOM_PROFILE_NAME: &str = "Custom";
/// The meter and the spectrum read nothing once the element has been silent this long.
const STALE_AFTER_MILLISECONDS: f64 = 1_000.0;

/// A profile's name without the "(Simple)" or "(Advanced)" a conversion added,
/// however many times it was converted, so a copy of a copy keeps one suffix.
fn base_profile_name(name: &str) -> String {
    let mut base = name.trim();
    loop {
        let stripped = [" (Simple)", " (Advanced)"].iter().find_map(|suffix| base.strip_suffix(suffix));
        match stripped {
            Some(rest) if !rest.trim().is_empty() => base = rest.trim_end(),
            _ => return base.to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ImportOutcome {
    Imported {
        profile: EqualizerProfile,
        dropped_filters: usize,
    },
    Unreadable,
}

/// How loud the output is and whether the guard is acting.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Meter {
    pub peak: f32,
    pub guard_reduced: bool,
}

/// An output that keeps a profile, with the name it was last seen under.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RememberedOutput {
    pub id: String,
    pub name: String,
    pub binding: String,
}

pub struct EqEngine {
    hub: Rc<EventHub>,
    shared: Arc<EqShared>,
    element: FlaccyEq,
    store: EqualizerStore,
    state: RefCell<EqualizerState>,
    output: RefCell<Option<Output>>,
    output_reported: Cell<bool>,
    comparing: Cell<bool>,
    audition: RefCell<Option<EqualizerProfile>>,
    analysis_demand: Cell<usize>,
    version: Cell<u64>,
    analyzer: RefCell<Option<(f64, SpectrumAnalyzer)>>,
    scratch: RefCell<Vec<f32>>,
}

impl EqEngine {
    pub fn new(hub: Rc<EventHub>) -> Rc<Self> {
        super::register();
        let shared = EqShared::new();
        let element = FlaccyEq::with_shared(Arc::clone(&shared));
        let store = EqualizerStore::new(store::default_path());
        let state = store.load();
        let engine = Rc::new(Self {
            hub,
            shared,
            element,
            store,
            state: RefCell::new(state),
            output: RefCell::new(None),
            output_reported: Cell::new(false),
            comparing: Cell::new(false),
            audition: RefCell::new(None),
            analysis_demand: Cell::new(0),
            version: Cell::new(0),
            analyzer: RefCell::new(None),
            scratch: RefCell::new(vec![0.0; SpectrumAnalyzer::WINDOW_SIZE]),
        });
        engine.publish("launch");
        engine
    }

    /// Starts following the default audio sink. Called once at launch.
    pub fn start(self: &Rc<Self>) {
        let receiver = output::watch();
        let engine = Rc::downgrade(self);
        gst::glib::spawn_future_local(async move {
            while let Ok(output) = receiver.recv().await {
                let Some(engine) = engine.upgrade() else {
                    return;
                };
                engine.output_arrived(output);
            }
        });
    }

    pub fn element(&self) -> gst::Element {
        self.element.clone().upcast()
    }

    pub fn shared(&self) -> &Arc<EqShared> {
        &self.shared
    }

    pub fn state(&self) -> EqualizerState {
        self.state.borrow().clone()
    }

    pub fn output(&self) -> Option<Output> {
        self.output.borrow().clone()
    }

    pub fn output_id(&self) -> Option<String> {
        self.output.borrow().as_ref().map(|output| output.id.clone())
    }

    /// The profile the screens edit and draw, whether or not it is running.
    pub fn profile_in_force(&self) -> EqualizerProfile {
        self.state.borrow().profile_in_force(self.output_id().as_deref())
    }

    /// The profile actually shaping the sound, or `None` when audio passes untouched.
    pub fn running_profile(&self) -> Option<EqualizerProfile> {
        self.state.borrow().effective_profile(self.output_id().as_deref())
    }

    pub fn is_running(&self) -> bool {
        self.running_profile().is_some()
    }

    pub fn keeps_own_profile_for_output(&self) -> bool {
        self.state.borrow().keeps_own_profile(self.output_id().as_deref())
    }

    pub fn is_output_bound_to_off(&self) -> bool {
        let id = self.output_id();
        id.and_then(|id| self.state.borrow().output_bindings.get(&id).cloned())
            .is_some_and(|binding| binding == EqualizerState::OFF_BINDING)
    }

    pub fn all_profiles(&self) -> Vec<EqualizerProfile> {
        let mut profiles = EqualizerPresets::all();
        profiles.extend(self.state.borrow().user_profiles.iter().cloned());
        profiles
    }

    pub fn is_comparing(&self) -> bool {
        self.comparing.get()
    }

    pub fn set_enabled(&self, enabled: bool) {
        if self.state.borrow().is_enabled == enabled {
            return;
        }
        self.state.borrow_mut().is_enabled = enabled;
        self.commit(&format!("enabled {enabled}"));
    }

    pub fn set_peak_guard(&self, on: bool) {
        self.state.borrow_mut().is_peak_guard_on = on;
        self.commit(&format!("peak guard {on}"));
    }

    /// Chooses a profile and turns the equalizer on, since choosing a preset is asking to hear it.
    pub fn select(&self, profile_id: &str) {
        let output = self.output_id();
        {
            let mut state = self.state.borrow_mut();
            state.select(profile_id, output.as_deref());
            state.is_enabled = true;
        }
        self.commit(&format!("select {profile_id}"));
    }

    /// Applies an edit to the profile in force. A built-in profile is copied
    /// first, so presets stay put.
    pub fn edit(&self, transform: impl FnOnce(&mut EqualizerProfile)) -> EqualizerProfile {
        let output = self.output_id();
        let edited = {
            let mut state = self.state.borrow_mut();
            let edited = state.edit(output.as_deref(), CUSTOM_PROFILE_NAME, transform);
            state.is_enabled = true;
            edited
        };
        self.commit(&format!("edit {}", edited.id));
        edited
    }

    pub fn set_remembering(&self, remember: bool) {
        let Some(output) = self.output_id() else {
            return;
        };
        self.state.borrow_mut().set_remembering(remember, &output);
        self.commit(&format!("remember {remember}"));
    }

    pub fn bind_output_to_off(&self, id: Option<&str>) {
        let Some(target) = id.map(str::to_string).or_else(|| self.output_id()) else {
            return;
        };
        self.state.borrow_mut().bind_off(&target);
        self.commit("bind off");
    }

    pub fn set_binding(&self, profile_id: &str, output_id: &str) {
        self.state
            .borrow_mut()
            .output_bindings
            .insert(output_id.to_string(), profile_id.to_string());
        self.commit(&format!("binding {output_id}"));
    }

    /// Makes `profile_id` the default for every output that keeps no profile of its own.
    pub fn set_default_profile(&self, profile_id: &str) {
        self.state.borrow_mut().active_profile_id = profile_id.to_string();
        self.commit(&format!("default {profile_id}"));
    }

    /// Stops an output from keeping a profile of its own.
    pub fn forget_output(&self, id: &str) {
        self.state.borrow_mut().output_bindings.remove(id);
        self.commit(&format!("forget {id}"));
    }

    /// The outputs that keep a profile, current one first, with the names they were last seen under.
    pub fn remembered_outputs(&self) -> Vec<RememberedOutput> {
        let current = self.output_id();
        let state = self.state.borrow();
        let mut remembered: Vec<RememberedOutput> = state
            .output_bindings
            .iter()
            .map(|(id, binding)| RememberedOutput {
                id: id.clone(),
                name: state.output_names.get(id).cloned().unwrap_or_else(|| id.clone()),
                binding: binding.clone(),
            })
            .collect();
        remembered.sort_by(|a, b| {
            let rank = |entry: &RememberedOutput| usize::from(Some(&entry.id) != current.as_ref());
            (rank(a), &a.name).cmp(&(rank(b), &b.name))
        });
        remembered
    }

    /// Copies the profile in force into the other kind, leaving the original
    /// untouched, and makes the copy the one in force. Switching back and forth
    /// lands on the copy already made rather than adding another to the list.
    pub fn convert_in_force(&self, kind: EqualizerKind) -> EqualizerProfile {
        let source = self.profile_in_force();
        if source.kind == kind {
            return source;
        }
        let mut copy = source.clone();
        copy.id = new_id();
        copy.kind = kind;
        let base = base_profile_name(&source.name);
        match kind {
            EqualizerKind::Parametric => {
                copy.bands = source.resolved_bands();
                copy.targets = vec![0.0; GraphicSolver::CENTRES.len()];
                copy.name = format!("{base} (Advanced)");
            }
            EqualizerKind::Graphic => {
                copy.targets = GraphicSolver::targets_approximating(&source.resolved_bands());
                copy.bands = Vec::new();
                copy.name = format!("{base} (Simple)");
            }
        }
        let existing = self.state.borrow().user_profiles.iter().find(|profile| {
            let mut probe = copy.clone();
            probe.id = profile.id.clone();
            **profile == probe
        }).cloned();
        match existing {
            Some(existing) => {
                let output = self.output_id();
                self.state.borrow_mut().select(&existing.id, output.as_deref());
                self.commit("convert");
                existing
            }
            None => {
                self.adopt(copy.clone(), "convert");
                copy
            }
        }
    }

    /// Puts the saved state back exactly as it was, for undo and redo.
    pub fn restore(&self, previous: EqualizerState) {
        *self.state.borrow_mut() = previous;
        self.commit("restore");
    }

    pub fn rename(&self, profile_id: &str, name: &str) {
        {
            let mut state = self.state.borrow_mut();
            let Some(profile) = state.user_profiles.iter_mut().find(|profile| profile.id == profile_id) else {
                return;
            };
            profile.name = name.to_string();
        }
        self.commit("rename");
    }

    pub fn delete(&self, profile_id: &str) {
        self.state.borrow_mut().delete(profile_id);
        self.commit("delete");
    }

    /// Saves the profile in force under a name of the person's choosing and
    /// makes it the one in force.
    pub fn save_in_force_as(&self, name: &str) -> EqualizerProfile {
        let mut copy = self.profile_in_force();
        copy.id = new_id();
        copy.name = name.to_string();
        self.adopt(copy.clone(), "save as");
        copy
    }

    pub fn import_text(&self, text: &str, name: &str, use_it: bool) -> ImportOutcome {
        let Some(parsed) = EqualizerProfileText::parse(text, name) else {
            return ImportOutcome::Unreadable;
        };
        let output = self.output_id();
        {
            let mut state = self.state.borrow_mut();
            state.user_profiles.push(parsed.profile.clone());
            if use_it {
                state.select(&parsed.profile.id, output.as_deref());
                state.is_enabled = true;
            }
        }
        self.commit("import");
        ImportOutcome::Imported {
            profile: parsed.profile,
            dropped_filters: parsed.dropped_filters,
        }
    }

    pub fn export_text(&self, profile: &EqualizerProfile) -> String {
        EqualizerProfileText::write(profile)
    }

    /// The profile being previewed, if one is: what the person hears while
    /// the saved state still says something else.
    pub fn auditioning(&self) -> Option<EqualizerProfile> {
        self.audition.borrow().clone()
    }

    /// Lets the person hear `profile` without choosing it. Nothing is saved
    /// and the saved state is not touched; the element ramps to the previewed
    /// curve with its own preamp, so presets are compared at the level they
    /// would really play at, and `end_audition` puts back whatever was there,
    /// bit-perfect passthrough included.
    pub fn begin_audition(&self, profile: EqualizerProfile) {
        *self.audition.borrow_mut() = Some(profile);
        self.publish("audition on");
    }

    pub fn end_audition(&self) {
        if self.audition.borrow_mut().take().is_some() {
            self.publish("audition off");
        }
    }

    pub fn begin_compare(&self) {
        if self.comparing.get() || !self.is_running() {
            return;
        }
        self.comparing.set(true);
        self.publish("compare on");
    }

    pub fn end_compare(&self) {
        if !self.comparing.get() {
            return;
        }
        self.comparing.set(false);
        self.publish("compare off");
    }

    /// Keeps the element processing while a screen draws the live spectrum.
    pub fn begin_analysis(&self) {
        self.analysis_demand.set(self.analysis_demand.get() + 1);
        self.shared.set_analysis_requested(self.analysis_demand.get() > 0);
    }

    pub fn end_analysis(&self) {
        self.analysis_demand.set(self.analysis_demand.get().saturating_sub(1));
        self.shared.set_analysis_requested(self.analysis_demand.get() > 0);
    }

    /// The level of the audio the element is processing right now, or `None`
    /// when nothing has passed through it lately.
    pub fn meter(&self) -> Option<Meter> {
        if !self.is_streaming() {
            return None;
        }
        let (peak, guard_reduced) = self.shared.peak_and_guard();
        Some(Meter { peak, guard_reduced })
    }

    /// The last window of audio as 110 log-spaced decibel bins, or `None` when
    /// the element is not processing (analysis not requested, or nothing playing).
    pub fn spectrum(&self) -> Option<Vec<f32>> {
        if !self.is_streaming() {
            return None;
        }
        let mut scratch = self.scratch.borrow_mut();
        let rate = self.shared.copy_analysis_into(&mut scratch)?;
        let mut analyzer = self.analyzer.borrow_mut();
        if analyzer.as_ref().map(|(known, _)| *known) != Some(rate) {
            *analyzer = Some((rate, SpectrumAnalyzer::new(rate)));
        }
        analyzer.as_mut().map(|(_, analyzer)| analyzer.analyze(&scratch))
    }

    /// Milliseconds since the element last processed a buffer, or `None` if it never has.
    pub fn milliseconds_since_last_render(&self) -> Option<f64> {
        self.shared.milliseconds_since_last_buffer()
    }

    /// Whether the element is currently a true passthrough.
    pub fn is_element_passthrough(&self) -> bool {
        gst_base::prelude::BaseTransformExt::is_passthrough(&self.element)
    }

    fn is_streaming(&self) -> bool {
        self.shared
            .milliseconds_since_last_buffer()
            .is_some_and(|age| age < STALE_AFTER_MILLISECONDS)
    }

    fn adopt(&self, profile: EqualizerProfile, reason: &str) {
        let output = self.output_id();
        {
            let mut state = self.state.borrow_mut();
            state.user_profiles.push(profile.clone());
            state.select(&profile.id, output.as_deref());
        }
        self.commit(reason);
    }

    fn commit(&self, reason: &str) {
        self.store.save(&self.state.borrow());
        self.publish(reason);
        self.hub.emit(&AppEvent::EqualizerChanged);
    }

    fn publish(&self, reason: &str) {
        let running = self.auditioning().or_else(|| self.running_profile());
        let mut bands: Vec<EqualizerBand> = Vec::new();
        let mut preamp = 0.0;
        if let Some(running) = &running {
            let resolved = running.resolved_bands();
            preamp = running.preamp_for(&resolved);
            if !self.comparing.get() {
                bands = resolved;
            }
        }
        let version = self.version.get() + 1;
        self.version.set(version);
        let band_count = bands.len();
        self.shared.publish(EqConfig {
            version,
            is_engaged: running.is_some(),
            bands,
            preamp_db: preamp,
            peak_guard: self.state.borrow().is_peak_guard_on,
        });
        if reason.starts_with("edit") || reason.starts_with("audition") {
            return;
        }
        crate::logger::info(
            "playback",
            &format!(
                "equalizer config v{version} ({reason}): engaged={} profile={} bands={band_count} preamp={preamp:.1} dB output={}",
                running.is_some(),
                running.as_ref().map_or("none", |profile| profile.name.as_str()),
                self.output_id().as_deref().unwrap_or("none"),
            ),
        );
    }

    fn output_arrived(&self, output: Option<Output>) {
        if self.output_reported.replace(true) {
            self.output_changed(output);
        } else {
            *self.output.borrow_mut() = output.clone();
            self.remember_name(output.as_ref());
            self.publish(&format!("output {}", output.as_ref().map_or("none", |o| o.id.as_str())));
            self.hub.emit(&AppEvent::EqualizerChanged);
        }
    }

    fn output_changed(&self, new_output: Option<Output>) {
        *self.output.borrow_mut() = new_output.clone();
        self.remember_name(new_output.as_ref());
        let id = new_output.as_ref().map(|output| output.id.clone());
        self.publish(&format!("output {}", id.as_deref().unwrap_or("none")));
        let profile_name = {
            let state = self.state.borrow();
            state
                .keeps_own_profile(id.as_deref())
                .then(|| state.profile_in_force(id.as_deref()).name)
        };
        if let Some(output) = &new_output {
            self.hub.emit(&AppEvent::EqualizerOutputChanged {
                output_name: output.name.clone(),
                profile_name,
            });
        }
        self.hub.emit(&AppEvent::EqualizerChanged);
    }

    fn remember_name(&self, output: Option<&Output>) {
        let Some(output) = output else {
            return;
        };
        let mut state = self.state.borrow_mut();
        if state.output_names.get(&output.id) == Some(&output.name) {
            return;
        }
        state.output_names.insert(output.id.clone(), output.name.clone());
        self.store.save(&state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversion_suffixes_collapse_to_the_name_they_started_from() {
        assert_eq!(base_profile_name("Flat"), "Flat");
        assert_eq!(base_profile_name("Flat (Advanced)"), "Flat");
        assert_eq!(base_profile_name("Flat (Advanced) (Simple) (Advanced)"), "Flat");
        assert_eq!(base_profile_name("Warm Detail (Simple)"), "Warm Detail");
    }

    #[test]
    fn a_name_that_is_only_a_suffix_is_left_alone() {
        assert_eq!(base_profile_name("(Advanced)"), "(Advanced)");
    }
}
