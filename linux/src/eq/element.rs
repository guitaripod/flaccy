//! `flaccyeq`: a `BaseTransform` that runs the shared equalizer kernel in place.
//!
//! Every format the kernel does not natively speak is converted to float32 on
//! the way in and back, rounded and clipped, on the way out. While the stage is
//! off, fully faded out and nobody watches the spectrum, the element is in true
//! passthrough and buffers cross it untouched.

use super::{EqConfig, EqShared};
use flaccy_shared::equalizer::kernel::{EqualizerKernel, Plane};
use flaccy_shared::equalizer::song_gain;
use flaccy_shared::equalizer::spectrum::SpectrumAnalyzer;
use gst::glib;
use gst::prelude::*;
use gst::subclass::prelude::*;
use gst_audio::AudioFormat;
use gst_base::subclass::prelude::*;
use std::sync::{Arc, LazyLock, Mutex, OnceLock};

glib::wrapper! {
    pub struct FlaccyEq(ObjectSubclass<imp::FlaccyEq>)
        @extends gst_base::BaseTransform, gst::Element, gst::Object;
}

impl FlaccyEq {
    pub fn with_shared(shared: Arc<EqShared>) -> Self {
        let element: Self = glib::Object::new();
        let _ = element.imp().shared.set(shared);
        element
    }

    pub fn shared(&self) -> Arc<EqShared> {
        self.imp().shared()
    }
}

pub fn register() -> Result<(), glib::BoolError> {
    gst::Element::register(None, "flaccyeq", gst::Rank::NONE, FlaccyEq::static_type())
}

/// The sample layouts the element accepts, all interleaved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SampleFormat {
    F32,
    F64,
    S16,
    S32,
    S24In32,
}

impl SampleFormat {
    fn from_audio(format: AudioFormat) -> Option<Self> {
        match format {
            AudioFormat::F32le => Some(Self::F32),
            AudioFormat::F64le => Some(Self::F64),
            AudioFormat::S16le => Some(Self::S16),
            AudioFormat::S32le => Some(Self::S32),
            AudioFormat::S2432le => Some(Self::S24In32),
            _ => None,
        }
    }

    fn bytes(self) -> usize {
        match self {
            Self::S16 => 2,
            Self::F64 => 8,
            _ => 4,
        }
    }

    /// Reads little-endian samples into float32, integers scaled by full scale.
    fn load(self, bytes: &[u8], out: &mut [f32]) {
        match self {
            Self::F32 => {
                for (slot, c) in out.iter_mut().zip(bytes.chunks_exact(4)) {
                    *slot = f32::from_le_bytes([c[0], c[1], c[2], c[3]]);
                }
            }
            Self::F64 => {
                for (slot, c) in out.iter_mut().zip(bytes.chunks_exact(8)) {
                    *slot = f64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]) as f32;
                }
            }
            Self::S16 => {
                for (slot, c) in out.iter_mut().zip(bytes.chunks_exact(2)) {
                    *slot = i16::from_le_bytes([c[0], c[1]]) as f32 / 32_768.0;
                }
            }
            Self::S32 => {
                for (slot, c) in out.iter_mut().zip(bytes.chunks_exact(4)) {
                    *slot = (i32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64 / 2_147_483_648.0) as f32;
                }
            }
            Self::S24In32 => {
                for (slot, c) in out.iter_mut().zip(bytes.chunks_exact(4)) {
                    *slot = i32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f32 / 8_388_608.0;
                }
            }
        }
    }

    /// Writes float32 samples back, rounded to the nearest step and clipped. Only the
    /// 16-bit layout is dithered, and only samples the stage actually changed: one
    /// already on a step passes bit for bit, while one a preamp or curve moved would
    /// otherwise carry quantisation error that follows the music on quiet passages,
    /// which triangular dither turns into steady noise.
    fn store(self, samples: &[f32], bytes: &mut [u8], dither: &mut Dither) {
        match self {
            Self::F32 => {
                for (value, c) in samples.iter().zip(bytes.chunks_exact_mut(4)) {
                    c.copy_from_slice(&value.to_le_bytes());
                }
            }
            Self::F64 => {
                for (value, c) in samples.iter().zip(bytes.chunks_exact_mut(8)) {
                    c.copy_from_slice(&(*value as f64).to_le_bytes());
                }
            }
            Self::S16 => {
                for (value, c) in samples.iter().zip(bytes.chunks_exact_mut(2)) {
                    let scaled = value * 32_768.0;
                    let nearest = scaled.round();
                    let shaped = if (scaled - nearest).abs() < 1e-4 { nearest } else { scaled + dither.triangular() };
                    let quantised = shaped.round().clamp(-32_768.0, 32_767.0) as i16;
                    c.copy_from_slice(&quantised.to_le_bytes());
                }
            }
            Self::S32 => {
                for (value, c) in samples.iter().zip(bytes.chunks_exact_mut(4)) {
                    let quantised = (*value as f64 * 2_147_483_648.0)
                        .round()
                        .clamp(-2_147_483_648.0, 2_147_483_647.0) as i32;
                    c.copy_from_slice(&quantised.to_le_bytes());
                }
            }
            Self::S24In32 => {
                for (value, c) in samples.iter().zip(bytes.chunks_exact_mut(4)) {
                    let quantised = (value * 8_388_608.0).round().clamp(-8_388_608.0, 8_388_607.0) as i32;
                    c.copy_from_slice(&quantised.to_le_bytes());
                }
            }
        }
    }
}

