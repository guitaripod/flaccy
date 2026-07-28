import Foundation

struct ListeningGuideCard {
    let title: String
    let symbolName: String
    let body: String
    let bulletsCaption: String?
    let bullets: [String]
    let takeawayCaption: String?
    let takeaway: String?
    let sourceLabel: String?
    let sourceURL: URL?

    init(
        title: String,
        symbolName: String,
        body: String,
        bulletsCaption: String? = nil,
        bullets: [String] = [],
        takeawayCaption: String? = nil,
        takeaway: String? = nil,
        sourceLabel: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.title = title
        self.symbolName = symbolName
        self.body = body
        self.bulletsCaption = bulletsCaption
        self.bullets = bullets
        self.takeawayCaption = takeawayCaption
        self.takeaway = takeaway
        self.sourceLabel = sourceLabel
        self.sourceURL = sourceURL
    }
}

enum ListeningGuideContent {

    static let caption = String(localized: "Audio Quality")
    static let headline = String(localized: "Listening Guide")
    static let intro = String(localized: "Five facts about Bluetooth, AAC, and what your files actually deliver to your ears.")

    static let cards: [ListeningGuideCard] = [
        ListeningGuideCard(
            title: String(localized: "Bluetooth & AAC"),
            symbolName: "airpods",
            body: String(localized: "AirPods receive audio over Bluetooth using Apple's AAC codec at up to roughly 256 kbps. The rate is adaptive — it can drop when the wireless link degrades.")
        ),
        ListeningGuideCard(
            title: String(localized: "Why lossless can't reach AirPods"),
            symbolName: "waveform",
            body: String(localized: "Apple confirms Bluetooth connections aren't lossless. Playing a FLAC or ALAC file to AirPods delivers, at best, ~256 kbps AAC at your ear. AirPods Pro 3's spec sheet lists \u{201C}No Lossless Audio\u{201D}."),
            bulletsCaption: String(localized: "Exceptions"),
            bullets: [
                String(localized: "AirPods Max (USB-C) support 24-bit/48 kHz lossless over a USB-C cable, added by a firmware update in March 2025."),
                String(localized: "H2-chip AirPods get lossless wirelessly only with Apple Vision Pro, over a proprietary 5 GHz link — not standard Bluetooth."),
            ],
            sourceLabel: "support.apple.com/en-us/118295",
            sourceURL: URL(string: "https://support.apple.com/en-us/118295")
        ),
        ListeningGuideCard(
            title: String(localized: "What happens to your files"),
            symbolName: "arrow.triangle.2.circlepath",
            body: String(localized: "iOS mixes all audio — your music plus system sounds — into one stream and re-encodes it to AAC for Bluetooth, so even a 256 kbps AAC file is decoded and encoded again on its way to your AirPods. This is how the audio pipeline works: engineering consensus, as Apple doesn't document passthrough. One extra generation of high-bitrate AAC is essentially inaudible — the loss is real on paper, tiny in practice."),
            takeawayCaption: String(localized: "Practical takeaway"),
            takeaway: String(localized: "Storing AAC 256 instead of FLAC loses nothing audible over AirPods and saves roughly 60% storage.")
        ),
        ListeningGuideCard(
            title: String(localized: "When FLAC is worth it"),
            symbolName: "cable.connector",
            body: String(localized: "For true lossless on iPhone, go wired: the Apple headphone adapter delivers up to 24-bit/48 kHz, and an external USB-C DAC unlocks hi-res lossless up to 24-bit/192 kHz. FLAC also shines on a home rig or desktop where the DAC is wired.")
        ),
        ListeningGuideCard(
            title: String(localized: "Can you hear the difference?"),
            symbolName: "ear",
            body: String(localized: "In published blind tests — the largest public one put 580 participants on CD versus 256 kbps AAC — most listeners cannot reliably tell 256 kbps AAC from lossless. Only a small minority succeed, on specific tracks, under ideal conditions, on revealing gear. Apple itself calls the difference \u{201C}virtually indistinguishable\u{201D}.")
        ),
    ]
}
