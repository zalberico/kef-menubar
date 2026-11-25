<p align="center">
  <img src="docs/app-icon.png" width="128" alt="KEF Menu Bar app icon">
</p>

<h1 align="center">KEF Menu Bar</h1>

<p align="center">
  Control your KEF wireless speakers from the Mac menu bar.<br>
  Volume, inputs, now playing and EQ, directly over your local network. No cloud, no account.
</p>

---

If you have KEF speakers on your desk, you've probably reached for your phone and opened
KEF Connect just to turn the volume down or switch from TV to USB. This is a small native
macOS app that puts those controls in the menu bar, with global keyboard shortcuts for
volume.

It talks to the speaker's own local API, the same one KEF Connect uses. Nothing goes
through KEF's servers, and there are no third-party dependencies.

<p align="center">
  <img src="docs/panel.png" width="354" alt="The KEF Menu Bar panel: speaker name and power, volume slider, input tiles with USB selected, subwoofer level, and the expanded Sound section with treble, bass extension, desk and wall mode, balance, phase correction, sub crossover, high-pass, sub polarity and subwoofer output">
</p>

> **Status:** works well every day on an LSX II (firmware 3.1.141) with a KC62 subwoofer.
> Other W2-platform models should work but are untested. Reports and PRs are welcome.
>
> Not affiliated with or endorsed by KEF. KEF and its product names are trademarks of
> their respective owners.

## Features

- **Power, volume and mute**, with a live level meter right in the menu bar icon
- **Input picker:** USB, Wi-Fi / AirPlay, TV (HDMI), Optical, Analog, Bluetooth, and
  Coaxial on models that have it
- **Now playing** with artwork and play/pause/skip while streaming over Wi-Fi or Bluetooth
- **Subwoofer level**, plus a collapsible **Sound** section with the speaker's EQ: treble,
  bass extension, desk and wall mode, balance, phase correction, sub crossover, speaker
  high-pass, sub polarity and output
- **Global shortcuts:** ⌃⌥⌘↑ / ⌃⌥⌘↓ / ⌃⌥⌘M by default (all configurable), with a small
  volume overlay. Holding a volume key repeats.
- **Live updates:** changes from the remote, KEF Connect, AirPlay or anything else show up
  within a second
- **Subwoofer presets:** pick your KEF sub model (KC62, KF92, Kube…) and get KEF's default
  gain, crossover and high-pass, or restore them after tweaking
- **Speaker settings:** name, auto standby (ECO, 30, 60 minutes, never), wake source,
  switch to TV when it turns on, startup volume (one level or per input), volume limit,
  standby light, startup sound, remote on/off and volume step
- **Firmware updates:** see the installed version, check for updates on demand, and
  install one after a confirmation. The panel tells you when an update is available.
- **App settings:** Bonjour discovery or a fixed IP address, shortcut volume step and
  overlay, launch at login
- **Native and light:** SwiftUI, light and dark mode, no Dock icon, about 2 MB

The menu bar icon is a little bookshelf speaker with KEF's Uni-Q driver, not Apple's
speaker symbol, so you can tell it apart from the system volume:

<p align="center">
  <img src="docs/menubar-states.png" width="540" alt="Menu bar icon: on with level meter, muted, standby, offline, on light and dark menu bars">
</p>

## Compatibility

| | |
| --- | --- |
| **Mac** | macOS 14 Sonoma or later, Apple silicon |
| **Tested** | KEF LSX II, firmware 3.1.141, with a KC62 |
| **Should work** | LSX II LT, LS50 Wireless II, LS60 Wireless (same W2 platform and API) |
| **Not supported** | The original LSX and LS50 Wireless, which use a different protocol |

The Mac and the speaker must be on the same network.

## Install

### Download