/// Triangular-probability dither in units of one least significant bit, from a
/// small xorshift generator: two uniform draws summed span plus or minus one bit.
struct Dither(u32);

impl Dither {
    fn new() -> Self {
        Self(0x9E37_79B9)
    }

    fn uniform(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        (self.0 >> 8) as f32 / 16_777_216.0 - 0.5
    }

    fn triangular(&mut self) -> f32 {
        self.uniform() + self.uniform()
    }
}

/// Frames converted and filtered per kernel call, which bounds the scratch buffer.
const CHUNK_FRAMES: usize = 16_384;

/// One negotiated stream: its kernel and every buffer the streaming thread needs.
struct Stream {
    format: SampleFormat,
    channels: usize,
    rate: f64,
    kernel: EqualizerKernel,
    planes: Vec<Plane>,
    scratch: Vec<f32>,
    analysis: Vec<f32>,
    applied: Option<(u64, i32)>,
    dither: Dither,
    engaged: bool,
    was_processing: bool,
    segment: Option<gst::FormattedSegment<gst::ClockTime>>,
}

impl Stream {
    fn new(format: SampleFormat, channels: usize, rate: f64) -> Self {
        Self {
            format,
            channels,
            rate,
            kernel: EqualizerKernel::new(channels, rate),
            planes: (0..channels)
                .map(|offset| Plane { offset, stride: channels })
                .collect(),
            scratch: vec![0.0; CHUNK_FRAMES * channels],
            analysis: vec![0.0; SpectrumAnalyzer::WINDOW_SIZE],
            applied: None,
            dither: Dither::new(),
            engaged: false,
            was_processing: false,
            segment: None,
        }
    }

    /// Runs `config` with the song's own volume folded in. The first call of a
    /// kernel puts it in force on the first sample; later ones glide.
    fn apply(&mut self, config: &EqConfig, level: i32) {
        let starts_engaged = self.applied.is_none();
        let stage = song_gain::stage(
            config.is_engaged,
            &config.bands,
            config.preamp_db,
            config.peak_guard,
            level,
        );
        self.kernel.configure_starting(
            &stage.bands,
            stage.preamp_db,
            stage.is_engaged,
            stage.peak_guard,
            starts_engaged,
        );
        self.engaged = stage.is_engaged;
        self.applied = Some((config.version, level));
    }

    /// A new song begins at another volume: a fresh kernel puts its level in
    /// force from its first sample instead of gliding over from the last song's.
    fn begin_song(&mut self, level: i32) {
        if self.applied.map(|(_, applied)| applied) != Some(level) {
            self.kernel = EqualizerKernel::new(self.channels, self.rate);
            self.applied = None;
        }
    }

    fn needs_processing(&self, analysis_requested: bool) -> bool {
        self.engaged || !self.kernel.is_bypassed() || analysis_requested
    }

