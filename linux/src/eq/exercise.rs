//! Plays two generated FLAC files through the real player with the equalizer
//! engaged and logs PASS/FAIL per expectation (`FLACCY_DEMO_EQ=1`): the element
//! runs on FLAC at both rates, a +9 dB bell lifts a 220 Hz tone by 9 dB,
//! Compare removes it, the gapless hand-off arrives on time and costs no more
//! than the same hand-off with the equalizer off, and the element returns to
//! true passthrough when the equalizer is switched off. `FLACCY_DEMO_EQ=scrub` plays
//! the same files with the equalizer engaged and runs the scrub drill on them.
//!
//! Put `eqtest-a.flac` (44.1 kHz, 16 bit, a 220 Hz tone) and `eqtest-b.flac`
//! (96 kHz, 24 bit, a 1 kHz tone) in `~/eqtest` and read the app log afterwards.

use super::EqEngine;
use crate::app::AppCore;
use crate::library::Track;
use flaccy_shared::equalizer::biquad::FilterType;
use flaccy_shared::equalizer::profile::{EqualizerBand, EqualizerKind, EqualizerProfile};
use gst::glib;
use gtk::gio::prelude::ApplicationExt;
use std::rc::Rc;
use std::time::Duration;

const LEVEL_TOLERANCE_DECIBELS: f32 = 1.5;
const BOUNDARY_ALLOWANCE_MILLISECONDS: f64 = 40.0;
const STEADY_GAP_LIMIT_MILLISECONDS: f64 = 400.0;
const TRACK_SECONDS: f64 = 40.0;

pub fn run(core: &Rc<AppCore>, mode: &str) {
    let core = Rc::clone(core);
    let mode = mode.to_string();
    glib::spawn_future_local(async move {
        match mode.as_str() {
            "scrub" => scrub_drill(&core).await,
            _ => full_exercise(&core).await,
        }
    });
}

fn report(expectation: &str, passed: bool) {
    crate::logger::info(
        "equalizer",
        &format!("EqualizerExercise {}: {expectation}", if passed { "PASS" } else { "FAIL" }),
    );
}

async fn sleep(milliseconds: u64) {
    glib::timeout_future(Duration::from_millis(milliseconds)).await;
}

async fn wait_until(seconds: f64, condition: impl Fn() -> bool) -> bool {
    let mut remaining = (seconds * 1000.0) as i64;
    while remaining > 0 {
        if condition() {
            return true;
        }
        sleep(50).await;
        remaining -= 50;
    }
    condition()
}

fn track(file: &str, title: &str) -> Track {
    Track {
        id: 0,
        rel_path: file.to_string(),
        title: title.to_string(),
        artist: "Equalizer Exercise".to_string(),
        album: "Test Tones".to_string(),
        album_artist: None,
        track_number: 1,
        duration: TRACK_SECONDS,
        codec: None,
        bit_depth: None,
        sample_rate: None,
        channels: None,
        loved: false,
        play_count: 0,
        date_added: 0,
        last_played: None,
        revision: 1,
        revised_at: None,
        file_modified_ms: None,
    }
}

fn start_playback(core: &Rc<AppCore>) -> bool {
    let folder = dirs::home_dir().unwrap_or_default().join("eqtest");
    if !folder.join("eqtest-a.flac").exists() || !folder.join("eqtest-b.flac").exists() {
        report(&format!("test files present in {}", folder.display()), false);
        return false;
    }
    core.player.set_root(folder);
    core.player.play_queue(
        vec![track("eqtest-a.flac", "Tone A"), track("eqtest-b.flac", "Tone B")],
        0,
    );
    true
}

fn bell(frequency: f64) -> impl FnOnce(&mut EqualizerProfile) {
    move |profile| {
        profile.kind = EqualizerKind::Parametric;
        profile.bands = vec![EqualizerBand::new(FilterType::Bell, frequency, 9.0, Some(1.0), true)];
        profile.is_auto_preamp = false;
        profile.manual_preamp = 0.0;
    }
}

async fn settled_peak(eq: &EqEngine) -> f32 {
    sleep(1200).await;
    let mut loudest = -96.0f32;
    for _ in 0..5 {
        if let Some(bins) = eq.spectrum() {
            loudest = loudest.max(bins.iter().copied().fold(-96.0, f32::max));
        }
        sleep(120).await;
    }
    loudest
}

async fn is_processing_now(eq: &EqEngine) -> bool {
    let before = eq.shared().frames_processed();
    sleep(600).await;
    eq.shared().frames_processed() > before && !eq.is_element_passthrough()
}

