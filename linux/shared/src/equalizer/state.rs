//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/EqualizerState.swift`.
//!
//! Everything the equalizer remembers between launches: the master switch, the
//! profile used by default, the person's own profiles, and which output keeps
//! which profile. Pure value logic so the Apple clients and Linux decide the same
//! way. The JSON keys match Swift's Codable output, including `activeProfileID`.

use super::presets::EqualizerPresets;
use super::profile::{new_id, EqualizerKind, EqualizerProfile};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EqualizerState {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    #[serde(default = "default_is_enabled")]
    pub is_enabled: bool,
    #[serde(rename = "activeProfileID", default = "default_active_profile_id")]
    pub active_profile_id: String,
    #[serde(default = "default_is_peak_guard_on")]
    pub is_peak_guard_on: bool,
    #[serde(default = "default_user_profiles")]
    pub user_profiles: Vec<EqualizerProfile>,
    #[serde(default = "default_output_bindings")]
    pub output_bindings: HashMap<String, String>,
    #[serde(default = "default_output_names")]
    pub output_names: HashMap<String, String>,
}

/// The lenient decoder's defaults mirror `EqualizerState.init(from:)`, so a
/// document missing any key still loads the way the Apple clients load it.
fn default_schema_version() -> u32 {
    EqualizerState::SCHEMA_VERSION
}

fn default_is_enabled() -> bool {
    false
}

fn default_active_profile_id() -> String {
    EqualizerProfile::FLAT_ID.to_string()
}

fn default_is_peak_guard_on() -> bool {
    true
}

fn default_user_profiles() -> Vec<EqualizerProfile> {
    Vec::new()
}

fn default_output_bindings() -> HashMap<String, String> {
    HashMap::new()
}

fn default_output_names() -> HashMap<String, String> {
    HashMap::new()
}

impl EqualizerState {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const OFF_BINDING: &'static str = "off";

    /// The profile with `id`, whether built in or the person's own.
    pub fn profile_with_id(&self, id: &str) -> Option<EqualizerProfile> {
        EqualizerPresets::profile_for_id(id).or_else(|| {
            self.user_profiles
                .iter()
                .find(|profile| profile.id == id)
                .cloned()
        })
    }

    /// The profile in force for `output`: the output's own when it keeps one,
    /// otherwise the default. Never missing, because an unknown id falls back to
    /// Flat.
    pub fn profile_in_force(&self, output: Option<&str>) -> EqualizerProfile {
        let id = self
            .bound_profile_id(output)
            .unwrap_or(self.active_profile_id.as_str());
        self.profile_with_id(id)
            .unwrap_or_else(EqualizerPresets::flat)
    }

    /// The stage to run for `output`, or `None` when audio should pass untouched:
    /// the master switch is off, the output is bound to Off, or the profile is flat.
    pub fn effective_profile(&self, output: Option<&str>) -> Option<EqualizerProfile> {
        if !self.is_enabled {
            return None;
        }
        if self.bound_profile_id(output) == Some(Self::OFF_BINDING) {
            return None;
        }
        let profile = self.profile_in_force(output);
        if profile.is_flat() {
            None
        } else {
            Some(profile)
        }
    }

    /// True when the output has a binding of its own, including a binding to Off.
    pub fn keeps_own_profile(&self, output: Option<&str>) -> bool {
        self.bound_profile_id(output).is_some()
    }

    /// Chooses `profile_id` for `output`: the output's own binding when it has one,
    /// the default otherwise.
    pub fn select(&mut self, profile_id: &str, output: Option<&str>) {
        match output {
            Some(output) if self.keeps_own_profile(Some(output)) => {
                self.output_bindings
                    .insert(output.to_string(), profile_id.to_string());
            }
            _ => self.active_profile_id = profile_id.to_string(),
        }
    }

    /// Makes the output remember the profile now in force, or forget it.
    pub fn set_remembering(&mut self, remember: bool, output: &str) {
        if remember {
            let id = self.profile_in_force(Some(output)).id;
            self.output_bindings.insert(output.to_string(), id);
        } else {
            self.output_bindings.remove(output);
        }
    }

    pub fn bind_off(&mut self, output: &str) {
        self.output_bindings
            .insert(output.to_string(), Self::OFF_BINDING.to_string());
    }

    /// Applies an edit to the profile in force. A built-in profile is never changed
    /// in place: the edit lands in a copy called `copy_name`, which becomes the
    /// profile in force. Returns the profile that now holds the edit.
    pub fn edit(
        &mut self,
        output: Option<&str>,
        copy_name: &str,
        transform: impl FnOnce(&mut EqualizerProfile),
    ) -> EqualizerProfile {
        let mut profile = self.profile_in_force(output);
        if profile.is_built_in() {
            let mut copy = EqualizerProfile {
                id: new_id(),
                name: copy_name.to_string(),
                kind: profile.kind,
                targets: profile.targets.clone(),
                bands: if profile.kind == EqualizerKind::Graphic {
                    Vec::new()
                } else {
                    profile.bands.clone()
                },
                is_auto_preamp: profile.is_auto_preamp,
                manual_preamp: profile.manual_preamp,
            };
            transform(&mut copy);
            self.user_profiles.push(copy.clone());
            profile = copy;
        } else {
            transform(&mut profile);
            match self
                .user_profiles
                .iter()
                .position(|existing| existing.id == profile.id)
            {
                Some(index) => self.user_profiles[index] = profile.clone(),
                None => self.user_profiles.push(profile.clone()),
            }
        }
        self.select(&profile.id, output);
        profile
    }

