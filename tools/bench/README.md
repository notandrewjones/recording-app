# Transport bench

`feeder.c` paces raw frames into ffmpeg the way a capture callback would. It was used to produce the
numbers in `docs/decisions.md` and can be re-run on a new machine.

```sh
clang -O2 -o feeder feeder.c
ffmpeg -f lavfi -i "testsrc2=s=1920x1080:r=60000/1001,noise=alls=12:allf=t" -frames:v 60 \
  -pix_fmt yuv422p10le -c:v v210 -f rawvideo hd.v210

# Arguments: file frame_bytes fps seconds target paced. Target is a path, unix:path, or - for stdout.
ffmpeg -f v210 -video_size 1920x1080 -framerate 60000/1001 -listen 1 -i unix:s.sock \
  -c:v prores_videotoolbox -profile:v hq -pix_fmt p210le -realtime 1 out.mov &
sleep 0.5
./feeder hd.v210 5529600 59.94 10 unix:s.sock 1
```

Run several pairs in parallel to find a machine's limit. `late_steady` counts frames more than one
frame period late after the first 2 seconds, with no ring buffer in the path.
