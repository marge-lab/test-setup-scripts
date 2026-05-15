#!/usr/bin/env bash
# Lülitab GNOME ekraanisäästja, lukustuse ja idle-suspend'i välja.
# Mõeldud Linux VM-idele (Ubuntu/GNOME), mis muidu hanguvad jõude olles.
# Kasutus:  ./disable-screensaver.sh

set -u

if ! command -v gsettings >/dev/null 2>&1; then
    echo "VIGA: gsettings ei ole leitav. Kas see on GNOME töölaud?" >&2
    exit 1
fi

echo "==> Seadistan ekraanisäästja off..."
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false 2>/dev/null || true

echo
echo "==> Kontroll:"
printf '  lock-enabled            = %s\n' "$(gsettings get org.gnome.desktop.screensaver lock-enabled)"
printf '  idle-activation-enabled = %s\n' "$(gsettings get org.gnome.desktop.screensaver idle-activation-enabled)"
printf '  idle-delay              = %s\n' "$(gsettings get org.gnome.desktop.session idle-delay)"
printf '  sleep-inactive-ac-type  = %s\n' "$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type)"
printf '  idle-dim                = %s\n' "$(gsettings get org.gnome.settings-daemon.plugins.power idle-dim)"

echo
echo "Valmis. Oodatud: lock-enabled=false, idle-delay=uint32 0."