    /// Removes a user profile and every binding or default that pointed at it.
    pub fn delete(&mut self, profile_id: &str) {
        self.user_profiles.retain(|profile| profile.id != profile_id);
        if self.active_profile_id == profile_id {
            self.active_profile_id = EqualizerProfile::FLAT_ID.to_string();
        }
        for bound in self.output_bindings.values_mut() {
            if bound.as_str() == profile_id {
                *bound = EqualizerProfile::FLAT_ID.to_string();
            }
        }
    }

    fn bound_profile_id(&self, output: Option<&str>) -> Option<&str> {
        output
            .and_then(|output| self.output_bindings.get(output))
            .map(String::as_str)
    }
}

impl Default for EqualizerState {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            is_enabled: false,
            active_profile_id: EqualizerProfile::FLAT_ID.to_string(),
            is_peak_guard_on: true,
            user_profiles: Vec::new(),
            output_bindings: HashMap::new(),
            output_names: HashMap::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::equalizer::biquad::FilterType;
    use crate::equalizer::profile::EqualizerBand;

    fn enabled_with(active: &str) -> EqualizerState {
        EqualizerState {
            is_enabled: true,
            active_profile_id: active.to_string(),
            ..EqualizerState::default()
        }
    }

    #[test]
    fn a_fresh_state_runs_no_stage() {
        let state = EqualizerState::default();

        assert!(state.effective_profile(Some("speakers")).is_none());
        assert_eq!(
            state.profile_in_force(Some("speakers")).id,
            EqualizerProfile::FLAT_ID
        );
    }

    #[test]
    fn the_master_switch_overrides_everything() {
        let mut state = EqualizerState {
            active_profile_id: EqualizerPresets::id_for_key("rock"),
            ..EqualizerState::default()
        };
        state
            .output_bindings
            .insert("pods".to_string(), EqualizerPresets::id_for_key("jazz"));

        assert!(state.effective_profile(Some("pods")).is_none());
        assert!(state.effective_profile(None).is_none());
    }

    #[test]
    fn an_output_uses_its_own_profile_and_others_use_the_default() {
        let mut state = enabled_with(&EqualizerPresets::id_for_key("rock"));
        state
            .output_bindings
            .insert("pods".to_string(), EqualizerPresets::id_for_key("jazz"));

        assert_eq!(state.effective_profile(Some("pods")).unwrap().name, "Jazz");
        assert_eq!(state.effective_profile(Some("speakers")).unwrap().name, "Rock");
        assert_eq!(state.effective_profile(None).unwrap().name, "Rock");
    }

    #[test]
    fn an_output_bound_to_off_passes_audio_untouched() {
        let mut state = enabled_with(&EqualizerPresets::id_for_key("rock"));
        state.bind_off("dac");

        assert!(state.effective_profile(Some("dac")).is_none());
        assert!(state.effective_profile(Some("speakers")).is_some());
        assert!(state.keeps_own_profile(Some("dac")));
    }

    #[test]
    fn a_flat_profile_runs_no_stage() {
        let state = enabled_with(EqualizerProfile::FLAT_ID);

        assert!(state.effective_profile(Some("speakers")).is_none());
    }

    #[test]
    fn selecting_changes_the_default_unless_the_output_remembers_its_own() {
        let mut state = enabled_with(EqualizerProfile::FLAT_ID);

        state.select(&EqualizerPresets::id_for_key("pop"), Some("speakers"));
        assert_eq!(state.active_profile_id, EqualizerPresets::id_for_key("pop"));
        assert!(state.output_bindings.is_empty());

        state.set_remembering(true, "pods");
        state.select(&EqualizerPresets::id_for_key("jazz"), Some("pods"));
        assert_eq!(
            state.output_bindings.get("pods"),
            Some(&EqualizerPresets::id_for_key("jazz"))
        );
        assert_eq!(state.active_profile_id, EqualizerPresets::id_for_key("pop"));
    }

    #[test]
    fn remembering_binds_the_profile_now_in_force_and_forgetting_removes_it() {
        let mut state = enabled_with(&EqualizerPresets::id_for_key("rock"));

        state.set_remembering(true, "pods");
        assert_eq!(
            state.output_bindings.get("pods"),
            Some(&EqualizerPresets::id_for_key("rock"))
        );

        state.set_remembering(false, "pods");
        assert!(state.output_bindings.get("pods").is_none());
    }

