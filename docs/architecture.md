# Architecture

## Modules

| Module | Language | Depends on | Responsibility |
|---|---|---|---|
| `ISOCore` | Swift | Foundation only | Formats, timecode, ffmpeg arguments, naming, frame index, watchdog, estimates |
| `Bridge` | Objective-C++ | DeckLink SDK | Discovery, hot-plug, capture, format detection |
| `ISOEngine` | Swift | ISOCore, ffmpeg | Ring buffers, socket writers, segment and session recording, recovery |
| `isorec` | Swift | ISOEngine | Headless recorder for testing and soak runs |
| `App` | Swift, Metal | ISOCore, ISOEngine, Bridge | Capture sources, preview, UI |

`ISOCore` and `ISOEngine` stay free of UI and hardware imports. The engine's tests run real ffmpeg
against synthetic sources, so everything except the capture card is tested end to end.
`ControlServer` arrives in M4.

## Process model

```
App process
  DeckLink callback thread (one per input)
    ├─ InputRecorder.ingest copies into FrameRing
    └─ offers latest frame to PreviewFrameStore
  SegmentRecorder video and audio threads → sockets → one ffmpeg child per input → fragmented MOV
  InputRecorder queue: runs RecorderWatchdog, monitors output growth, updates session.json
  Finalizer queue: remuxes closed segments one at a time
```

The callback does a bounded amount of work and never touches ffmpeg, so a stalled ffmpeg can only
overflow its own ring. If the app dies, each ffmpeg sees EOF and the written fragments remain readable.

## Recording

`FrameRing` is preallocated memory, about 1 s per input, with independent video and audio readers.
If it fills, or the source skips frames, the writers repeat the previous frame and write matching silence.
So a file always has one frame per frame of real time, and repeats are flagged in the index.

A gap longer than 2 s is too long to fill and starts a new segment instead. So does a backwards jump.

`RecorderWatchdog` is a pure state machine, and `InputRecorder` carries out its decisions:

| Event | Result |
|---|---|
| ffmpeg exits | New segment after backoff. The ring survives, so unwritten frames carry over |
| No output growth with frames queued | ffmpeg is killed, then as above |
| Signal lost, or no frames for 1 s | Segment closes and the next opens when signal returns |
| Format change | Segment closes and the next opens immediately in the new format |
| Five failures in a row | Input goes to failed. Other inputs are unaffected |

Stopping closes the ring, the writers drain it, and ffmpeg exits on EOF.

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

One fragmented `<input>_0001.part.mov` per segment, with 0.5 s fragments. When a segment closes, the
finalizer remuxes it losslessly to `<input>_0001.mov`, checks the frame count matches, and only then deletes
the working file. If that fails or there is not enough disk, the working file stays and is marked in
`session.json`. Every 2 s the working file and index are flushed to the drive with `F_FULLFSYNC`.

Each segment also has an `.idx` and an ffmpeg `.log`. `session.json` is replaced atomically on each change.

On launch, the app finds sessions with unfinalized segments and finishes them. `isorec recover DIR`
does the same from the command line. A session folder holds everything recovery needs.

## Phase 2 dependencies

- `.idx` must be written from the first recording milestone.
- Frame-exact file indexing, which depends on drop filling.
- A Swift `moof`/`trun` reader for byte offsets in growing files, plus VideoToolbox decode.
- Intra-only codecs on replay inputs. `Codec.isIntraOnly` exists so the UI can warn.
