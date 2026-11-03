# Setup

## Requirements

- Apple Silicon Mac, macOS 14 or later
- Xcode 26 and XcodeGen (`brew install xcodegen`)
- ffmpeg with `prores_videotoolbox` (`brew install ffmpeg`)
- Blackmagic Desktop Video, matching the SDK major version

## DeckLink SDK

The SDK's `Mac/include` folder is vendored in `Vendor/DeckLinkSDK`, so nothing needs downloading to build.
To build against another SDK, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set
`DECKLINK_SDK_PATH` to the folder containing `Mac/include`.

The build uses `DeckLinkAPI.h`, the `DeckLinkAPI*.h` headers it includes, `DeckLinkAPIVersion.h` and
`DeckLinkAPIDispatch.cpp`. `DeckLinkAPIDispatch.cpp` loads `/Library/Frameworks/DeckLinkAPI.framework` at
runtime, which Desktop Video installs.

## Build and run

```sh
xcodegen generate
xcodebuild -project ISORecorder.xcodeproj -scheme ISORecorder -derivedDataPath build build
build/Build/Products/Debug/ISORecorder.app/Contents/MacOS/ISORecorder
```

Pass `-synthetic 4` to start with four generated inputs. Inputs > Add Synthetic Input (⇧⌘N) adds more.
Add `-syntheticGrain YES` for realistic encoder load, and `-autoRecordSeconds 60` to record unattended.

Recordings go to `~/Movies/ISO Recorder`. Choose another folder under ISO Recorder > Settings (⌘,) > General,
or click the free-space text in the status bar. If a chosen folder is missing, for example because its drive
is unplugged, the app refuses to record rather than recreate the path on another disk.

Rename an input by double-clicking its name or right-clicking its tile, or under Settings > General.
Arm or disarm an input with the record button in its tile header, or ⌘1–⌘9 by position. Names are kept by input ID, survive
relaunches, and are used for the recording's folder and file names. Two inputs with the same name get `_2`
appended to the second one's files.

Output settings are under Settings > Output, or the codec name in the status bar.

## Control API

The app serves a small JSON API on port 9455, for Bitfocus Companion, Stream Deck actions or curl. Its
settings are under Settings > General > Remote control. The port can also be set with
`defaults write com.notandrewjones.ISORecorder controlPort -int 9000`, and 0 turns the API off.

| Request | Effect |
|---|---|
| `GET /api/v1/status` | Recording state, free space, `recordingSeconds` while recording, and each input (`label` is its name, `device` the hardware name, `index` its position) |
| `POST /api/v1/record/start` | Record All |
| `POST /api/v1/record/stop` | Stop All |
| `POST /api/v1/record/toggle` | Record All, or Stop All when recording |
| `POST /api/v1/marker` | Adds a marker. Optional body: `{"label": "Goal"}` |
| `POST /api/v1/inputs/<id>/arm` | Arms an input. While recording, it joins the session in a new segment |
| `POST /api/v1/inputs/<id>/disarm` | Disarms an input. While recording, it stops just that input |
| `POST /api/v1/inputs/<id>/toggle` | Arms or disarms an input |

Every command replies with the full status, the same as `GET /status`.

By default only this Mac can connect. **Allow control from other computers** also listens on the network,
and other computers must then send the access token shown in Settings:

```sh
curl -H "Authorization: Bearer <token>" -X POST http://<mac-address>:9455/api/v1/record/toggle
```

The token travels as plain HTTP, so only turn this on for a network you trust. Requests from this Mac need
no token. Requests carrying a browser `Origin` header, or a non-local `Host` from this Mac, are refused, so a
web page cannot control a recording.

## Bitfocus Companion

`companion-module/` is a Companion connection module, for Companion 4.3 or later. It records, arms and
disarms inputs, and lights buttons with tally, saving state and the recording time.
[companion-module/companion/HELP.md](../companion-module/companion/HELP.md) covers what it offers.

To build it, run this with Node 22 or later and corepack:

```sh
cd companion-module
corepack yarn install
corepack yarn package    # writes iso-recorder-<version>.tgz
```

In Companion's **Modules** page, import the `.tgz`. Then add an **ISO Recorder** connection and enter the
address, port and token from ISO Recorder's Settings. For development, set **Developer Modules Path** in
Companion's launcher settings to the folder that contains `companion-module`, and run `corepack yarn dev`,
which rebuilds on every change.

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

See [release.md](release.md). Release builds use the hardened runtime and are unsandboxed, with
`com.apple.security.cs.disable-library-validation` so they can load Blackmagic's framework. Debug builds
are ad-hoc signed with hardened runtime off.
