# kwin-gpu-trap-watchdog

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Free and open source](https://img.shields.io/badge/Free%20and%20open%20source-brightgreen.svg)](LICENSE)
[![Platform: MacBookPro11,3](https://img.shields.io/badge/platform-MacBook%20Pro%2011%2C3%20%2B%20nouveau-lightgrey.svg)](#the-bug)

Recover a frozen Plasma Wayland session on nouveau (GK107 / GT 750M, MacBookPro11,3)
without a hard poweroff.

## The bug

After minutes to hours, the screen freezes. Parts of the panel and the cursor disappear,
but audio keeps playing. The kernel log floods with hundreds of these per second:

```
nouveau 0000:01:00.0: gr: TRAP ch 3 [007f904000 kwin_wayland[2816]]
nouveau 0000:01:00.0: gr: GPC0/PROP trap: 00000080 [ZETA_STORAGE_TYPE_MISMATCH] ... storage type = fe
```

KWin's depth/stencil (zeta) render target ends up with storage type 0xfe, the color
fallback, so every draw traps. The rest of the system stays alive.

- **Since:** started with the switch to Plasma Wayland on 2026-11-11. Months of `kwin_x11`
  boots show essentially zero of these traps.
- **Not caused by:** the re-clock governor; pstate held at 0a with no change before any
  episode.
- **Upstream status:** no fix found. Same trap reported on Kepler under kwin_x11 and GNOME
  ([fdo #92922](https://bugs.freedesktop.org/show_bug.cgi?id=92922)).

## What this does

This user service follows `journalctl -k -f` for `gr: TRAP ... kwin_wayland[PID]`.
When it sees ≥150 traps within 5 s from one PID:

1. **Stage 1:** it sends `SIGKILL` to `kwin_wayland`. `kwin_wayland_wrapper` sees a non-zero
   exit and respawns KWin through its crash path, up to 10 times. Qt/KDE apps reconnect
   (`QT_WAYLAND_RECONNECT=1`). GTK apps such as gnome-terminal and Firefox close.
2. **Stage 2:** if no KWin stays up for 10 s within 30 s, it runs
   `loginctl terminate-session`. That brings back the SDDM login screen with a fresh
   compositor. All apps are lost, but there's no hard power-off.
3. On success it shows a desktop notification. Every event is logged to
   `~/.local/state/kwin-gpu-trap-watchdog/recoveries.log`.

It acts once per kwin PID. After 4 recoveries in an hour, it goes straight to stage 2.
Set `SKIP_RESPAWN=1` to always go straight to stage 2.

### Do not use SIGHUP to the wrapper (v1, failed live test 2026-11-21)

`SIGHUP` calls `KWinWrapper::restart()`. That disconnects the wrapper's crash-respawn
handler and never reconnects it. On this machine the replacement kwin segfaulted 0.4 s
after starting: `libkwin.so.6.8.3`, segfault at 0x178, legacy modesetting on nouveau
card0. With the handler gone nothing restarted it, so there was no compositor and the
machine needed a hard reboot.

## Install / remove

```
./install.sh               # ~/.local/bin + systemd --user unit, enabled for graphical-session
./install.sh --uninstall
```

No root needed: the user is in `wheel`, so it can read the kernel journal.

## Tuning

Put overrides in `~/.config/kwin-gpu-trap-watchdog.conf`:

```
THRESH=150 WINDOW=5 KILL_AFTER=6 MAX_PER_HOUR=4 DRY_RUN=0
```

## Testing

Dry-run against saved log lines:

```
DRY_RUN=1 TEST_INPUT=traps.txt ./kwin-gpu-trap-watchdog.sh
```

## Watch

```
journalctl --user -fu kwin-gpu-trap-watchdog
```

## Live test result (v2, 2026-11-21 21:20) — PASSED, stage 1

- **Kill:** watchdog sent `SIGKILL` to kwin 2815.
- **Respawns:** the wrapper respawned KWin 3 times and each segfaulted, same
  `libkwin` bug at 0x178. The 4th (12839) came up about 2.3 s after the kill and
  was stable at 10 s.
- **Result:** session kept, plasmashell restarted on its own, stage 2 not needed.

**Crash budget:** the wrapper quits once its crash count goes over 10. The count
is per login and is not reset by a successful restart, only by KWin exit code 133.
Each recovery costs about 4 (1 kill plus about 3 segfaults). So about 2 in-place
recoveries per login, then the next one ends the session (SDDM). A logout/login
resets it.

## See also

Also made for the MacBook Pro 11,3 on Linux (nouveau, Plasma 6):

- [mbp113-kernel73-kit](https://github.com/doug445/mbp113-kernel73-kit): fixes what Linux 7.3 broke, quiet and tinny speakers (CS4208 pin regression) and fan control (applesmc hwmon move).
- [mbp-resume-fix](https://github.com/doug445/mbp-resume-fix): fixes the CPU stuck at 800 MHz and fans that stop responding after suspend/resume.
- [matrixrain-plasma6](https://github.com/doug445/matrixrain-plasma6): a Matrix rain wallpaper for Plasma 6, with the glow removed and animation that stops while a maximized window covers it.

## License

MIT, see [LICENSE](LICENSE).