    #[test]
    fn editing_a_built_in_profile_makes_a_copy_and_leaves_the_original_alone() {
        let mut state = enabled_with(&EqualizerPresets::id_for_key("bassBoost"));

        let edited = state.edit(None, "Custom", |profile| profile.targets[0] = 9.0);

        assert!(!edited.is_built_in());
        assert_eq!(edited.name, "Custom");
        assert_eq!(edited.targets[0], 9.0);
        assert_eq!(state.active_profile_id, edited.id);
        assert_eq!(state.user_profiles.len(), 1);
        assert_eq!(EqualizerPresets::profile_for_key("bassBoost").unwrap().targets[0], 6.0);
    }

    #[test]
    fn editing_a_user_profile_changes_it_in_place() {
        let mut state = enabled_with(EqualizerProfile::FLAT_ID);
        let first = state.edit(None, "Custom", |profile| profile.targets[2] = 3.0);

        let second = state.edit(None, "Custom", |profile| profile.targets[2] = 5.0);

        assert_eq!(second.id, first.id);
        assert_eq!(state.user_profiles.len(), 1);
        assert_eq!(state.user_profiles[0].targets[2], 5.0);
    }

    #[test]
    fn editing_an_outputs_remembered_profile_keeps_the_binding() {
        let mut state = enabled_with(&EqualizerPresets::id_for_key("rock"));
        state.set_remembering(true, "pods");

        let edited = state.edit(Some("pods"), "Custom", |profile| profile.targets[1] = 7.0);

        assert_eq!(state.output_bindings.get("pods"), Some(&edited.id));
        assert_eq!(state.active_profile_id, EqualizerPresets::id_for_key("rock"));
    }

    #[test]
    fn deleting_a_profile_sends_its_users_back_to_flat() {
        let mut state = enabled_with(EqualizerProfile::FLAT_ID);
        let mine = state.edit(None, "Mine", |profile| profile.targets[0] = 4.0);
        state.output_bindings.insert("pods".to_string(), mine.id.clone());

        state.delete(&mine.id);

        assert!(state.user_profiles.is_empty());
        assert_eq!(state.active_profile_id, EqualizerProfile::FLAT_ID);
        assert_eq!(
            state.output_bindings.get("pods").map(String::as_str),
            Some(EqualizerProfile::FLAT_ID)
        );
    }

    #[test]
    fn the_state_survives_a_json_round_trip() {
        let mut state = enabled_with(&EqualizerPresets::id_for_key("jazz"));
        state.edit(None, "Custom", |profile| profile.targets[4] = -3.0);
        state.bind_off("dac");

        let text = serde_json::to_string(&state).unwrap();
        let decoded: EqualizerState = serde_json::from_str(&text).unwrap();

        assert_eq!(decoded, state);
        assert_eq!(decoded.schema_version, EqualizerState::SCHEMA_VERSION);
    }

    #[test]
    fn the_state_json_uses_the_swift_keys() {
        let state = EqualizerState::default();

        let value: serde_json::Value = serde_json::to_value(&state).unwrap();

        assert_eq!(value["schemaVersion"], 1);
        assert_eq!(value["activeProfileID"], EqualizerProfile::FLAT_ID);
        assert_eq!(value["isPeakGuardOn"], true);
        assert_eq!(value["userProfiles"], serde_json::json!([]));
        assert_eq!(value["outputBindings"], serde_json::json!({}));
    }

    #[test]
    fn json_without_output_names_loads_with_an_empty_map() {
        let text = r#"{"schemaVersion":1,"isEnabled":true,"activeProfileID":"builtin.flat","isPeakGuardOn":true,"userProfiles":[],"outputBindings":{"pods":"builtin.flat"}}"#;

        let state: EqualizerState = serde_json::from_str(text).unwrap();

        assert!(state.is_enabled);
        assert!(state.output_names.is_empty());
        assert_eq!(state.output_bindings.get("pods").map(String::as_str), Some(EqualizerProfile::FLAT_ID));
    }

    #[test]
    fn an_empty_object_loads_as_the_default_state() {
        let state: EqualizerState = serde_json::from_str("{}").unwrap();

        assert_eq!(state, EqualizerState::default());
        assert!(!state.is_enabled);
        assert!(state.is_peak_guard_on);
    }

    #[test]
    fn output_names_survive_a_json_round_trip() {
        let mut state = enabled_with(EqualizerProfile::FLAT_ID);
        state.bind_off("dac");
        state
            .output_names
            .insert("dac".to_string(), "USB DAC".to_string());

        let text = serde_json::to_string(&state).unwrap();
        let decoded: EqualizerState = serde_json::from_str(&text).unwrap();

        assert_eq!(decoded, state);
        assert_eq!(decoded.output_names.get("dac").map(String::as_str), Some("USB DAC"));
        let value: serde_json::Value = serde_json::to_value(&state).unwrap();
        assert_eq!(value["outputNames"]["dac"], "USB DAC");
    }

    #[test]
    fn a_band_inside_a_profile_is_encoded_with_its_type_key() {
        let mut state = EqualizerState::default();
        state.user_profiles.push(EqualizerProfile::parametric(
            "test.warm",
            "Warm",
            vec![EqualizerBand::new(FilterType::HighPass, 28.0, 0.0, None, true)],
        ));

        let value: serde_json::Value = serde_json::to_value(&state).unwrap();

        assert_eq!(value["userProfiles"][0]["bands"][0]["type"], "highPass");
    }
}