    /// Runs the kernel over every whole frame in `bytes`, writing the result back
    /// only when the stage can change a sample, and returns the frames handled.
    fn process(&mut self, bytes: &mut [u8]) -> usize {
        let frame_bytes = self.channels * self.format.bytes();
        let total = bytes.len() / frame_bytes;
        let changes_samples = !self.kernel.is_bypassed();
        let mut done = 0;
        while done < total {
            let frames = (total - done).min(CHUNK_FRAMES);
            let span = &mut bytes[done * frame_bytes..(done + frames) * frame_bytes];
            let scratch = &mut self.scratch[..frames * self.channels];
            self.format.load(span, scratch);
            self.kernel.process(scratch, &self.planes, frames);
            if changes_samples {
                self.format.store(scratch, span, &mut self.dither);
            }
            done += frames;
        }
        total
    }
}

mod imp {
    use super::*;
    use gst_base::prelude::BaseTransformExt;

    #[derive(Default)]
    pub struct FlaccyEq {
        pub(super) shared: OnceLock<Arc<EqShared>>,
        stream: Mutex<Option<Stream>>,
    }

    impl FlaccyEq {
        pub(super) fn shared(&self) -> Arc<EqShared> {
            Arc::clone(self.shared.get_or_init(EqShared::new))
        }

        /// How far ahead of the pipeline clock the end of this buffer plays, or
        /// `None` while there is no clock or the buffer carries no timestamps.
        fn lead_nanoseconds(
            &self,
            stream: &Stream,
            pts: Option<gst::ClockTime>,
            duration: Option<gst::ClockTime>,
        ) -> Option<i64> {
            let element = self.obj();
            let running_end = stream.segment.as_ref()?.to_running_time(pts? + duration?)?;
            let now = element.clock()?.time().checked_sub(element.base_time()?)?;
            Some(running_end.nseconds() as i64 - now.nseconds() as i64)
        }

        fn with_stream<R>(&self, work: impl FnOnce(&mut Stream) -> R) -> Option<R> {
            let mut guard = self.stream.lock().ok()?;
            guard.as_mut().map(work)
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FlaccyEq {
        const NAME: &'static str = "FlaccyEq";
        type Type = super::FlaccyEq;
        type ParentType = gst_base::BaseTransform;
    }

    impl ObjectImpl for FlaccyEq {}
    impl GstObjectImpl for FlaccyEq {}

    impl ElementImpl for FlaccyEq {
        fn metadata() -> Option<&'static gst::subclass::ElementMetadata> {
            static METADATA: LazyLock<gst::subclass::ElementMetadata> = LazyLock::new(|| {
                gst::subclass::ElementMetadata::new(
                    "Flaccy equalizer",
                    "Filter/Effect/Audio",
                    "Parametric and graphic equalizer with a float32 signal path",
                    "Flaccy",
                )
            });
            Some(&*METADATA)
        }

        fn pad_templates() -> &'static [gst::PadTemplate] {
            static TEMPLATES: LazyLock<Vec<gst::PadTemplate>> = LazyLock::new(|| {
                let caps = gst_audio::AudioCapsBuilder::new_interleaved()
                    .format_list([
                        AudioFormat::F32le,
                        AudioFormat::F64le,
                        AudioFormat::S16le,
                        AudioFormat::S32le,
                        AudioFormat::S2432le,
                    ])
                    .channels_range(1..=8)
                    .build();
                vec![
                    gst::PadTemplate::new("src", gst::PadDirection::Src, gst::PadPresence::Always, &caps)
                        .expect("src template"),
                    gst::PadTemplate::new("sink", gst::PadDirection::Sink, gst::PadPresence::Always, &caps)
                        .expect("sink template"),
                ]
            });
            TEMPLATES.as_ref()
        }
    }

    impl BaseTransformImpl for FlaccyEq {
        const MODE: gst_base::subclass::BaseTransformMode = gst_base::subclass::BaseTransformMode::AlwaysInPlace;
        const PASSTHROUGH_ON_SAME_CAPS: bool = false;
        const TRANSFORM_IP_ON_PASSTHROUGH: bool = false;

        fn start(&self) -> Result<(), gst::ErrorMessage> {
            self.obj().set_passthrough(true);
            Ok(())
        }

        fn stop(&self) -> Result<(), gst::ErrorMessage> {
            if let Ok(mut guard) = self.stream.lock() {
                *guard = None;
            }
            Ok(())
        }

