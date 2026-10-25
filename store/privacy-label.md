# Flaccy App Privacy label

Answers for App Store Connect, App Privacy section, for the iOS app and the Mac app (the two records answer the same). Apple does not expose this section through the API; `store/app-privacy.json` holds the same rows and is applied with `asc web privacy plan`, `apply` and `publish` (ops/runbooks/submissions-and-review.md). It matches `Resources/PrivacyInfo.xcprivacy`, `Platforms/mac/PrivacyInfo.xcprivacy` and the policy at https://midgarcorp.cc/legal/flaccy/privacy/ (source: `web/midgarcorp/src/content/legal/flaccy/privacy.html`, last updated 23 October 2026). The privacy policy URL on the app info (`store/metadata/*/app-info/*.json`) and the links in the descriptions move from the `mako.midgarcorp.cc` addresses to the midgarcorp.cc one with this release; `midgar listing` pushes them and, under the `metadata_edit` policy, only with the founder at a terminal. The old address redirects to the new one, because mako answers it with a 301.

## Top-level answers

- Do you or your third-party partners collect data from this app: Yes.
- Data used to track you: none. No data type is used for tracking. The apps ask for no tracking permission and `NSPrivacyTracking` is false with no tracking domains.
- Privacy policy URL: https://midgarcorp.cc/legal/flaccy/privacy/

## Data types collected

| Data type (Apple) | Linked to the user | Used to track | Purpose | What it is in Flaccy |
| --- | --- | --- | --- | --- |
| Identifiers, User ID | Yes | No | App Functionality | The random Midgar ID, kept in iCloud Keychain and shared with Midgar's other apps on the person's devices. It goes to `api.midgarcorp.cc` (the identity service) when it is created or joined, and authorizes the portal's "Your Midgar" panel. (New with this release.) |
| Identifiers, Device ID | Yes | No | App Functionality | The app reads no advertising identifier and no vendor identifier. MidgarKit's App Attest key id, per app and per device, stored with the Midgar ID when the ID is created or joined. App Store and TestFlight builds use App Attest's production environment whether or not the app has the App Attest entitlement (Apple, App Attest Environment entitlement), so released builds create it. The AI cleanup and Last.fm signing requests to `flaccy-api` also carry a random per-install UUID (`X-Device-ID`) that only counts daily requests. (New with this release.) |
| Usage Data, Product Interaction | No | No | Analytics | The anonymous More Apps card events (opened, shown, tapped) that the portal sends to `api.midgarcorp.cc/v1/signals` through MidgarKit's anonymous signals client, with no Midgar ID, device identifier or `Authorization` header. Reading "Your Midgar" sends no event. (New with this release.) |
| Purchases, Purchase History | Yes | No | App Functionality | The App Store transactions of Flaccy Pro (yearly) and the lifetime unlocks, bought through MidgarStore with the Midgar ID as Apple's app account token and reported to the Midgar ledger. |
| User Content, Other User Content | No | No | App Functionality | The AI metadata cleanup sends file and folder names (never audio) through `api.midgarcorp.cc/v1/flaccy` to the Claude model and keeps nothing. The request carries the per-install `X-Device-ID` only for the daily count. |

Everything else is "Data Not Collected".

## Data types answered "not collected", and why

- Contacts, Browsing History, Search History, Sensitive Info, Health & Fitness, Location, Financial Info: none.
- Contact Info: none. There is no account, no name and no email address.
- Diagnostics: the log (`Library/Logs/flaccy.log`) stays on the device and is never uploaded. MetricKit is not collected.
- Other Data: none.
- Last.fm is optional: the person signs in with their own Last.fm account and the app sends scrobbles to Last.fm directly. Midgar receives only the signature request (the same track, artist and album text) and keeps nothing.

## Check before the label is entered

- Every call to Flaccy's server now goes through `api.midgarcorp.cc/v1/flaccy`; the legacy `flaccy-api.midgarcorp.cc` address is no longer used by this build, so the data collected is unchanged apart from the Midgar ID, the App Attest key id and the portal counts.
- Purchases go through MidgarStore (P2.16): each verified transaction carries the Midgar ID as app account token and goes to the Midgar ledger; Purchase History is linked.
- The Watch app has its own manifest and collects nothing: it does not use the Midgar ID, the gateway or the portal.

## Third-party SDK notes

- MidgarKit 4.3.1: `MidgarPortal` ships a manifest that declares Product Interaction for Analytics, not linked, matching the row above. `MidgarCore` (identity, HTTP, logging, signals) ships none and uses no required-reason API beyond the ones listed below. Anonymous signals send nothing else: MetricKit collection is not started.
- Cloudflare: hosts the gateway (`api.midgarcorp.cc`) and the services behind it, including Flaccy's worker, and may keep standard request logs (IP address) for a limited time; IP address is not a data type in the label.
- Anthropic: answers the AI metadata cleanup request that Flaccy's worker forwards.

## Required-reason APIs (in the manifest, not in the label)

- UserDefaults `CA92.1` (own settings), file timestamp `C617.1` (documents the person imports; the Mac also `3B52.1` for the music folder the person chose), system boot time `35F9.1` (the equalizer's render clock), disk space `E174.1` (the free-space check before an import).
