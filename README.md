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

Requirements: Xcode 15.4+ (iOS 17 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen                 # generates AudioPort.xcodeproj
open AudioPort.xcodeproj # choose a team for signing, run on device or simulator
```

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
