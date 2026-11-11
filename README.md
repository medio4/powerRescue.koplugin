# Power-button rescue (powerwatch.koplugin)

A KOReader plugin for Kobo. Hold the power button for **3 seconds** to stop
whatever is stuck and get back to the library.

- Stops every program started from the Kobo's storage (`/mnt/onboard`): apps
  launched from KOReader, the web browser, read-along audio and TTS helpers,
  anything a plugin spawned. KOReader, its SSH server and the watchdog are kept.
- Closes the open book and returns to the library.
- If KOReader itself is frozen, it is restarted (through `koreader.sh`'s crash
  handler) and then sent back to the library.

KOReader's own "hold power to power off" moves from 2 s to 6 s so it does not
fire first, and releasing after a rescue hold does not put the device to sleep.

## How it works

A frozen KOReader can't read its own button, so the watching is done by
`powerwatch.sh`, a small shell daemon the plugin starts with `setsid`. It reads
the power key (`/dev/input/event2`, `bd71828-pwrkey` on the Clara BW) straight
from evdev. The plugin stamps `/tmp/powerwatch.heartbeat` whenever KOReader
handles a power press or resumes; if no stamp shows up within 6 s of a rescue
hold, KOReader is considered frozen.

Log: `/tmp/powerwatch.log`. Menu: Settings → Device → Power-button rescue
(turn it off, or see the watchdog status).

## Install

Copy this folder to `.adds/koreader/plugins/powerwatch.koplugin` and restart
KOReader.

Tested on a Kobo Clara BW (FW 4.46) with KOReader v2026.07.2.
