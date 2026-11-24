# KEF Menu Bar

A native macOS menu bar app for KEF's wireless speakers on the W2 platform. It talks to
the speaker directly over your local network: no cloud, no account, no dependencies.
Built and tested on an LSX II (firmware 3.1.141) with a KC62 subwoofer. Other W2 models
(LS50 Wireless II, LS60 Wireless, LSX II LT) use the same API but are untested: the input
picker follows each model's published inputs, and reports from owners are welcome.

Not affiliated with or endorsed by KEF. "KEF" and the product names are KEF's trademarks.

- Power, volume and mute, input picker (on the LSX II: USB, Wi-Fi/AirPlay, TV, Optical, Analog,
  Bluetooth; Coaxial on models that have it)
- Now playing with artwork and transport controls while streaming (Wi-Fi / Bluetooth)
- Subwoofer level, plus a collapsible **Sound** section: treble, bass extension, desk and
  wall mode, balance, phase correction, sub crossover, speaker high-pass, sub polarity and
  output. The speaker keeps one EQ profile **per input**, and edits apply to the current one.
- Live state: changes made from the remote, the panel or other apps show up within a second
  (event-queue long-poll, reconnects with 1–30 s backoff)
- Global shortcuts (default ⌃⌥⌘↑ / ⌃⌥⌘↓ / ⌃⌥⌘M, configurable) with a small volume overlay
- Settings: Bonjour discovery or a manual IP, shortcut volume step, the speaker's maximum
  volume limit, launch at login

The menu bar icon is the app's own glyph (`SpeakerGlyph`): a bookshelf cabinet with KEF's
concentric Uni-Q driver. It is solid with a level meter while on, slashed when muted,
outlined in standby, and shows "!" when the speaker is unreachable. The app icon and the
volume overlay use the same drawing.

Volume and EQ are stored per input on the speaker. After an input change the app blocks
volume and EQ writes for about 1.5 s, until it has read the new input's own values back, so
a shortcut or slider can never apply one input's level or profile to another.

The app never resets, reboots or reconfigures the speaker's network. `KEFSafety` refuses
those paths in the client itself (factory reset, reboot, network wizard, firmware update,
pairing wipes, DSP restore…).

### Firmware updates

The speaker checks KEF's update feed itself every 4 hours, and its settings include a
silent update after about an hour idle (`settings:/fwupdate/*`). Whether silent install is
switched on can't be read from outside, so to update right away use KEF Connect. This app
never starts an update.

## Build and install

Requires macOS 14+ on Apple silicon and Xcode 16 or later (Swift 6). No prebuilt
release yet, so build it from source.

Xcode has to be the active developer directory: the Command Line Tools alone lack the
SwiftUI and Swift Testing macro plugins. If `xcode-select -p` prints
`/Library/Developer/CommandLineTools`, run `sudo xcode-select -s /Applications/Xcode.app`
or prefix `swift` commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(`scripts/build-app.sh` does this itself).

```bash
swift test                      # protocol unit tests (signing vectors, JSON, transport…)
scripts/build-app.sh --install  # build, sign, copy to ~/Applications and launch
```

The script signs with the first "Apple Development" identity in your keychain (ad-hoc if
there is none; override with `CODESIGN_IDENTITY`). On first launch macOS asks for
**Local Network** access, which the app needs to reach the speaker. It finds speakers
with Bonjour; if yours isn't found, enter its IP address in Settings.

## Layout

| Path | What |
| --- | --- |
| `Sources/KEFKit` | Protocol client: transport (HTTPS 4430 with HTTP 80 fallback), KEF CA pinning, HMAC request signing, typed values, events, EQ, Bonjour discovery. No dependencies. |
| `Sources/KEFMenuBar` | The SwiftUI app (MenuBarExtra, Settings, hot keys, overlay). |
| `Sources/kefctl` | Small CLI over KEFKit: `kefctl discover`, `kefctl <ip> state`, `volume 30`, `eq`, `watch`… |
| `Tests/KEFKitTests` | Swift Testing suite, including signatures checked against pykefcontrol's own `sign()`. |
| `scripts/signing_vectors.py` | Regenerates those vectors from the pykefcontrol wheel (`python3 -I scripts/signing_vectors.py …/pykefcontrol/_auth.py`). |
| `scripts/make-icon.swift` | Renders `Resources/AppIcon.icns`. |

## Protocol notes

The protocol follows [pykefcontrol](https://github.com/N0ciple/pykefcontrol) 1.0.1 (MIT),
which this project uses as its reference. KEFKit is a Swift port derived from it (see
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)), and the signing tests check against its `sign()`. Findings from the LSX II on firmware 3.1.141:

- Only HTTPS on 4430 is served. The certificate is issued by KEF's private CA for the
  speaker's IPs and is regenerated at boot. Port 80 is closed, and Bonjour still advertises it.
- GETs are unsigned. POSTs need the `HMAC_SHA256` header after a one-time `webserver:addUser`.
- The speaker struggles with many fresh TLS handshakes in a row, so the client keeps one
  keep-alive session.
- `settings:/kef/dsp/*` leaves mostly don't exist. EQ and sub settings are read and written as the
  whole `kef:eqProfile/v2` profile, which is per input, and so is the volume.
- `settings:/kef/host/speakerStatus` can stay `standby` after a wake while the speaker plays,
  so on/off follows `physicalSource`, like pykefcontrol's `is_on()`.
- Errors come back as HTTP 500 with a JSON body. An expired event queue is HTTP 400 with plain text.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
