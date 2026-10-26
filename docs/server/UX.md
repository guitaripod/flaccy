# Flaccy Server: the first ten minutes

The experience contract for every client (iPhone, Mac, Linux) and the server's own terminal. Copy is final English; keys are added to `Localizable.xcstrings` and translated into the ten catalog locales. Rules from the repo apply: an error or empty state names what failed, the cause when known, and the next step; haptics on every interaction; no modal paywall; prices from `StoreProduct.price`.

## 1. Goals

- From "I have a computer with my music and Tailscale" to a synced phone in under five minutes on a Mac and ten on Linux, with no config file and no terminal on the Mac.
- The person never types a URL if they can scan a code, never types a code if they can tap a link, never sees a protocol word.
- Every failure says what to do next, in the order a person would try it (Tailscale on? code fresh? server up?).
- After setup nothing needs attention. There is no sync button.

## 2. The server's terminal

`flaccy-server setup` is a conversation, not a form. Defaults are in brackets and Return accepts them.

```
Flaccy Server 1.0

Where is your music? [~/Music]
  Found 7,412 songs in 612 albums.

Tailscale: connected as arch (100.91.211.44).
Your name on this server? [marcus]
Starting the server on port 4545... ready.
Keeping it running after you log out... done (flaccy-server.service).

Scan this with Flaccy on your iPhone, Mac or Linux:

  <QR code>

Or open this link on a device that has Flaccy:
  flaccy://server?url=http%3A%2F%2Farch%3A4545&enroll=…&name=arch

The code works once and expires in 10 minutes. Make another with `flaccy-server enroll`.
```

- No Tailscale: `Tailscale isn't running on this machine. Flaccy Server reaches your devices through it. Install it from tailscale.com/download, sign in, then run this again.`
- Port taken: `Port 4545 is in use by <process>. Use --port, or stop that program.`
- Folder empty: `That folder has no music yet. Flaccy Server will pick files up as you add them.`
- `flaccy-server doctor` prints one line per check (`✓` or `✗` plus the fix), in the order Tailscale, bind, clock, disk, ffmpeg, database, last backup, clients.

## 3. Adding a server in the app

One sheet, **Add Flaccy Server**, reached from Settings → Servers → Add, from the `flaccy://server` link, and from the getting-started guide.

| Step | What the person sees |
|---|---|
| Scan or paste | A camera view on iPhone ("Point at the code on your computer"), a paste field and a link drop target on Mac, a text field on Linux. Below it, "Type it instead" shows two fields: **Address** (`arch` or `100.91.211.44`) and **Code** |
| Checking | "Connecting to arch…" with a spinner, five second timeout per attempt |
| Connected | A success haptic and "Connected to arch." Under it: "Your playlists, loves and history now sync with this server. Its music is in your library under Servers." Button: **Done** |

- A link with `enroll` is a Flaccy Server; a link with `key` is an OpenSubsonic server and keeps today's sheet. Typed addresses are probed with `GET /flaccy/v1/hello` first; if it answers, the code field appears, otherwise the old flow runs.
- The code field groups as the person types (`ABCD-EFGH-…`), ignores spaces and dashes, accepts lower case, and reads `O` as `0` and `I`/`L` as `1`.
- The address field accepts `arch`, `arch.tailnet-name.ts.net`, an IP, with or without `http://` and a port (default 4545).

### Errors

| Situation | Title | Body | Buttons |
|---|---|---|---|
| Unreachable, timeout | Can't reach arch | Is Tailscale on? Open Tailscale and connect on this device and on arch, then try again. | Open Tailscale (iPhone, Mac), Try again |
| Name not found | Can't find arch | Check the name on the server with `tailscale status`, or scan the code from the server. | Try again |
| Code refused | That code didn't work | A code works once and expires after 10 minutes. On arch, run `flaccy-server enroll` for a new one. | Try again |
| Too many wrong codes | Too many tries | Wait a minute, then try again. | OK |
| Not a Flaccy Server | arch isn't a Flaccy Server | It answered, but not as Flaccy Server. If it is Navidrome or another Subsonic server, add it as a regular server. | Add as regular server, Cancel |
| Server too old | Update your Flaccy Server | This version of Flaccy needs Flaccy Server 1.0 or newer. | OK |
| App too old | Update Flaccy | arch needs a newer Flaccy than this one. | Open App Store (iPhone, Mac) |
| Server clock wrong | The clock on arch is wrong | Sync stays off until the server's date and time are right. Check it with `timedatectl`. | OK |

## 4. Living with it

Settings → Servers lists the server like any other, with a **Sync** badge. Its row shows one status line:

| State | Line |
|---|---|
| Idle, up to date | Synced just now / Synced 4 minutes ago |
| Working | Syncing 12 changes… |
| Offline | Offline. 4 changes will send when arch is reachable. |
| Unreachable | Can't reach arch. Is Tailscale on? |
| Not Pro | Sync is a Flaccy Pro feature. Songs still stream. |
| Needs the person | Update Flaccy to keep syncing. / Update your Flaccy Server to keep syncing. |
| Disk full on the server | arch is out of disk space. Free some up and Flaccy retries by itself. |
| Server clock wrong | The clock on arch is wrong. Sync is paused. |

Tapping the row opens **arch**:

- *Status* (the line above and "Last synced…").
- *Library*: song count, "Show arch's music in my library" (on).
- *Sync* (Pro): a switch "Sync with arch" (on); when the person is not Pro the row reads "Sync playlists, loves and history · Pro" and opens the paywall, never anything automatic.
- *Devices*: this iPhone (renamable), the others with "last seen"; swipe to remove another device.
- *Disconnect this device*: confirmation "This iPhone stops syncing with arch. Your playlists and history stay here, and arch keeps its copy." The server and the data on it are never touched by Disconnect.

First connect with data on both sides shows one summary sheet, only when something merged: "We combined your playlists. Road Trip and Workout were on both devices and are now one each. N songs are now loved here." with **Undo** for each line and **OK**.

## 5. Mac and Linux

- Mac: Settings → Servers pane with **Add Flaccy Server…**, **Paste Link**, link drops, and the same sheet text. A menu bar status line when the menu bar extra is on.
- Linux: Preferences → Servers → **Add Flaccy Server**, one dialog with the same steps and copy; the status line under the server name; `FLACCY_DEMO_SERVER=1` for screenshots against a throwaway server.
- Every control has a VoiceOver / Orca label, scales with Dynamic Type / interface scale, and reports the status line as a live region.

## 6. Quiet nudges

- Settings → Servers has a footer for people with no server: "Have a computer with your music on it? Flaccy Server shares it with your other devices, and keeps playlists, loves and history in sync. It's free: flaccy.app/server." (the address is whatever the website decision settles; until then the repo README link).
- The getting-started guide gains one card, "Hear your whole library on every device", linking to the same sheet.
- Nothing appears on Home, and nothing nags: a person who closes the footer or the card never sees it again.
