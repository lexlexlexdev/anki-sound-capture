#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

ANKI_BASE="${ANKI_BASE:-$HOME/Library/Application Support/Anki2}"
ADDONS="$ANKI_BASE/addons21"
if [[ ! -f "$ADDONS/2055492159/__init__.py" ]]; then
    echo "AnkiConnect was not found in $ADDONS. Install AnkiConnect (code 2055492159), restart Anki, and run this installer again." >&2
    echo "If you use a custom Anki data folder, set ANKI_BASE to that folder." >&2
    exit 1
fi

./build.sh
APP="$HOME/Applications/Anki Audio Capture.app"
mkdir -p "$HOME/Applications" "$ADDONS/anki_audio_capture_sync"
ditto "build/Anki Audio Capture.app" "$APP"
cp anki-addon/__init__.py anki-addon/manifest.json "$ADDONS/anki_audio_capture_sync/"
printf '\nInstalled: %s\n' "$APP"
printf 'Restart Anki to load the companion add-on, then open the app.\n'