        fn set_caps(&self, incaps: &gst::Caps, _outcaps: &gst::Caps) -> Result<(), gst::LoggableError> {
            let info = gst_audio::AudioInfo::from_caps(incaps)
                .map_err(|_| gst::loggable_error!(gst::CAT_RUST, "unreadable audio caps"))?;
            let format = SampleFormat::from_audio(info.format())
                .ok_or_else(|| gst::loggable_error!(gst::CAT_RUST, "unsupported sample format"))?;
            let channels = info.channels() as usize;
            if !(1..=8).contains(&channels) || info.layout() != gst_audio::AudioLayout::Interleaved {
                return Err(gst::loggable_error!(gst::CAT_RUST, "unsupported channel layout"));
            }
            let shared = self.shared();
            let mut stream = Stream::new(format, channels, info.rate() as f64);
            stream.apply(&shared.current(), shared.level_heard());
            shared.note_stream(info.rate(), channels as u32);
            if let Ok(mut guard) = self.stream.lock() {
                *guard = Some(stream);
            }
            Ok(())
        }

        fn sink_event(&self, event: gst::Event) -> bool {
            match event.view() {
                gst::EventView::StreamStart(_) => {
                    if let Some(level) = self.shared().begin_song() {
                        self.with_stream(|stream| stream.begin_song(level));
                    }
                }
                gst::EventView::FlushStop(_) => {
                    self.shared().forget_last_buffer();
                    self.with_stream(|stream| stream.kernel.reset());
                }
                gst::EventView::Segment(segment) => {
                    let segment = segment.segment().downcast_ref::<gst::ClockTime>().cloned();
                    self.with_stream(|stream| {
                        stream.kernel.reset();
                        stream.segment = segment;
                    });
                }
                _ => {}
            }
            self.parent_sink_event(event)
        }

        fn before_transform(&self, _buffer: &gst::BufferRef) {
            let shared = self.shared();
            let analysis = shared.analysis_requested();
            let processing = self.with_stream(|stream| {
                if let Some(config) = shared.try_current() {
                    let level = shared.level_heard();
                    if stream.applied != Some((config.version, level)) {
                        stream.apply(&config, level);
                    }
                }
                let processing = stream.needs_processing(analysis);
                if processing && !stream.was_processing {
                    stream.kernel.reset();
                }
                stream.was_processing = processing;
                processing
            });
            if let Some(processing) = processing {
                self.obj().set_passthrough(!processing);
            }
        }

        fn transform_ip(&self, buffer: &mut gst::BufferRef) -> Result<gst::FlowSuccess, gst::FlowError> {
            let shared = self.shared();
            let analysis_requested = shared.analysis_requested();
            let mut guard = self.stream.lock().map_err(|_| gst::FlowError::Error)?;
            let stream = guard.as_mut().ok_or(gst::FlowError::NotNegotiated)?;
            let (pts, duration) = (buffer.pts(), buffer.duration());
            let mut map = buffer.map_writable().map_err(|_| gst::FlowError::Error)?;
            let frames = stream.process(map.as_mut_slice());
            if let Some(lead) = self.lead_nanoseconds(stream, pts, duration) {
                shared.note_lead(lead);
            }
            shared.note_buffer(frames, stream.kernel.block_peak(), stream.kernel.guard_reduced());
            if analysis_requested {
                stream.kernel.copy_analysis(&mut stream.analysis, SpectrumAnalyzer::WINDOW_SIZE);
                shared.record_analysis(stream.rate, &stream.analysis);
            }
            Ok(gst::FlowSuccess::Ok)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_shared::equalizer::biquad::FilterType;
    use flaccy_shared::equalizer::profile::EqualizerBand;

    const RATE: usize = 44_100;
    const CHANNELS: usize = 2;
    const BLOCK_FRAMES: usize = 4_096;

    fn caps_name(format: SampleFormat) -> &'static str {
        match format {
            SampleFormat::F32 => "F32LE",
            SampleFormat::F64 => "F64LE",
            SampleFormat::S16 => "S16LE",
            SampleFormat::S32 => "S32LE",
            SampleFormat::S24In32 => "S24_32LE",
        }
    }

