import Foundation

/// Where the published policies live: the Midgar site for the privacy policy, which is also what the store listing links
/// to (the old mako address redirects there), and mako for the terms, which it still answers.
nonisolated enum LegalLinks {
    static let privacyURL = URL(string: "https://midgarcorp.cc/legal/flaccy/privacy/")!
    static let termsURL = URL(string: "https://mako.midgarcorp.cc/terms/flaccy")!
}
