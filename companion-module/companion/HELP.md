## ISO Recorder

Start and stop recording on ISO Recorder, and arm or disarm inputs, with tally on your buttons.

### Setup

In ISO Recorder, open **Settings > General > Remote control**.

- **Companion on the same Mac:** set the address to `127.0.0.1` and leave the access token empty.
- **Companion on another computer:** turn on **Allow control from other computers**. Settings then shows the
  Mac's address and an access token. Enter both here. If you press **New Token** in ISO Recorder, paste the new
  one here too.

The default port is 9455. Change it here only if you changed it in ISO Recorder.

### Actions

| Action                  | What it does                                                                          |
| ----------------------- | ------------------------------------------------------------------------------------- |
| **Record: toggle**      | Records every armed input, or stops the session                                      |
| **Record: start / stop** | The same, one way only                                                               |
| **Input: arm / disarm** | Arm, disarm or toggle one input. During a recording this punches the input in or out |
| **Add marker**          | Marks the moment for the NLE exports. The label can contain variables                 |

Punching out stops only that input. Punching back in records it into the same session as a new clip, which
the NLE exports place at its real time.

Inputs are stored by hardware ID, so buttons follow the camera when an input is renamed or the multiview
order changes. An unplugged input stays selectable and is marked "(disconnected)".

### Feedbacks

- **Recording**, **Saving** (files still being finished after a stop)
- **Input: armed**, **Input: recording** (tally), **Input: has signal** (invert it to flag a lost camera)
- **Connection lost**: ISO Recorder isn't answering. Put this last on a button so it dims instead of
  showing stale tally.

### Variables

`recording`, `finalizing`, `record_time` (HH:MM:SS), `free_space`, `connected`, `input_count`, `armed_count`,
and for each input by its position in the multiview: `input_N_name`, `input_N_armed`, `input_N_recording`,
`input_N_signal`, `input_N_format`.

### Presets

**Record / Stop** shows the running time. There is one arm button per input, which is dim red when armed,
bright red when recording, and has amber text when the input has no signal.

### Troubleshooting

- **Authentication failure:** the token doesn't match. Copy it again from ISO Recorder.
- **Connection refused:** ISO Recorder isn't running, the port is wrong, or Companion is on another computer
  and **Allow control from other computers** is off.
- The first time ISO Recorder accepts network connections, macOS may ask whether to allow them. Click
  **Allow**.
