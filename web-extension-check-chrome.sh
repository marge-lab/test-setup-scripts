#!/usr/bin/env bash
#
# Web eID brauserilaienduse versiooni-kontroll - Chrome (Load unpacked)
#
# Loeb Chrome'i "Load unpacked" abil laetud lahti-pakitud kataloogi
# sisust valja nii laienduse enda versiooni (manifest.json) kui ka bundeldatud
# lib/web-eid.js teegi versiooni (VERSION konstant koodis).
#
# Vaikimisi loeb kausta ~/Downloads/chrome/.
#
# Kasutus:
#   ./web-extension-check-chrome.sh
#   ./web-extension-check-chrome.sh /teine/path/chrome
#
# Toetab Linux + macOS. Vajab: python3 (molemad mac/linux vaikimisi).
# NB! Edge'i Linuxil/macOS-il ei testita - selleks pole eraldi sammu.
#
# Vastus uhel real, sobib otse raportisse:
#   Web eID 2.5.0 (MV3) | web-eid.js 2.1.0 | /home/<sina>/Downloads/chrome

set -e

DIR="${1:-$HOME/Downloads/chrome}"

if [ ! -d "$DIR" ]; then
    echo "VIGA: Kataloogi ei leitud: $DIR" >&2
    echo "" >&2
    echo "Kontrolli, kas Web eID Chrome'i pakk on lahti pakitud sinna." >&2
    echo "Anna teine tee argumendiga: $0 /tee/chrome" >&2
    exit 1
fi

if [ ! -f "$DIR/manifest.json" ]; then
    echo "VIGA: manifest.json puudub kataloogis $DIR" >&2
    echo "Veendu, et kataloog sisaldab lahtipakitud laienduse faile (mitte zip)." >&2
    exit 1
fi

if ! command -v python3 > /dev/null 2>&1; then
    echo "VIGA: 'python3' pole paigaldatud (vajalik manifest.json parsimiseks)." >&2
    exit 1
fi

EXTVER=$(python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" < "$DIR/manifest.json")
MVNUM=$(python3 -c "import json,sys; print(json.load(sys.stdin)['manifest_version'])" < "$DIR/manifest.json")

# Otsi bundeldatud VERSION:"x.y.z" konstandid kogu paki JS-failidest,
# valja laienduse enda versioon (jaab alles ainult lib/web-eid.js oma).
LIB=$(find "$DIR" -name '*.js' -type f -print0 2>/dev/null \
      | xargs -0 grep -oh 'VERSION:[^"]*"[0-9][0-9.]*"' 2>/dev/null \
      | sed -E 's/.*"([0-9.]+)".*/\1/' \
      | grep -v "^${EXTVER}\$" \
      | head -1)
LIB="${LIB:-?}"

echo ""
echo "Web eID $EXTVER (MV$MVNUM) | web-eid.js $LIB | $DIR"
echo ""
