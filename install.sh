#!/usr/bin/env bash
# Claudometer installer — the whole app is one plasmoid package, so this is
# just a thin wrapper around kpackagetool6 (install or upgrade as needed).
set -euo pipefail
cd "$(dirname "$0")"

ID="com.github.trixles.claudometer"

if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx "$ID"; then
    echo "Upgrading $ID..."
    kpackagetool6 -t Plasma/Applet -u plasmoid/
else
    echo "Installing $ID..."
    kpackagetool6 -t Plasma/Applet -i plasmoid/
fi

echo
echo "Done. Add it via: right-click panel → Add Widgets → Claudometer"
echo "(If upgrading, restart plasmashell to pick up changes:"
echo "  systemctl --user restart plasma-plasmashell.service)"