1. Download the latest **KEF-Menu-Bar-….zip** from
   [Releases](https://github.com/zalberico/kef-menubar/releases/latest) and unzip it.
2. Move **KEF Menu Bar** to your Applications folder and open it. The app is signed and
   notarized by Apple, so macOS only asks you to confirm opening an app downloaded from
   the internet.
3. On first launch macOS asks for **Local Network** access. Allow it: the app can't reach
   the speaker without it. If you clicked Don't Allow, turn it back on in System Settings ›
   Privacy & Security › Local Network.

To update, download the new release and replace the app in Applications.

The app finds your speaker with Bonjour. If it doesn't, open **Settings…** from the
panel and enter the speaker's IP address. You'll find the address in KEF Connect under the
speaker's settings, or in your router's client list. A DHCP reservation for the speaker is
a good idea either way.

### Build it yourself

If you'd rather build from source, it takes about a minute.

1. Install **Xcode 16 or later** from the App Store and open it once to finish setup.
2. Make Xcode the active developer directory. The Command Line Tools alone aren't enough,
   because they lack the SwiftUI macro plugins:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app
   ```
3. Clone and build:
   ```bash
   git clone https://github.com/zalberico/kef-menubar.git
   cd kef-menubar
   scripts/build-app.sh --install
   ```
   This builds **KEF Menu Bar.app**, signs it, copies it to `~/Applications` and launches
   it. The script signs with your first "Apple Development" certificate if you have one and
   ad-hoc otherwise; set `CODESIGN_IDENTITY` to override.
4. Allow **Local Network** access on first launch, as above.

To update later, run `git pull` and `scripts/build-app.sh --install` again.

### Making a release

Push a version tag and the [Release workflow](.github/workflows/release.yml) tests and
builds the app, then publishes it as a GitHub Release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The workflow signs the app with Developer ID and has Apple notarize it, using the secrets
listed at the top of the workflow. Without those secrets (in a fork, say) it falls back to
an ad-hoc signature, and macOS then makes people allow the app once in System Settings ›
Privacy & Security › **Open Anyway**.

## Using it

Click the speaker in the menu bar for the panel: power, volume, inputs, now playing, sub
level and the **Sound** section. The shortcuts work from any app. The overlay shows the
new level, and you can turn it off in Settings.

The speaker keeps a separate **volume and EQ for each input**, and the app follows that.
Switching from USB to TV gives you TV's own level and EQ. Edits apply to the input you're
on, including **Sub model** › **Restore**, which puts the sub gain, crossover and speaker
high-pass back to KEF's defaults for your subwoofer.

**Settings…** has two tabs. **General** covers the app itself: which speaker, the keyboard
shortcuts and launch at login. **Speaker** covers settings stored on the speaker: name,
standby and wake, startup volume, volume limit, lights, the remote and firmware.

## Command line: `kefctl`

The repo also builds a small CLI on the same library, handy for scripts, Shortcuts or
debugging:

```bash
swift build -c release --product kefctl
K="$(swift build -c release --product kefctl --show-bin-path)/kefctl"

$K discover                        # list speakers on the network
$K 192.168.1.20 state              # name, power, input, volume, now playing…
$K 192.168.1.20 volume 30
$K 192.168.1.20 mute on
$K 192.168.1.20 source tv          # usb | wifi | tv | optical | coaxial | analog | bluetooth | standby
$K 192.168.1.20 control pause      # pause | next | previous
$K 192.168.1.20 eq                 # current input's EQ profile and allowed ranges
$K 192.168.1.20 eq-set trebleAmount -1
$K 192.168.1.20 watch 60           # print live events for 60 s (default 30)
$K 192.168.1.20 settings           # standby, wake source, startup volume, lights, remote
$K 192.168.1.20 name "Desk"        # rename the speaker
$K 192.168.1.20 firmware           # installed version and update status
$K 192.168.1.20 firmware check     # ask the speaker to look for an update (installing is app-only)
```

## FAQ

**Do I still need KEF Connect?** Only for initial setup and network changes (Wi-Fi,
pairing), and for its streaming-service browsing. Everything on KEF Connect's settings
screens that a desktop speaker needs is under **Settings › Speaker**, and firmware updates
are there too: **Check Now** asks the speaker to look for one, and
**Update…** installs it after you confirm. The speaker then restarts and is unreachable for
a few minutes. It also checks by itself every few hours and can install updates while
idle, so you may never need the button.

**Is it safe to point at my speakers?** The app reads state and changes the same everyday
settings KEF Connect does: volume, mute, input, playback, EQ, the volume limit and the
speaker settings above. It can also ask the speaker to
check for firmware and, only after you confirm, install an update. The client library
refuses destructive paths outright, whatever calls it: factory reset, reboot, network
setup, pairing wipes and DSP restore (`KEFSafety` in `Sources/KEFKit/Paths.swift`).
Firmware paths are refused there too, except for the two actions KEF Connect itself
uses. Those are reachable only through dedicated methods, and the install one first
re-reads the speaker and refuses unless the speaker reports an update. Volume and EQ writes are held off for about 1.5 s after
an input change, so a shortcut can't apply one input's level to another.

**Does it phone home?** No. It talks only to your speaker. The one exception is album art,
which it loads from whatever URL the speaker reports for the current track, sometimes a
streaming service's image server.

**Multiple speakers?** The app controls one speaker (a stereo pair counts as one). You can
pick which one in Settings, and the app then sticks to that speaker by its MAC address,
even if its IP address changes.

**Why not the App Store?** It hasn't been needed. The releases here are signed with
Developer ID and notarized by Apple, which is all macOS needs to open them without a
warning.

## How it works

KEF's W2 speakers expose a JSON API on the local network: `getData` / `setData` on paths
like `player:volume`, an event queue you long-poll for changes, and Bonjour advertising as
`_kef-info._tcp`. The protocol follows [pykefcontrol](https://github.com/N0ciple/pykefcontrol)
1.0.1 (MIT), which this project uses as its reference. `KEFKit` is a Swift port derived from
it (see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)), and the signing tests check against
pykefcontrol's own `sign()`.

What we found on the LSX II on firmware 3.1.141:

- Only HTTPS on port 4430 is served. The certificate is issued by KEF's private CA for the
  speaker's IP addresses and regenerated at boot. The app pins that CA. Port 80 is closed,
  even though Bonjour still advertises it.
- GETs are unsigned. POSTs need an `HMAC_SHA256` authorization header, after a one-time
  `webserver:addUser` registration.
- The speaker struggles with many fresh TLS handshakes in a row, so the client keeps one
  keep-alive session.
- EQ and sub settings are read and written as one `kef:eqProfile/v2` profile. It's per
  input, and so is the volume.
- `settings:/kef/host/speakerStatus` can stay `standby` after a wake while the speaker
  plays, so on/off follows `physicalSource`.
- Errors come back as HTTP 500 with a JSON body. An expired event queue is an HTTP 400
  with plain text.
- Speaker settings are plain values under `settings:/kef/host/` (`standbyMode`,
  `wakeUpSource`, `standbyDefaultVol`, `defaultVolumeGlobal`, `disableFrontStandbyLED`,
  `startupTone`, `remote/remoteIR`, `volumeStep`…). A per-input startup volume goes
  through KEF Connect's `hostlink:defaultVolume/set` action instead. The same action with
  no input is accepted but changes nothing, so the all-inputs level is written directly.
  The app reads each startup level back after writing it. Picking a sub model in KEF Connect
  also rewrites the profile's sub gain, crossover and high-pass from per-model tables
  (they depend on a KW1 wireless kit and the number of subs).
- Firmware updates follow KEF Connect: activating `firmwareupdate:checkForUpdate` makes
  `firmwareupdate:updateStatus` report `newUpdateAvailable` with the version, and
  activating `firmwareupdate:downloadNewUpdate` downloads and installs it (progress in
  `kef:fwupgrade/info`). The [homeassistant-kef](https://github.com/EvotecIT/homeassistant-kef)
  notes on these paths were a useful reference. The install step hasn't been seen live
  here yet, because there hasn't been a newer LSX II release to install.

The client falls back to plain HTTP on port 80 for older firmware that doesn't serve 4430.

## Development

```bash
swift test                        # signing vectors, JSON, requests, transport, EQ, safety
scripts/build-app.sh              # build and sign into build/ without installing
```

| Path | What |
| --- | --- |
| `Sources/KEFKit` | Protocol library: transport (HTTPS 4430 with HTTP fallback), KEF CA pinning, HMAC signing, typed values, events, EQ, Bonjour discovery. No dependencies. |
| `Sources/KEFMenuBar` | The SwiftUI app: menu bar extra, Settings, hot keys, volume overlay, icon drawing. |
| `Sources/kefctl` | The CLI above. |
| `Tests/KEFKitTests` | Swift Testing suite. The tests never touch a real speaker. |
| `scripts/build-app.sh` | Builds, signs and optionally installs the `.app`. |
| `scripts/make-icon.swift` | Renders `Resources/AppIcon.icns` from the same drawing as the menu bar icon. |
| `scripts/signing_vectors.py` | Regenerates the signing test vectors from a pykefcontrol wheel. |

If you test against your own speaker, start with read-only commands (`state`, `get`,
`rows`, `watch`) before writing anything.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