fn finish(core: &Rc<AppCore>) {
    core.player.toggle_play_pause();
    crate::logger::info("equalizer", "EqualizerExercise finished");
    if let Some(application) = gtk::gio::Application::default() {
        application.quit();
    }
}

async fn full_exercise(core: &Rc<AppCore>) {
    let eq = Rc::clone(&core.eq);
    eq.set_enabled(false);
    eq.begin_analysis();
    if !start_playback(core) {
        finish(core);
        return;
    }

    let running = wait_until(10.0, || eq.shared().frames_processed() > 0).await;
    report("the element is processing a 44.1 kHz 16-bit FLAC item with the equalizer off", running);
    if !running {
        finish(core);
        return;
    }
    let format = eq.shared().stream_format();
    report(
        &format!("stream format is {format:?} (expected 44100 Hz, 2 channels)"),
        format == Some((44_100, 2)),
    );

    let dry = settled_peak(&eq).await;
    report(&format!("dry 220 Hz tone reads {dry:.1} dB (expected about -20)"), (dry + 20.0).abs() < 2.5);

    let mut preview = EqualizerProfile::parametric("audition-exercise", "Audition", Vec::new());
    bell(220.0)(&mut preview);
    eq.begin_audition(preview);
    let previewed = settled_peak(&eq).await;
    report(
        &format!("auditioning a +9 dB bell lifts the tone by {:.1} dB while the saved state stays off", previewed - dry),
        ((previewed - dry) - 9.0).abs() < LEVEL_TOLERANCE_DECIBELS && !eq.is_running(),
    );
    eq.end_audition();
    let after_preview = settled_peak(&eq).await;
    report(
        &format!("ending the audition returns the tone to {after_preview:.1} dB and the element to passthrough"),
        (after_preview - dry).abs() < LEVEL_TOLERANCE_DECIBELS && !eq.shared().current().is_engaged,
    );

    eq.edit(bell(220.0));
    let engaged = eq.is_running() && eq.shared().current().is_engaged && is_processing_now(&eq).await;
    report("the element is engaged and processing with a +9 dB bell at 220 Hz", engaged);
    let wet = settled_peak(&eq).await;
    report(
        &format!("a +9 dB bell at 220 Hz moved the tone by {:.1} dB", wet - dry),
        ((wet - dry) - 9.0).abs() < LEVEL_TOLERANCE_DECIBELS,
    );

    eq.begin_compare();
    let compared = settled_peak(&eq).await;
    report(
        &format!("Compare returns the tone to {compared:.1} dB"),
        (compared - dry).abs() < LEVEL_TOLERANCE_DECIBELS,
    );
    eq.end_compare();
    let restored = settled_peak(&eq).await;
    report(
        &format!("releasing Compare brings the boost back to {restored:.1} dB"),
        (restored - wet).abs() < LEVEL_TOLERANCE_DECIBELS,
    );

    eq.edit(|profile| {
        profile.kind = EqualizerKind::Parametric;
        profile.bands = vec![EqualizerBand::new(FilterType::Bell, 220.0, 9.0, Some(1.0), true)];
        profile.is_auto_preamp = true;
    });
    let automatic = settled_peak(&eq).await;
    report(
        &format!("automatic preamp keeps the boosted tone at or below the dry level ({automatic:.1} dB)"),
        automatic <= dry + LEVEL_TOLERANCE_DECIBELS,
    );

    eq.edit(bell(220.0));
    sleep(500).await;
    eq.shared().restart_gap_measure();
    sleep(3000).await;
    let steady = eq.shared().take_largest_gap_milliseconds();
    let steady_lead = eq.shared().least_lead_milliseconds();
    report(
        &format!("steady playback: largest gap between processed buffers {steady:.1} ms"),
        steady < STEADY_GAP_LIMIT_MILLISECONDS,
    );

    let (advanced, boundary, boundary_lead) = cross_boundary(core).await;
    report(
        &format!("gapless boundary: audio never arrived late, least lead {boundary_lead:?} ms (steady playback {steady_lead:?} ms)"),
        boundary_lead.is_some_and(|lead| lead > 0.0),
    );
    crate::logger::info(
        "equalizer",
        &format!("EqualizerExercise INFO: gapless boundary: largest gap between processed buffers {boundary:.1} ms (steady playback {steady:.1} ms; decoding runs about a second ahead of the speaker, so a hand-off pause shows up here long before it could be heard)"),
    );
    report("the queue advanced to the 96 kHz 24-bit track", advanced);

    let format = eq.shared().stream_format();
    report(
        &format!("the element re-negotiated for the next item at {format:?} (expected 96000 Hz, 2 channels)"),
        format == Some((96_000, 2)),
    );
    report("the element is engaged and processing the 96 kHz track", is_processing_now(&eq).await && eq.is_running());

    eq.edit(bell(1000.0));
    let wet_b = settled_peak(&eq).await;
    eq.begin_compare();
    let dry_b = settled_peak(&eq).await;
    eq.end_compare();
    report(
        &format!("at 96 kHz a +9 dB bell at 1 kHz moved the tone by {:.1} dB", wet_b - dry_b),
        ((wet_b - dry_b) - 9.0).abs() < LEVEL_TOLERANCE_DECIBELS,
    );

    core.player.seek(1.0);
    let before = eq.shared().frames_processed();
    let after_seek = wait_until(3.0, || {
        eq.milliseconds_since_last_render().is_some_and(|age| age < 150.0)
            && eq.shared().frames_processed() > before
    })
    .await;
    report("the element keeps processing after a seek", after_seek);

    eq.set_enabled(false);
    eq.end_analysis();
    let passthrough = wait_until(4.0, || eq.is_element_passthrough()).await;
    report("the element returns to passthrough once the equalizer is off", passthrough);

    eq.set_enabled(true);
    eq.begin_analysis();
    report("switching it back on processes again while the song plays", wait_until(4.0, || !eq.is_element_passthrough()).await && is_processing_now(&eq).await);
    eq.end_analysis();

    let unequalized = unequalized_boundary(core).await;
    if let Some((off_gap, off_lead)) = unequalized {
        report(
            &format!("the equalizer adds no gap at the hand-off: {boundary:.1} ms engaged against {off_gap:.1} ms with it off (allowance {BOUNDARY_ALLOWANCE_MILLISECONDS:.0} ms)"),
            boundary <= off_gap + BOUNDARY_ALLOWANCE_MILLISECONDS,
        );
        report(
            &format!("the equalizer does not eat the margin at the hand-off: least lead {boundary_lead:?} ms engaged against {off_lead:?} ms with it off"),
            match (boundary_lead, off_lead) {
                (Some(on), Some(off)) => on >= off - BOUNDARY_ALLOWANCE_MILLISECONDS,
                _ => false,
            },
        );
    } else {
        report("the unequalized hand-off could be measured for comparison", false);
    }

    finish(core);
}

