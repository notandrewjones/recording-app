---
target: main user interface (multiview window)
total_score: 25
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/andrewjones/Desktop/Business/recording-app/App/ISORecorderApp.swift"
target_fingerprint: "sha256:d61df75909e024ec8b4fb67c0dfea4ea818c55432d8e27096a4373e79f6808c1"
target_path: /Users/andrewjones/Desktop/Business/recording-app/App/ISORecorderApp.swift
timestamp: 2026-11-03T21-12-01Z
slug: app-isorecorderapp-swift
closed: true
---
Method: design review only (detector not applicable, native platform)

## Design Health Score
| # | Heuristic | Score | Key Issue |
|---|---|---|---|
| 1 | Visibility of System Status | 2 | No session clock; punched-out input shown only by missing border; ⌘M markers give no feedback |
| 2 | Match System / Real World | 3 | Broadcast conventions strong; footer jargon (seg 1 · 570 f, rpt, unlabeled load bar) |
| 3 | User Control and Freedom | 3 | Punch-out confirm + quit guard good; stray idle click disarms silently |
| 4 | Consistency and Standards | 2 | Status-bar buttons look like text; same red for ARMED and REC |
| 5 | Error Prevention | 3 | Missing-drive check good; idle "5m 36s left" shown neutral grey |
| 6 | Recognition Rather Than Recall | 1 | No record/stop/marker control in window; ⌘R must be known; rename right-click only |
| 7 | Flexibility and Efficiency | 3 | ⌘R, ⌘M, Companion API; no per-input arm shortcuts |
| 8 | Aesthetic and Minimalist Design | 3 | Picture-first; flat 11-item status bar |
| 9 | Error Recovery | 3 | Copy is specific; placement is 11pt grey at bottom edge |
| 10 | Help and Documentation | 2 | Empty-state hint, a few tooltips; footer readouts unexplained |
| Total | | 25/40 | Acceptable |

Cognitive load: moderate (3/8 fail: visual hierarchy, working memory, progressive disclosure).

## Design Specificity Verdict
Specific to broadcast multiview (tally border, REC badge, mono timecode), but all chrome is uniform 11-12pt mono on 65% black: reads as a debug overlay on a monitor, not a recorder. Recorder-critical signals get no more weight than SDK version. Deterministic scan: not applicable (native platform).

## Priority Issues
- [P1] No visible transport or session clock. Hidden-titlebar strip is empty. Fix: transport bar with Record/Stop, large elapsed timer, Marker button with confirmation, "3 of 4 recording", time left. Command: /impeccable layout
- [P1] Not-recording inputs signalled by absence; ARMED red label on every default tile. Fix: label the exception — dim + amber NOT RECORDING / OFF chip; drop ARMED; status "3 of 4 recording". Command: /impeccable clarify
- [P1] Failures/risk in 11pt grey at bottom; idle time-left never coloured (storageLevel forced .ok). Fix: persistent banner over grid; time-left thresholds (amber <30m, red <10m); transport flashes on failed start. Command: /impeccable harden
- [P2] Whole tile is a single-click arm toggle, idle disarm unconfirmed; tiles not keyboard/VoiceOver accessible. Fix: explicit arm chip in header, ⌘1–⌘8, accessibility labels. Command: /impeccable harden
- [P2] Flat status bar; codec and disk are hidden buttons; driver version and MEM permanent. Fix: group, show driver only on problem, hover affordance. Command: /impeccable distill

## Persona Red Flags
- Alex: no elapsed time; ⌘M silent; no per-input arm shortcuts.
- Jordan: red ARMED reads as recording; no record button; failure text in grey at bottom.
- Sam: tiles unfocusable ZStack+onTapGesture; signal dot colour-only when good.

## Minor Observations
- Footer: replace frame count with per-input duration; seg only when >1; load bar only when strained.
- Idle storage estimate is worst-case (5m36s idle vs 26m53s live on bars); mark as estimate.
- Overlay type fixed 12pt; scale with tile size.
- Grid ceil(sqrt(n)) leaves empty quadrant at 3 inputs; pick columns by area for window aspect.
- EmptyInputsView ignores driverStatus.
- Synthetic input commands ship in Inputs menu.
- Rename only via right-click.
- No per-input audio presence indicator (needs engine levels).

## Questions to Consider
- What if the clock and Record button were the largest elements on screen?
- Should a non-recording angle be the loudest thing on screen during a session?
- Does an operator ever need the SDK version mid-show?
