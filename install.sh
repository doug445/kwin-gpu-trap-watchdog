#!/usr/bin/bash
# Install / uninstall kwin-gpu-trap-watchdog as a systemd --user service (no root needed).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin/kwin-gpu-trap-watchdog"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/kwin-gpu-trap-watchdog.service"

if [[ ${1:-} == --uninstall ]]; then
    /usr/bin/systemctl --user disable --now kwin-gpu-trap-watchdog.service 2>/dev/null || true
    /usr/bin/rm -f "$BIN" "$UNIT"
    /usr/bin/systemctl --user daemon-reload
    echo "uninstalled (history kept in ~/.local/state/kwin-gpu-trap-watchdog/)"
    exit 0
fi

/usr/bin/install -Dm755 "$HERE/kwin-gpu-trap-watchdog.sh" "$BIN"
/usr/bin/install -Dm644 "$HERE/kwin-gpu-trap-watchdog.service" "$UNIT"
/usr/bin/systemctl --user daemon-reload
/usr/bin/systemctl --user enable --now kwin-gpu-trap-watchdog.service
/usr/bin/systemctl --user --no-pager status kwin-gpu-trap-watchdog.service | /usr/bin/head -12
