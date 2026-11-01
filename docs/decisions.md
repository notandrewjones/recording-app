# Decisions log

Measurements are from an M2 Pro with 16 GB RAM and ffmpeg 8.0.1, using `tools/bench`, grainy synthetic
video, and no capture hardware. "Late" means more than one frame period late with no ring buffer.

## Transport: raw video and audio on separate Unix sockets, no NUT

| Transport | Max throughput |
|---|---|
| Named FIFO | 1.25 GB/s, below 2160p59.94 v210 at 1.33 GB/s |
| Anonymous pipe | 4.1 GB/s |
| Unix socket | 8 GB/s |

At 8 × 1080p59.94 sockets held 60.0 fps and stdin pipes 58.8 fps. Frame count acts as the timestamp, so
NUT would add a muxer to write without adding information. NUT was not benchmarked.

Constraints found in testing:

- Socket writes can return `ENOBUFS` under memory pressure. This must be retried. Treating it as fatal
  truncated a frame and corrupted the stream.
- `sun_path` is 104 bytes on macOS and long paths are silently truncated, so sockets need a short directory.
- Inputs need `-probesize 32 -analyzeduration 0`. Without them, ffmpeg took over 5 s to create the file.
- `-fflags +nobuffer` must not be used. It silently discards the first frame, confirmed by per-frame MD5,
  which would put every file one frame out against its index.
- ffmpeg paces on its slowest input, so audio and video writers must be independent.

## Capacity on the M2 Pro

| Load | Result |
|---|---|
| ProRes HQ 1080p59.94 × 4 | Clean |
| × 8 | Held 60 fps, about 5% of frames briefly late, worst write 59 ms |
| × 10 | Failed at 53.5 fps |
| ProRes HQ 2160p59.94 × 1 | Clean |
| × 2 | 104 of 958 late, startup not separated |
| HEVC 50 Mb/s 1080p59.94 × 4 | Clean |
| H.264 50 Mb/s 1080p59.94 × 4 | Failed, 1353 of 1916 late, cause not investigated |
| `prores_ks` HQ 1080p59.94 × 1 | Failed, 414 of 479 late, about 11 cores |

Each ffmpeg used 412–718 MB. At 12 streams the machine ran out of memory headroom before anything else.

## Software ProRes is opt-in

`prores_ks` cannot hold one 1080p59.94 stream, so falling back silently would replace a clear error
with dropped frames.

## Crash safety: fragmented MOV with 0.5 s fragments

`kill -9` at about 7 s left 420 frames, readable in AVFoundation with 16-channel audio and timecode
tracks. The file is readable while growing, about 0.5 s behind live. Power loss is not yet tested.

## Finalize must restate timecode

A stream copy changed `01:02:03;04` to `01:01:59:20`. The frame count survives but the drop-frame flag
does not. Restating `-timecode` preserves it.

## Field order and colour are set with `setparams`

`prores_videotoolbox` ignores `-field_order` and `-colorspace`. Set on frames with `setparams`, field
order and colour reach the file. This is confirmed from `ffprobe` tags. Whether ProRes frames are
actually coded as interlaced is not yet verified.

## Audio is limited to 2, 8 or 16 channels

ffmpeg's demuxer rejects `32c` and `64c`, and no target card exceeds 16 embedded channels.

## Free-running sources, host time as the shared timeline

Current sources are not genlocked. The model does not assume they are, and needs no changes if they are.

## The engine is a separate library with a CLI

There is no capture hardware to test with yet. Keeping the engine free of the SDK means its tests cover
gap filling, format changes, signal loss, killed and hung ffmpeg, and app crashes against real ffmpeg.

## Frame count over timestamps, with repeats for gaps

File frame N must equal index record N, or the replay timeline falls apart. Repeating the previous frame
keeps that true through short drops at the cost of a visible hold, and the index flags every repeat.

## The ring survives a recorder crash

Reusing it means frames captured but not yet written carry into the next segment. Only what ffmpeg
held in memory at the crash is lost, which is bounded by its queue and the last fragment.

## Working files are deleted only after verification

A closed segment temporarily takes twice its size during the remux. The frame count of the result must
match the working file first. This matters on a small drive, so a segment with too little room for
the copy stays as a working file rather than risking the recording.
