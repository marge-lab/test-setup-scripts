#!/usr/bin/env bash
#
# Web eID brauserilaienduse versiooni-kontroll - Firefox (Temporary Add-on)
#
# Loeb Firefoxi Temporary Add-on'ina laetud paki sisust valja nii laienduse
# enda versiooni (manifest.json) kui ka bundeldatud lib/web-eid.js teegi
# versiooni (VERSION konstant koodis). Vaikimisi loeb faili ~/Downloads/firefox.zip.
#
# Kasutus:
#   ./web-extension-check-firefox.sh
#   ./web-extension-check-firefox.sh /teine/path/firefox.zip
#
# Toetab Linux + macOS. Vajab: unzip, python3 (molemad mac/linux vaikimisi).
#
# Vastus uhel real, sobib otse raportisse:
#   Web eID 2.5.0 (MV2) | web-eid.js 2.1.0 | /home/<sina>/Downloads/firefox.zip

set -e

ZIP="${1:-$HOME/Downloads/firefox.zip}"

if [ ! -f "$ZIP" ]; then
    echo "VIGA: Faili ei leitud: $ZIP" >&2
    echo "" >&2
    echo "Kontrolli, kas Web eID Firefoxi pakk (zip) on alla laetud." >&2
    echo "Anna teine tee argumendiga: $0 /tee/firefox.zip" >&2
    exit 1
fi

if ! command -v unzip > /dev/null 2>&1; then
    echo "VIGA: 'unzip' pole paigaldatud (vajalik zip-i avamiseks)." >&2
    echo "  Ubuntu/Debian: sudo apt install unzip" >&2
    echo "  Fedora/RHEL:   sudo dnf install unzip" >&2
    echo "  macOS:         juba sees (kui mitte, brew install unzip)" >&2
    exit 1
fi

if ! command -v python3 > /dev/null 2>&1; then
    echo "VIGA: 'python3' pole paigaldatud (vajalik manifest.json parsimiseks)." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$ZIP" -d "$TMP"

if [ ! -f "$TMP/manifest.json" ]; then
    echo "VIGA: manifest.json puudub paki seest." >&2
    exit 1
fi

EXTVER=$(python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" < "$TMP/manifest.json")
MVNUM=$(python3 -c "import json,sys; print(json.load(sys.stdin)['manifest_version'])" < "$TMP/manifest.json")

# Otsi bundeldatud VERSION:"x.y.z" konstandid kogu paki JS-failidest,
# valja laienduse enda versioon (jaab alles ainult lib/web-eid.js oma).
LIB=$(find "$TMP" -name '*.js' -type f -print0 2>/dev/null \
      | xargs -0 grep -oh 'VERSION:[^"]*"[0-9][0-9.]*"' 2>/dev/null \
      | sed -E 's/.*"([0-9.]+)".*/\1/' \
      | grep -v "^${EXTVER}\$" \
      | head -1)
LIB="${LIB:-?}"

echo ""
echo "Web eID $EXTVER (MV$MVNUM) | web-eid.js $LIB | $ZIP"
echo ""