    /// `appsrc ! flaccyeq ! appsink`, pushed and pulled in lockstep, with the
    /// element's shared box in hand so a test can switch the stage mid-stream.
    struct Rig {
        pipeline: gst::Pipeline,
        source: gst::Element,
        sink: gst::Element,
        eq: FlaccyEq,
        shared: Arc<EqShared>,
        format: SampleFormat,
        version: u64,
    }

    impl Rig {
        fn new(format: SampleFormat) -> Self {
            gst::init().expect("gst init");
            crate::eq::register();
            let shared = EqShared::new();
            let eq = FlaccyEq::with_shared(Arc::clone(&shared));
            let caps = gst::Caps::builder("audio/x-raw")
                .field("format", caps_name(format))
                .field("layout", "interleaved")
                .field("rate", RATE as i32)
                .field("channels", CHANNELS as i32)
                .build();
            let source = gst::ElementFactory::make("appsrc")
                .property("caps", &caps)
                .property("format", gst::Format::Time)
                .build()
                .expect("appsrc");
            let sink = gst::ElementFactory::make("appsink")
                .property("sync", false)
                .build()
                .expect("appsink");
            let pipeline = gst::Pipeline::new();
            let eq_element: gst::Element = eq.clone().upcast();
            pipeline.add_many([&source, &eq_element, &sink]).expect("add");
            gst::Element::link_many([&source, &eq_element, &sink]).expect("link");
            pipeline.set_state(gst::State::Playing).expect("playing");
            Self { pipeline, source, sink, eq, shared, format, version: 0 }
        }

        fn engage(&mut self, engaged: bool) {
            self.version += 1;
            self.shared.publish(EqConfig {
                version: self.version,
                is_engaged: engaged,
                bands: vec![EqualizerBand::new(FilterType::Bell, 220.0, 9.0, Some(1.0), true)],
                preamp_db: 0.0,
                peak_guard: true,
            });
        }

        fn is_passthrough(&self) -> bool {
            gst_base::prelude::BaseTransformExt::is_passthrough(&self.eq)
        }

        fn run(&self, bytes: &[u8]) -> Vec<u8> {
            let buffer = gst::Buffer::from_slice(bytes.to_vec());
            let flow: gst::FlowReturn = self.source.emit_by_name("push-buffer", &[&buffer]);
            assert_eq!(flow, gst::FlowReturn::Ok);
            let sample: Option<gst::Sample> = self.sink.emit_by_name("pull-sample", &[]);
            let sample = sample.expect("a sample comes out");
            let buffer = sample.buffer().expect("buffer");
            let map = buffer.map_readable().expect("map");
            map.as_slice().to_vec()
        }

        fn encode(&self, amplitude: f32, frequency: f64, start_frame: usize, frames: usize) -> Vec<u8> {
            let mut floats = Vec::with_capacity(frames * CHANNELS);
            for frame in start_frame..start_frame + frames {
                let value = amplitude * (2.0 * std::f64::consts::PI * frequency * frame as f64 / RATE as f64).sin() as f32;
                floats.extend(std::iter::repeat(value).take(CHANNELS));
            }
            let mut bytes = vec![0u8; floats.len() * self.format.bytes()];
            self.format.store(&floats, &mut bytes, &mut Dither::new());
            bytes
        }

        fn decode_left(&self, bytes: &[u8]) -> Vec<f32> {
            let mut floats = vec![0.0f32; bytes.len() / self.format.bytes()];
            self.format.load(bytes, &mut floats);
            floats.iter().step_by(CHANNELS).copied().collect()
        }
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = self.pipeline.set_state(gst::State::Null);
        }
    }

    fn rms(samples: &[f32]) -> f64 {
        (samples.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / samples.len() as f64).sqrt()
    }

