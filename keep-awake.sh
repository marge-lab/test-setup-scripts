#!/usr/bin/env bash
# Hoiab masina ärkvel: lülitab ekraanisäästja, lukustuse, idle-suspend'i,
# kettama-spin-down-i ja auto-hibernate'i välja. Mõeldud test-VM-idele ja
# test-masinatele, mis muidu hanguvad jõude olles.
#
# Kasutus:  ./keep-awake.sh
#
# Toetatud:
#   - Linux/GNOME (Ubuntu, Fedora) — kasutab gsettings, ei vaja sudo
#   - macOS — kasutab pmset (vajab sudo) + defaults (ei vaja sudo)
#   - Windows — kasuta selle asemel keep-awake.cmd

set -u

case "$(uname -s)" in
    Linux)
        if ! command -v gsettings >/dev/null 2>&1; then
            echo "VIGA: gsettings ei ole leitav. Kas see on GNOME töölaud?" >&2
            exit 1
        fi

        echo "==> Linux/GNOME: seadistan gsettings (ekraanisäästja off, idle-suspend off)..."
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
        ;;

    Darwin)
        if ! command -v pmset >/dev/null 2>&1; then
            echo "VIGA: pmset ei ole leitav (ootamatu macOS-il)." >&2
            exit 1
        fi

        echo "==> macOS: seadistan pmset (vajab sudo — küsib parooli)..."
        # -a = kõik power-allikad (AC + akku) korraga
        sudo pmset -a displaysleep 0  # ekraan ei lülitu välja
        sudo pmset -a sleep 0         # süsteem ei lähe sleep-i
        sudo pmset -a disksleep 0     # ketas ei lähe spin-down-i

        echo "==> Lülitan ekraanisäästja välja (defaults — ei vaja sudo)..."
        defaults -currentHost write com.apple.screensaver idleTime -int 0
        defaults write com.apple.screensaver askForPassword -int 0

        echo
        echo "==> Kontroll:"
        pmset -g | grep -E '^[[:space:]]+(displaysleep|sleep|disksleep)' | sed 's/^/  /'
        idle=$(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo '(pole määratud)')
        printf '  com.apple.screensaver idleTime = %s\n' "$idle"

        echo
        echo "Valmis. Oodatud: kõik pmset väärtused = 0, screensaver idleTime = 0."
        echo
        echo "NB! Ajutiseks ärkvel-hoidmiseks (kuni protsess jookseb, ilma sudo-ta):"
        echo "    caffeinate -dimsu"
        ;;

    *)
        echo "VIGA: toetatud on ainult Linux ja macOS." >&2
        echo "Windowsil kasuta keep-awake.cmd skripti." >&2
        exit 1
        ;;
esac
