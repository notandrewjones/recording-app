# Soak test checklist

Run this before trusting a machine or a capture setup on a real job. Allow about 3 hours.

A passing soak shows that this Mac, these cards and these settings held up for the length of the test.
Repeat it whenever any of those change.

## Before you start

- [ ] Desktop Video and the DeckLink SDK are the versions in `docs/setup.md`.
- [ ] All inputs show the right format and picture, with timecode where the source provides it.
- [ ] Sources are real cameras or a generator with movement. Static bars understate the encoder load.
- [ ] Each input's output settings are the ones you will use on the job.
- [ ] No warnings show in the status bar or in Settings.
- [ ] The drive has room for the whole test, plus one segment for finalizing. Check GB/hour in Settings.
- [ ] Energy settings will not sleep the Mac. The MacBook is on mains power, with the lid open. Run `pmset -g batt` to confirm, because a run on battery says nothing about the recorder once the charge gets low.
- [ ] Close other apps, or leave open what will really be open on the job.
- [ ] Note the chassis, cables and Thunderbolt ports in use.

## Part 1: endurance, 2 hours or more

Leave everything running. Don't touch the Mac.

1. Press Record All (⌘R), and note the time.
2. Add a marker (⌘M) at the start, about halfway and at the end.
3. Check at 5 minutes, 1 hour and the end:
   - [ ] Load bars stay near empty.
   - [ ] No input shows `rpt`, `gap` or `restart`.
   - [ ] CPU and memory in the status bar are steady, not climbing.
   - [ ] Time left on the drive is falling at the rate you expected.
4. Press Stop All, and wait for FINALIZING to clear.

## Part 2: faults, about 20 minutes

Record again, and do these one at a time. Between each, confirm that every other input carried on with no
new `rpt`, `gap` or `restart`.

- [ ] Unplug one SDI input for 30 seconds, then plug it back. The tile shows NO SIGNAL and resumes.
- [ ] Power-cycle a camera.
- [ ] Change one source's format, for example 1080p59.94 to 1080i59.94 or 1080p29.97. The tile follows it.
- [ ] Unplug the UltraStudio's Thunderbolt cable for 30 seconds, then reconnect it. Its tile goes and returns.
- [ ] Find an input's ffmpeg with `pgrep -lf ffmpeg` and kill it with `kill -9 <pid>`. It restarts by itself.
- [ ] Force quit the app while recording, reopen it, and confirm the status bar reports recovered segments.
- [ ] Optional, on a test drive only: cut power to the Mac while recording, then check how much survived.

Each fault should appear in `session.json`, and each new segment should start cleanly.

## Part 3: check the footage

- [ ] Every recorded file plays, with sound, and shows no `.part.mov` left behind.
- [ ] Timecode in an NLE matches the source.
- [ ] Open `export/` in your NLE, and confirm the angles line up on a clap or a flash.
- [ ] Check long-recording sync at the end of the longest file: the same clap or flash lines up there too.
- [ ] Check 16-channel audio routes as expected, if you use it.

## Pass or fail

For the session folder, run:

```sh
cd Packages/ISOCore
swift run -c release isorec report "/path/to/session"
```

Or use Record > Export Diagnostics in the app, and read `report.txt` in the zip.

| Result | Meaning |
|---|---|
| `FAIL` | Repeated frames, lost frames, a recorder failure, an unfinished segment, or clock drift over 2 frames |
| `WARN` | Ring reached 90%, memory grew over 15% in the run, memory pressure hit critical, or signal was lost |

Part 2 produces `FAIL` lines on purpose, because a killed ffmpeg is a recorder failure. Only Part 1 has to be
clean. In Part 2, check that the failures are the ones you caused, on the inputs you caused them.

If a session fails, send the diagnostics zip. It holds logs, health samples and system details, and never media.
It does include file paths from this Mac, so check it before sharing it publicly.