/// Replays the hand-off with the equalizer off, the element only watching, and
/// returns its largest gap and least lead.
async fn unequalized_boundary(core: &Rc<AppCore>) -> Option<(f64, Option<f64>)> {
    let eq = Rc::clone(&core.eq);
    eq.set_enabled(false);
    eq.begin_analysis();
    start_playback(core).then_some(())?;
    wait_until(10.0, || eq.shared().frames_processed() > 0).await;
    sleep(2500).await;
    let (advanced, gap, lead) = cross_boundary(core).await;
    eq.end_analysis();
    advanced.then_some((gap, lead))
}

/// Seeks the first track to three seconds before its end and measures what the
/// element saw until the second track had been playing for a while.
async fn cross_boundary(core: &Rc<AppCore>) -> (bool, f64, Option<f64>) {
    let eq = &core.eq;
    let duration = core.player.duration().unwrap_or(TRACK_SECONDS);
    core.player.seek((duration - 3.0).max(0.0));
    sleep(800).await;
    eq.shared().restart_gap_measure();
    let advanced = wait_until(7.0, || core.player.current_index_and_len().0 == 1).await;
    sleep(1500).await;
    (
        advanced,
        eq.shared().take_largest_gap_milliseconds(),
        eq.shared().least_lead_milliseconds(),
    )
}

async fn scrub_drill(core: &Rc<AppCore>) {
    let eq = Rc::clone(&core.eq);
    eq.edit(bell(220.0));
    if !start_playback(core) {
        finish(core);
        return;
    }
    let playing = wait_until(10.0, || eq.shared().frames_processed() > 0).await;
    report("the element is processing before the scrub drill starts", playing && eq.is_running());
    sleep(1500).await;
    crate::scrub_drill::run(core);
    let before = eq.shared().frames_processed();
    sleep(5000).await;
    report(
        "the element kept processing while the drill ran",
        eq.shared().frames_processed() > before && eq.is_running(),
    );
}
