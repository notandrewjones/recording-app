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

Recordings go to `~/Movies/ISO Recorder`. Change this with
`defaults write com.notandrewjones.ISORecorder recordingRoot /path`.

## Record without the app

```sh
cd Packages/ISOCore
swift run isorec record --root /path/to/recordings --inputs 2 --seconds 30 --codec hq
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
