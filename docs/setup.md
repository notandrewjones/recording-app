# Setup

## Requirements

- Apple Silicon Mac, macOS 14 or later
- Xcode 26 and XcodeGen (`brew install xcodegen`)
- ffmpeg with `prores_videotoolbox` (`brew install ffmpeg`)
- Blackmagic Desktop Video, matching the SDK major version

## DeckLink SDK

The SDK is proprietary and is not in this repo.

1. Download the Desktop Video SDK from the [Blackmagic support centre](https://www.blackmagicdesign.com/support).
2. Extract it anywhere.
3. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DECKLINK_SDK_PATH` to the
   extracted folder, the one containing `Mac/include`.

The build uses these files from `Mac/include`: `DeckLinkAPI.h`, the `DeckLinkAPI*.h` headers it includes,
`DeckLinkAPIVersion.h` and `DeckLinkAPIDispatch.cpp`. Nothing from the SDK is copied or linked statically.
`DeckLinkAPIDispatch.cpp` loads `/Library/Frameworks/DeckLinkAPI.framework` at runtime, which Desktop Video installs.

## Build and run

```sh
xcodegen generate
xcodebuild -project ISORecorder.xcodeproj -scheme ISORecorder -derivedDataPath build build
build/Build/Products/Debug/ISORecorder.app/Contents/MacOS/ISORecorder
```

Pass `-synthetic 4` to start with four generated inputs. Inputs > Add Synthetic Input (⇧⌘N) adds more.
Add `-syntheticGrain YES` for realistic encoder load, and `-autoRecordSeconds 60` to record unattended.

Recordings go to `~/Movies/ISO Recorder`. Change this with
`defaults write com.notandrewjones.ISORecorder recordingRoot /path`.

Output settings are under ISO Recorder > Settings (⌘,), or the codec name in the status bar.

## Control API

The app listens on `127.0.0.1:9455`, for Bitfocus Companion's generic HTTP module, Stream Deck actions or
curl. Change the port with `defaults write com.notandrewjones.ISORecorder controlPort -int 9000`, and use 0
to turn it off. Replies are JSON.

| Request | Effect |
|---|---|
| `GET /api/v1/status` | Recording state, free space and each input |
| `POST /api/v1/record/start` | Record All |
| `POST /api/v1/record/stop` | Stop All |
| `POST /api/v1/marker` | Adds a marker. Optional body: `{"label": "Goal"}` |
| `POST /api/v1/inputs/<id>/arm` | Arms an input |
| `POST /api/v1/inputs/<id>/disarm` | Disarms an input |

It only binds to loopback, so a Companion on another machine needs it opened up first. Requests carrying a
browser `Origin` header or a non-local `Host` are refused, so a web page cannot control a recording.

## NLE exports

Each session writes `export/` when it finishes:

| File | Open in | Contains |
|---|---|---|
| `<session>.fcpxml` | Final Cut Pro, DaVinci Resolve | A multicam clip with one angle per input |
| `<session>.xml` | Premiere Pro, DaVinci Resolve | A sequence with each input on its own track, aligned |
| `<session>_<input>.edl` | Anything that reads CMX 3600 | One EDL per input |

Rerun with `isorec export <session>`, for example after moving the session folder, because exports use
absolute paths.

## Check a recording

Each session writes `health.jsonl` every 5 seconds while recording. To get a pass or fail, or a zip of logs
to send to someone, use Record > Export Diagnostics in the app, or:

```sh
cd Packages/ISOCore
swift run -c release isorec report "/path/to/session"
swift run -c release isorec diagnose "/path/to/session" --to ~/Desktop
```

See [the soak test checklist](soak-test.md).

## Record without the app

```sh
cd Packages/ISOCore
swift run -c release isorec record --root /path/to/recordings --inputs 5 --seconds 60 --grain
swift run -c release isorec record --root /path/to/recordings --encoder hevc-hw --rate cbr --kbps 30000
swift run -c release isorec record --root /path/to/recordings --encoder x264 --rate cq --quality 23
swift run isorec recover /path/to/recordings/<session>
```

## Run tests

```sh
cd Packages/ISOCore && swift test
```

## ffmpeg

The app looks for `/opt/homebrew/bin/ffmpeg`, then `/usr/local/bin/ffmpeg`. To use another build:

```sh
defaults write com.notandrewjones.ISORecorder ffmpegPath /path/to/ffmpeg
```

It refuses to record unless the build has `prores_videotoolbox`.

Bundling a static build later:

- Build with only what the app needs: `--enable-videotoolbox --enable-audiotoolbox`, the v210, rawvideo
  and PCM demuxers and decoders, `prores_ks`, and the MOV muxer.
- **LGPL build (preferred):** leave out `--enable-gpl` and `--enable-nonfree`. Ship the ffmpeg source
  offer and licence text, and run it as a separate executable, as this app already does.
- **GPL build:** the Homebrew build uses `--enable-gpl`. Distributing a GPL ffmpeg brings GPL
  obligations for that binary, so check them before shipping one with the app.
- This app does not need x264 or x265, since H.264 and HEVC use VideoToolbox.
- Sign the bundled binary with the app's Developer ID.

## Distribution notes

The app is unsandboxed. A hardened-runtime build needs
`com.apple.security.cs.disable-library-validation` so it can load Blackmagic's framework. This is not
exercised yet because the development build has hardened runtime off.
