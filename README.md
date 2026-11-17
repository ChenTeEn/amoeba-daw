# AMOEBA DAW

A Linux DAW preview centered on a headless Common Lisp session. The session owns the score, transport and unsaved edits. The keyboard, Lisp scripts and optional touch mixer all operate on that session. Closing the mixer leaves playback and mix edits in place.

## Quick start

Use a Linux login with a running systemd user manager. Install **SBCL, ALSA (libasound.so.2 and alsa-utils), curl, Python 3 and Git**. Chromium is needed only for the mixer or score view. Cage is optional for an active local TTY. On Debian 13, the package names are `sbcl alsa-utils libasound2t64 curl python3 git dbus-user-session` and optionally `chromium cage`.

```sh
git clone https://github.com/ChenTeEn/amoeba-daw.git
cd amoeba-daw
python3 examples/signal-rooms.py signal-rooms
bin/amoeba signal-rooms play B
bin/amoeba signal-rooms at
bin/amoeba signal-rooms stop
bin/amoeba signal-rooms session end
```

All Signal Rooms instruments and its voice-like track are synthesized by the generator; it does not read any pre-existing audio. The project path must be new. The generated WAVs are local files.

### Touch and keyboard

From a desktop session run `bin/amoeba signal-rooms mix`. On a local Wayland-capable TTY use `AMOEBA_CAGE=1 bin/amoeba signal-rooms mix`. Tap section **B** or a waveform to seek; Tab and Enter can reach the same controls. Left and Right on a focused waveform move by one beat. The **關閉混音畫面** button detaches the view. Re-run `mix` to reconnect; the playhead, playback and unsaved mix edits are still in the session. Playback can be stopped from another terminal even if Chromium crashes. The UI labels currently use Traditional Chinese.

- `at` prints seconds, section, bar, frame and revision.
- `jump B` or `seek 8.5` locates by section or seconds.
- `stems NEW-DIRECTORY` exports 48 kHz / 24-bit stereo master and stems from the saved revision.
- `session end` ends the session and discards unsaved session edits.
- Set `AMOEBA_PCM` before the first session command to select a named ALSA playback device. The default is `default`. Set `AMOEBA_PCM=null` for a silent, paced transport test.
- Set `AMOEBA_BROWSER` or `AMOEBA_CAGE_BINARY` if the tools have different executable names or need absolute paths. Or set `AMOEBA_VIEWER` to a program that opens the URL passed as its only argument, waits for its window, and closes the window when terminated.
- On NixOS, `AMOEBA_ALSA_LIBRARY` can point to your installed libasound library when the dynamic loader cannot find it. No per-machine path comes with this repository.

### Common Lisp REPL

```lisp
(load "src/score-repl.lisp")
(amoeba-repl:daw #p"signal-rooms/" "play" "B")
(amoeba-repl:daw #p"signal-rooms/" "at")
(amoeba-repl:daw #p"signal-rooms/" "stop")
```

This adapter also works in SBCL scripts. It dispatches the same named operations; scripts execute in their own process. The audio loop does not evaluate browser input or arbitrary project forms. The renderer, transport, editing and session state are implemented in Common Lisp.

On the AMOEBA Lisp Console, the Cage launcher automatically uses the console's touch ownership marker. Another compatible console can set `AMOEBA_CONSOLE_VIEW_MARKER` to its private marker path. The viewer waits for the console's sibling `touch-reading` marker to disappear before starting and releases only the marker it created. This does not change desktop-mode Chromium.

## Verify and give feedback

`tests/smoke.sh` needs a Linux user session, Xvfb, Chromium and Node.js 22+ in addition to the core dependencies. It generates the project under a temporary directory and uses the ALSA null device. It starts playback from the CLI, injects a Chromium touch event to locate B, detaches and reconnects the mixer, terminates Chromium, and verifies terminal stop. End an existing AMOEBA session first.

`tests/console-handoff.sh` checks the touch ownership handshake, viewer failure cleanup, and preservation of a marker owned by an existing viewer. It needs a POSIX shell and standard utilities only.

Public preview limitations: one active local project per user, 90-second mixer views, fixed-tempo projects, no plugins or MIDI cue scheduler, experimental ALSA capture. Capture is off by default. To opt in set `AMOEBA_CAPTURE_PCM` before starting the session; configure interface gain and headphones externally. This release includes no routing presets, measured compensation, or recordings from its development machine.

Open a [GitHub issue](https://github.com/ChenTeEn/amoeba-daw/issues/new) with your distro, the command or interaction, expected and observed state, and whether the viewer was attached. Please use the generated example when sharing reproduction steps.

License: MIT.
