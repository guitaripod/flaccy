/// The video chosen for one library track, and how far its timeline sits from
/// the audio on disk.
#[derive(Clone)]
pub struct VideoMatch {
    pub video_id: String,
    pub title: String,
    pub channel: String,
    pub duration: f64,
    pub offset: f64,
    pub aligned: bool,
    pub chosen_by_user: bool,
    pub reason: String,
}