    fn noise(format: SampleFormat, frames: usize) -> Vec<u8> {
        let mut state = 0x2545_F491_4F6C_DD1Du64;
        let mut bytes = vec![0u8; frames * CHANNELS * format.bytes()];
        for byte in bytes.iter_mut() {
            state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            *byte = (state >> 33) as u8;
        }
        if format == SampleFormat::F32 {
            for chunk in bytes.chunks_exact_mut(4) {
                let value = (u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) % 20_000) as f32 / 10_000.0 - 1.0;
                chunk.copy_from_slice(&value.to_le_bytes());
            }
        }
        bytes
    }

    fn passthrough_is_bit_exact(format: SampleFormat) {
        let rig = Rig::new(format);
        for round in 0..4 {
            let input = noise(format, BLOCK_FRAMES + round * 17);
            assert_eq!(rig.run(&input), input, "{format:?} round {round}");
        }
        assert!(rig.is_passthrough());
        assert_eq!(rig.shared.frames_processed(), 0, "the kernel never ran");
    }

    #[test]
    fn passthrough_is_bit_exact_for_s16() {
        passthrough_is_bit_exact(SampleFormat::S16);
    }

    #[test]
    fn passthrough_is_bit_exact_for_f32() {
        passthrough_is_bit_exact(SampleFormat::F32);
    }

    fn bell_lifts_the_tone_by_nine_decibels(format: SampleFormat) {
        let mut rig = Rig::new(format);
        rig.engage(true);
        let blocks = 20;
        let mut input = Vec::new();
        let mut output = Vec::new();
        for block in 0..blocks {
            let bytes = rig.encode(0.1, 220.0, block * BLOCK_FRAMES, BLOCK_FRAMES);
            output.extend(rig.decode_left(&rig.run(&bytes)));
            input.extend(rig.decode_left(&bytes));
        }
        let half = input.len() / 2;
        let gain = 20.0 * (rms(&output[half..]) / rms(&input[half..])).log10();
        assert!((gain - 9.0).abs() < 0.3, "{format:?}: measured {gain:.2} dB");
        assert!(!rig.is_passthrough());
        assert!(rig.shared.frames_processed() > 0);
    }

    #[test]
    fn a_nine_decibel_bell_lifts_a_220_hz_tone_in_f32() {
        bell_lifts_the_tone_by_nine_decibels(SampleFormat::F32);
    }

    #[test]
    fn a_nine_decibel_bell_lifts_a_220_hz_tone_in_s16() {
        bell_lifts_the_tone_by_nine_decibels(SampleFormat::S16);
    }

    impl Rig {
        fn start_song(&self, title: &str) {
            self.shared.hand_over(title, "Artist");
            let pad = self.eq.static_pad("sink").expect("sink pad");
            assert!(pad.send_event(gst::event::StreamStart::new(title)));
        }

        fn peak_of(&self, bytes: &[u8]) -> f32 {
            self.decode_left(bytes).iter().fold(0.0f32, |peak, value| peak.max(value.abs()))
        }
    }

    #[test]
    fn a_song_plays_at_its_own_level_from_its_first_sample_and_the_next_at_its_own() {
        let rig = Rig::new(SampleFormat::F32);
        rig.shared.set_song_level("Raised", "Artist", 60);
        rig.shared.set_song_level("Lowered", "Artist", -60);
        rig.start_song("Raised");
        let first = rig.run(&rig.encode(0.1, 220.0, 0, BLOCK_FRAMES));
        let raised = 0.1 * 10f32.powf(6.0 / 20.0);
        assert!((rig.peak_of(&first) - raised).abs() < 0.002, "raised from the start: {}", rig.peak_of(&first));
        assert_eq!(rig.shared.level_heard(), 60);

        rig.start_song("Lowered");
        let second = rig.run(&rig.encode(0.1, 220.0, BLOCK_FRAMES, 256));
        let lowered = 0.1 * 10f32.powf(-6.0 / 20.0);
        assert!(
            (rig.peak_of(&second) - lowered).abs() < 0.002,
            "no glide from the last song's level: {}",
            rig.peak_of(&second)
        );

        rig.start_song("Untouched");
        let input = rig.encode(0.1, 220.0, BLOCK_FRAMES + 256, BLOCK_FRAMES);
        assert_eq!(rig.run(&input), input, "a song at 0 dB crosses bit for bit");
        assert!(rig.is_passthrough());
    }

    #[test]
    fn changing_the_playing_songs_level_glides_and_a_raised_song_never_clips() {
        let rig = Rig::new(SampleFormat::F32);
        rig.start_song("Song");
        let input = rig.encode(0.9, 220.0, 0, BLOCK_FRAMES);
        assert_eq!(rig.run(&input), input);
        rig.shared.set_song_level("Song", "Artist", 120);
        let mut loudest = 0.0f32;
        for block in 1..8 {
            loudest = loudest.max(rig.peak_of(&rig.run(&rig.encode(0.9, 220.0, block * BLOCK_FRAMES, BLOCK_FRAMES))));
        }
        assert!(loudest <= 1.0001, "the guard holds a +12 dB song at full scale: {loudest}");
        assert!(loudest > 0.99, "and it is raised up to it: {loudest}");
        rig.shared.set_song_level("Other", "Artist", -120);
        let still = rig.peak_of(&rig.run(&rig.encode(0.9, 220.0, 8 * BLOCK_FRAMES, BLOCK_FRAMES)));
        assert!(still > 0.99, "another song's level leaves this one alone: {still}");
    }

    fn switching_off_crossfades_back_and_ends_bit_exact(format: SampleFormat) {
        let mut rig = Rig::new(format);
        rig.engage(true);
        for block in 0..6 {
            rig.run(&rig.encode(0.1, 220.0, block * BLOCK_FRAMES, BLOCK_FRAMES));
        }
        rig.engage(false);
        let fading = rig.encode(0.1, 220.0, 6 * BLOCK_FRAMES, BLOCK_FRAMES);
        let faded = rig.run(&fading);
        let frame_bytes = CHANNELS * format.bytes();
        let settled = (EqualizerKernel::CROSSFADE_FRAMES + 1) * frame_bytes;
        assert_ne!(faded[..settled], fading[..settled], "the first frames still carry the curve");
        assert_eq!(faded[settled..], fading[settled..], "the crossfade has finished by then");
        for block in 7..12 {
            let input = rig.encode(0.1, 220.0, block * BLOCK_FRAMES, BLOCK_FRAMES);
            assert_eq!(rig.run(&input), input, "block {block} crosses untouched");
        }
        assert!(rig.is_passthrough());
    }

    #[test]
    fn switching_off_crossfades_back_and_ends_bit_exact_in_f32() {
        switching_off_crossfades_back_and_ends_bit_exact(SampleFormat::F32);
    }

    #[test]
    fn switching_off_crossfades_back_and_ends_bit_exact_in_s16() {
        switching_off_crossfades_back_and_ends_bit_exact(SampleFormat::S16);
    }

    #[test]
    fn an_analysis_request_keeps_the_element_processing_without_touching_samples() {
        let rig = Rig::new(SampleFormat::S16);
        rig.shared.set_analysis_requested(true);
        let input = rig.encode(0.1, 220.0, 0, BLOCK_FRAMES * 2);
        assert_eq!(rig.run(&input), input);
        assert!(!rig.is_passthrough());
        assert!(rig.shared.frames_processed() > 0);
        let mut window = vec![0.0f32; SpectrumAnalyzer::WINDOW_SIZE];
        assert_eq!(rig.shared.copy_analysis_into(&mut window), Some(RATE as f64));
        assert!(window.iter().any(|v| v.abs() > 0.05));
        rig.shared.set_analysis_requested(false);
        rig.run(&input);
        rig.run(&input);
        assert!(rig.is_passthrough());
    }

    #[test]
    fn sixteen_bit_output_is_dithered_so_a_level_between_two_steps_survives() {
        let level = 100.3f32 / 32_768.0;
        let samples = vec![level; 20_000];
        let mut bytes = vec![0u8; samples.len() * 2];
        SampleFormat::S16.store(&samples, &mut bytes, &mut Dither::new());
        let mut back = vec![0.0f32; samples.len()];
        SampleFormat::S16.load(&bytes, &mut back);
        let mean = back.iter().map(|v| f64::from(*v) * 32_768.0).sum::<f64>() / back.len() as f64;
        assert!((mean - 100.3).abs() < 0.05, "mean {mean}");
    }

    #[test]
    fn integer_formats_round_trip_and_clip() {
        for format in [SampleFormat::S16, SampleFormat::S32, SampleFormat::S24In32] {
            let mut bytes = vec![0u8; 3 * format.bytes()];
            format.store(&[0.25, 1.5, -2.0], &mut bytes, &mut Dither::new());
            let mut back = [0.0f32; 3];
            format.load(&bytes, &mut back);
            assert!((back[0] - 0.25).abs() < 1e-4, "{format:?}");
            assert!(back[1] > 0.9999 && back[1] <= 1.0, "{format:?} clips high");
            assert_eq!(back[2], -1.0, "{format:?} clips low");
        }
    }
}
