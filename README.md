# AudioPort — an Audacity-style audio editor for iOS

A native iOS (iPhone + iPad) multitrack audio editor modelled on Audacity's
workflow: record, import, select, cut/copy/paste, apply effects, undo, export.

Desktop Audacity is built on wxWidgets, PortAudio and a large C++ codebase
that does not run on iOS. This project does not try to cross-compile it.
It re-implements the same feature set with the closest iOS equivalent for each
layer:

| Desktop Audacity              | This port                                                    |
|-------------------------------|--------------------------------------------------------------|
| C++ effects (libsoundtouch, built-in effects) | `AudioDSP`: portable C11 DSP core (no dependencies, unit-tested) |
| WaveTrack / WaveClip / sample blocks | `AudioCore`: Swift value types, `Track` / `Clip`, sample-exact edits |
| UndoManager (shared sample blocks) | `History`: snapshot undo; copy-on-write arrays share unchanged audio |
| PortAudio                     | `AVAudioEngine` (streamed playback, overdub recording)       |
| libsndfile / FFmpeg import    | `AVAudioFile` (WAV, AIFF, CAF, MP3, AAC/M4A, ALAC, FLAC) + built-in WAV codec |
| wxWidgets UI                  | SwiftUI (Canvas waveforms, gestures, Swift Charts)           |
| .aup3 (SQLite)                | `.wavproj` package: JSON manifest + raw float32 per clip channel, atomic save |
| Autosave journal              | Autosave on backgrounding, recovery on launch                |
| Waveform summaries (256 / 64K) | `WaveformCache`: 256- and 65 536-sample min/max levels      |

## Features

**Editing:** multitrack mono/stereo, selection across tracks (drag edges to adjust),
cut / copy / paste / delete (ripple), silence, trim, split, join, duplicate,
insert silence, time-shift clips, labels, mix and render, unlimited-ish undo/redo (100 levels).

**Effects** (Effects menu, all with auto-generated dialogs and preview):
Amplify (with clip guard), Normalize (DC removal, independent channels), Fade In/Out
(linear, exponential, logarithmic, S-curve), Compressor, Limiter (look-ahead, never
overshoots), Noise Gate, Noise Reduction (two-step spectral subtraction with noise profile),
Bass and Treble, 10-band Graphic EQ, Filter (low/high/band-pass, notch; 12–48 dB/oct),
Echo, Change Speed (windowed-sinc resampling), Change Tempo (WSOLA, pitch preserved),
Change Pitch (tempo preserved), Truncate Silence, Repeat, Reverse, Invert.

**Generate:** Tone (sine/square/sawtooth/triangle), Noise (white/pink/brown), DTMF, Silence.

**Analyze:** Plot Spectrum (log-frequency, selectable FFT size).

**Transport:** play / pause / stop / loop selection, record with overdub and live waveform,
peak meters, playhead follow, pinch zoom, zoom to selection / fit.

**Files:** import (multiple files, auto-resampled to the project rate), export mix or
selection to WAV (16/24/32-bit PCM, 32-bit float, TPDF dither), AIFF, CAF, M4A/AAC,
Apple Lossless, FLAC; share sheet; projects in the app's Documents folder (visible in Files).

Not included yet: MP3 *export* (iOS has no MP3 encoder; would need LAME),
plugins (LV2/VST/Nyquist), spectrogram track view, envelope/draw tools, MIDI tracks.

## Layout

```
Sources/AudioDSP/     C DSP core: effects, filters, FFT, noise reduction, time stretch, generators, WAV I/O
Sources/AudioCore/    Swift model: Project, Track, Clip, editing, History, Effects catalog, Mixer, archive
Tests/AudioDSPTests/  C unit tests (run on any host with `make test`)
Tests/AudioCoreTests/ XCTest suite for the Swift model (`swift test`, macOS or Linux)
App/Sources/          SwiftUI iOS app (engine, editor model, views)
project.yml           XcodeGen spec for the iOS app target
```

## Building

### 1. What you need

- A Mac with a recent macOS and **Xcode 15.4 or later** (iOS 17 SDK). CI builds with the
  runner's default Xcode.
- To run on a phone or iPad: a device on **iOS/iPadOS 17 or later** and an **Apple ID**.
  A free Apple ID works; a paid developer account is only needed for TestFlight / App Store.
