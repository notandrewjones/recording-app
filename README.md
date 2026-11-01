# ISO Recorder

Native macOS multi-channel SDI ISO recorder for Blackmagic DeckLink and UltraStudio hardware.
Each input is recorded to its own file. Multi-angle replay is planned for phase 2.

- [Setup](docs/setup.md)
- [Architecture](docs/architecture.md)
- [Decisions log](docs/decisions.md)

```sh
xcodegen generate
xcodebuild -project ISORecorder.xcodeproj -scheme ISORecorder -derivedDataPath build build
(cd Packages/ISOCore && swift test)
```
