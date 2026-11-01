# Architecture

## Modules

| Module | Language | Depends on | Responsibility |
|---|---|---|---|
| `ISOCore` | Swift | Foundation only | Formats, timecode, ffmpeg arguments, naming, frame index, watchdog, estimates |
| `Bridge` | Objective-C++ | DeckLink SDK | Discovery, hot-plug, capture, format detection |
| `App` | Swift, Metal | ISOCore, Bridge | Capture sources, preview, UI |

`ISOCore` stays free of UI and hardware imports so that logic can be tested without either.
Recording (`CaptureEngine`, `RecorderSupervisor`) arrives in M2, and `ControlServer` in M4.

## Process model

```
App process
  DeckLink callback thread (one per input)
    ├─ copies into ring buffer (M2)
    └─ offers latest frame to PreviewFrameStore
  Writer threads → sockets → one ffmpeg child per input → fragmented MOV
```

The callback does a bounded amount of work and never touches ffmpeg, so a stalled ffmpeg can only
overflow its own ring. If the app dies, each ffmpeg sees EOF and the written fragments remain readable.

## Capture and formats

Each input starts at 1080p59.94 with format detection enabled. On a change, the callback follows the
SDK sample's sequence: pause, re-enable with the new mode, flush, restart. Capture is always v210, so
every source takes the same path whatever its detected bit depth. RGB 4:4:4 capture is not handled yet.

`CaptureSource` is implemented by DeckLink and by a synthetic source, so everything above capture runs
without hardware.

## Preview

`PreviewFrameStore` is a latest-frame mailbox. Frame counts use a separate short lock so they are exact.
The pixel copy uses try-lock and is skipped until the renderer has taken the previous frame, so preview
cannot delay capture. Each tile renders at 30 fps. The fragment shader decodes v210 or UYVY directly from
an integer texture, using nearest-neighbour sampling.

## Timeline

Every frame gets one 32-byte `.idx` record: frame number, host time, stream time, timecode, flags.

- Frame count is the timestamp. The writer fills drops with repeat frames, so file frame N is record N.
- Host time is the shared timeline, because stream time is not shared between separate cards and
  sources are free-running. A nearest-frame lookup finds "the same moment" on another angle, including
  across mixed frame rates.
- If sources are genlocked later, nothing changes. Offsets simply stay constant.

## Files

One fragmented MOV per input, with 0.5 s fragments. New segments open on signal loss, format change or
ffmpeg restart. Stop runs a lossless remux to a standard MOV for NLE compatibility.

## Phase 2 dependencies

- `.idx` must be written from the first recording milestone.
- Frame-exact file indexing, which depends on drop filling.
- A Swift `moof`/`trun` reader for byte offsets in growing files, plus VideoToolbox decode.
- Intra-only codecs on replay inputs. `Codec.isIntraOnly` exists so the UI can warn.