- [Homebrew](https://brew.sh), to install XcodeGen.

### 2. Set up Xcode (first time only)

1. Install Xcode from the Mac App Store and open it once so it can install its components.
2. Add the iOS platform if prompted (Xcode › Settings › Components › iOS).
3. In Terminal: `sudo xcode-select -s /Applications/Xcode.app` then `sudo xcodebuild -license accept`.
4. Add your Apple ID: Xcode › Settings › Accounts › **+** › Apple ID.

### 3. Get the code and generate the project

The Xcode project is generated from `project.yml` and is not checked in.

```sh
brew install xcodegen
git clone https://github.com/fishboyjr/Audacityport.git
cd Audacityport
xcodegen                  # writes AudioPort.xcodeproj
open AudioPort.xcodeproj
```

Run `xcodegen` again whenever you pull changes that add, remove or rename source files.
It rewrites the project, so put lasting settings in `project.yml`, not in Xcode.

### 4a. Run in the Simulator (no signing needed)

Pick the **AudioPort** scheme and an iPhone or iPad simulator in the toolbar, then press **⌘R**.
The simulator records from the Mac's microphone.

### 4b. Run on your iPhone or iPad

1. **Use your own bundle ID.** `com.example.audioport` cannot be registered. In `project.yml`,
   change `PRODUCT_BUNDLE_IDENTIFIER` to something unique such as `com.yourname.audioport`,
   and optionally add `DEVELOPMENT_TEAM: <your team ID>` on the next line so the team
   survives regeneration (Xcode › Settings › Accounts › your team shows the ID). Run `xcodegen`.
2. **Choose a team.** In Xcode select the blue **AudioPort** project › target **AudioPort** ›
   **Signing & Capabilities**, tick *Automatically manage signing*, and choose your team
   (a free account shows as "Your Name (Personal Team)").
3. **Prepare the device.** Connect it by cable, unlock it and tap *Trust*. On iOS 16+ turn on
   Settings › Privacy & Security › **Developer Mode** and restart when asked.
4. **Run.** Select the device in Xcode's toolbar and press **⌘R**.
5. **First launch on a free account:** iOS blocks the app until you trust the developer at
   Settings › General › VPN & Device Management › your Apple ID › *Trust*. Then launch again.
6. Allow microphone access when the app first records.

With a free (Personal Team) account, apps stop launching after **7 days**; run again from
Xcode to renew. A paid Apple Developer Program membership removes that limit.

### Demo project

To open the generated sample project used for screenshots: Product › Scheme › Edit Scheme ›
Run › Arguments › *Arguments Passed On Launch* › add `-demo`.

### Command-line build

```sh
xcodebuild build -project AudioPort.xcodeproj -scheme AudioPort \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

### Troubleshooting

| Problem | Fix |
|---|---|
| `xcodegen: command not found` | Install Homebrew, then `brew install xcodegen`. |
| "No such module 'AudioCore'" | File › Packages › Reset Package Caches, then build again. The package is local (this repository), so no download is needed. |
| "Failed to register bundle identifier" | The bundle ID is taken; change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and rerun `xcodegen`. |
| "Signing for AudioPort requires a development team" | Choose a team in Signing & Capabilities (step 4b.2). |
| Team or bundle ID resets after `xcodegen` | Put them in `project.yml` instead of Xcode (step 4b.1). |
| Device shows "Untrusted Developer" | Trust it under Settings › General › VPN & Device Management. |
| Device not listed in Xcode | Unlock it, accept *Trust This Computer*, enable Developer Mode, and check it runs iOS 17+. |

Tests:

```sh
make test     # C DSP core, any platform with a C compiler
swift test    # AudioCore package (macOS or Linux)
```

CI (`.github/workflows/ci.yml`) runs both suites on Linux and macOS and builds the app
for the iOS Simulator.

## Usage notes

- **Select** tool: drag on a track to select time; tap to place the cursor; drag a selection edge to adjust it.
  Tap a track header to select that track. **Move Clips** tool: drag a clip in time. **Scroll** tool: pan horizontally.
- Drag the ruler to scroll, tap it to move the playhead. Pinch to zoom.
- Noise Reduction: select noise only → Effects › Get Noise Profile → select the audio → Noise Reduction.
- Recording goes into a new track at the playhead (or selection start) while existing tracks play back.

## Licensing and naming

The code here is an original implementation written for this project; it does not copy
Audacity source code. "Audacity" is a registered trademark of Muse Group, so the app is
named *AudioPort* — keep a different name if you publish it.
