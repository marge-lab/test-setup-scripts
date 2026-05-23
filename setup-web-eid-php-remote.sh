#!/bin/bash
set -e

# ============================================================
# Web eID PHP näiterakenduse paigaldus — main haru + ngrok (Linux)
#
# Kasutamine:
#   bash setup-web-eid-php-remote.sh
#
# Sarnaselt setup-web-eid-php.sh-le, kuid:
# - paigaldab ngrok-i
# - ngrok-tunnel teeb Apache HTTPS-i (port 443) internetist kättesaadavaks
# - example/src/app.conf.php origin_url uuendatakse ngrok URL-iks
# - ngrok auth token küsitakse eraldi terminaliaknas (sama muster nagu .NET)
#
# Sobib näiteks PR-i jagamiseks arendajaga kaugteel või mobiilseadmest
# testimiseks. Haru valikut ei ole — kasutab alati main-haru. Kui vajad
# konkreetset haru, kasuta setup-web-eid-php-branch-remote.sh-d.
# ============================================================

HOME_DIR="$HOME"
REPO_DIR="$HOME_DIR/web-eid-authtoken-validation-php"
EXAMPLE_DIR="$REPO_DIR/example"
APP_CONF="$EXAMPLE_DIR/src/app.conf.php"
APACHE_CONF="/etc/apache2/sites-available/web-eid-php.conf"

TOOLS_DIR="$HOME/tools"
NGROK_BIN="$TOOLS_DIR/ngrok"
NGROK_PID_FILE="$TOOLS_DIR/ngrok.pid"
NGROK_LOG="$TOOLS_DIR/ngrok.log"

echo "=== Web eID PHP näiterakendus (main + ngrok) ==="
echo "Kodukataloog: $HOME_DIR"
echo ""

mkdir -p "$TOOLS_DIR"

# Cleanup trap — vea korral tapa ngrok, eemalda token-helper
TOKEN_HELPER=""
cleanup_on_exit() {
  local rc=$?
  if [ -n "${TOKEN_HELPER:-}" ] && [ -f "$TOKEN_HELPER" ]; then
    rm -f "$TOKEN_HELPER" 2>/dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "VIGA (exit $rc) — koristame taustaprotsesse..." >&2
    if [ -f "$NGROK_PID_FILE" ]; then
      local pid
      pid=$(cat "$NGROK_PID_FILE" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
      rm -f "$NGROK_PID_FILE"
    fi
  fi
}
trap cleanup_on_exit EXIT

resolve_term_name() {
  local cmd path
  cmd=$(command -v "$1" 2>/dev/null) || return 1
  path=$(readlink -f "$cmd" 2>/dev/null || echo "$cmd")
  basename "$path"
}

# ── 1. Paketid ────────────────────────────────────────────
echo "--- [1/8] Paketid ---"
sudo apt update -q
sudo apt install -y apache2 libapache2-mod-php php-curl phpunit php-xml composer git

# ── 2. ngrok + auth token ────────────────────────────────
echo ""
echo "--- [2/8] ngrok ---"
if [ -x "$NGROK_BIN" ]; then
  echo "ngrok juba olemas"
else
  echo "Laadin ngrok..."
  wget --show-progress -O "$TOOLS_DIR/ngrok.tgz" \
    "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz"
  tar -xzf "$TOOLS_DIR/ngrok.tgz" -C "$TOOLS_DIR/"
  rm -f "$TOOLS_DIR/ngrok.tgz"
  chmod +x "$NGROK_BIN"
  echo "ngrok paigaldatud"
fi
"$NGROK_BIN" version

echo ""
echo "--- ngrok auth token ---"

TOKEN_HELPER="/tmp/ngrok-token-helper-$$.sh"
cat > "$TOKEN_HELPER" <<'HELPER_EOF'
#!/bin/bash
export PATH="__NGROK_DIR__:$PATH"
clear
cat <<'BANNER'
================================================================
 NGROK AUTH TOKEN

 Kleebi siia ngrok dashboardilt kopeeritud käsk
   (nt:  ngrok config add-authtoken 2xxxxxxxxxxxxxxxxxxxx...)
 ja vajuta Enter.

 Tokeni leiad:
   https://dashboard.ngrok.com/get-started/your-authtoken

 Pärast "Authtoken saved" sõnumit sulge see aken ja
 mine tagasi paigaldus-skripti juurde (Enter sealsamas).
================================================================
BANNER
echo
exec "${SHELL:-bash}" -i
HELPER_EOF

NGROK_DIR_REAL=$(dirname "$NGROK_BIN")
sed -i.bak "s|__NGROK_DIR__|$NGROK_DIR_REAL|" "$TOKEN_HELPER"
rm -f "$TOKEN_HELPER.bak"
chmod +x "$TOKEN_HELPER"

opened=0
for term in x-terminal-emulator gnome-terminal ptyxis konsole xfce4-terminal alacritty kitty xterm kgx; do
  if command -v "$term" >/dev/null 2>&1; then
    real_term=$(resolve_term_name "$term" || echo "$term")
    case "$real_term" in
      gnome-terminal*|ptyxis*)
        "$term" -- "$TOKEN_HELPER" >/dev/null 2>&1 &
        ;;
      kitty*)
        "$term" "$TOKEN_HELPER" >/dev/null 2>&1 &
        ;;
      *)
        "$term" -e "$TOKEN_HELPER" >/dev/null 2>&1 &
        ;;
    esac
    opened=1
    break
  fi
done

if [ "$opened" -eq 1 ]; then
  echo "Avasin uue terminali — kleebi sinna ngrok dashboardilt kopeeritud käsk."
else
  echo "Ei suutnud uut terminali automaatselt avada."
  echo "Ava ise teine terminal ja jooksuta:"
  echo "    export PATH=\"$NGROK_DIR_REAL:\$PATH\""
  echo "    <kleebi ngrok dashboardilt käsk>"
fi
echo ""
read -r -p "Vajuta Enter SIIN aknas kui token on seadistatud..." _

# ── 3. Apache seadistamine ────────────────────────────────
echo ""
echo "--- [3/8] Apache seadistamine ---"

if ! grep -q "web-eid-authtoken-validation-php" /etc/apache2/apache2.conf; then
  echo "
<Directory $REPO_DIR>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>" | sudo tee -a /etc/apache2/apache2.conf > /dev/null
  echo "Directory blokk lisatud apache2.conf-i"
else
  echo "Directory blokk juba olemas"
fi

sudo cp /etc/apache2/sites-available/default-ssl.conf "$APACHE_CONF"
sudo sed -i "s|DocumentRoot /var/www/html|DocumentRoot $EXAMPLE_DIR/public|" "$APACHE_CONF"
echo "DocumentRoot: $EXAMPLE_DIR/public"

sudo a2enmod ssl rewrite
sudo a2ensite web-eid-php.conf
chmod 755 "$HOME_DIR"

sudo -v
sudo service apache2 restart
echo "Apache taaskäivitatud"

# ── 4. Repo kloonimine (main) ─────────────────────────────
echo ""
echo "--- [4/8] Repo kloonimine (main haru) ---"
if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo juba olemas, uuendan main..."
  git -C "$REPO_DIR" checkout main 2>/dev/null || git -C "$REPO_DIR" checkout master
  git -C "$REPO_DIR" pull --ff-only
else
  git clone https://github.com/web-eid/web-eid-authtoken-validation-php.git "$REPO_DIR"
fi

# ── 5. Composer ───────────────────────────────────────────
echo ""
echo "--- [5/8] Composer sõltuvused ---"
cd "$EXAMPLE_DIR"
composer update --no-interaction

# ── 6. Sertifikaadid ──────────────────────────────────────
echo ""
echo "--- [6/8] Sertifikaadid ---"
mkdir -p "$EXAMPLE_DIR/certificates"
cd "$EXAMPLE_DIR/certificates"

wget -q -N https://c.sk.ee/esteid2018.der.crt
wget -q -N https://sk.ee/upload/files/TEST_of_ESTEID2018.der.crt
wget -q -N https://crt.eidpki.ee/ESTEID2025.crt -O ESTEID2025.der.crt
wget -q -N https://installer.id.ee/media/id2025/TestChain/TestESTEID2025.crt -O TestESTEID2025.der.crt
wget -q -N https://www.sk.ee/upload/files/TEST_of_KLASS3-SK_2016.der.crt
wget -q -N https://c.sk.ee/TEST_ORG_2021E.der.crt
wget -q -N https://c.sk.ee/TEST_ORG_2021R.der.crt
echo "Sertifikaadid allalaaditud: $(ls *.crt 2>/dev/null | wc -l) faili"

# ── 7. ngrok tunnel + app.conf.php uuendamine ─────────────
echo ""
echo "--- [7/8] ngrok tunnel + app.conf.php ---"

# Tapa vana ngrok
if [ -f "$NGROK_PID_FILE" ]; then
  old_pid=$(cat "$NGROK_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$NGROK_PID_FILE"
fi

# Apache kuulab port 443 SSL-iga (self-signed sert).
# ngrok-il tuleb öelda et tagumine ots on HTTPS (mitte vaiketüüp HTTP).
nohup "$NGROK_BIN" http https://localhost:443 --log=stdout > "$NGROK_LOG" 2>&1 &
echo $! > "$NGROK_PID_FILE"

echo "Ootan ngrok tunneli avamist..."
NGROK_URL=""
for i in $(seq 1 20); do
  NGROK_URL=$(wget -qO- --timeout=2 http://localhost:4040/api/tunnels 2>/dev/null \
    | grep -oE 'https://[^"]+\.ngrok[^"]*' | head -1 || true)
  [ -n "$NGROK_URL" ] && break
  sleep 1
done
if [ -z "$NGROK_URL" ]; then
  echo "VIGA: ngrok tunnel ei avanenud 20 sek jooksul." >&2
  tail -20 "$NGROK_LOG" >&2
  exit 1
fi
echo "Tunnel: $NGROK_URL"

# Uuenda app.conf.php — origin_url peab vastama ngrok URL-ile.
# Kui faili pole (esimene kord), loo see.
if [ ! -f "$APP_CONF" ]; then
  echo "Loon $APP_CONF (puudus)..."
  mkdir -p "$(dirname "$APP_CONF")"
  cat > "$APP_CONF" <<PHP_EOF
<?php
return [
    'origin_url' => '$NGROK_URL',
];
PHP_EOF
else
  # Asenda origin_url väärtus
  if grep -q "'origin_url'" "$APP_CONF"; then
    sed -i "s|'origin_url'[[:space:]]*=>[[:space:]]*'[^']*'|'origin_url' => '$NGROK_URL'|" "$APP_CONF"
  else
    # Kui võti puudub, kirjuta fail ümber
    cat > "$APP_CONF" <<PHP_EOF
<?php
return [
    'origin_url' => '$NGROK_URL',
];
PHP_EOF
  fi
fi
echo "app.conf.php uuendatud: origin_url = $NGROK_URL"

# ── 8. Live-logi monitooring ─────────────────────────────
echo ""
echo "--- [8/8] Live-logi monitooring ---"

LOG_TAIL_HELPER="$HOME/.web-eid-php-log-tail.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; C='\033[1;36m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid PHP + ngrok — LIVE LOGI (Apache)\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${Y}  Avalik URL:\${N}     $NGROK_URL"
echo -e "\${C}  ngrok inspector:\${N} http://127.0.0.1:4040"
echo -e "\${Y}  Logid:\${N}          /var/log/apache2/access.log + error.log"
echo ""
echo -e "\${B}  Iga päring (auth/sign/cert) ilmub allpool reaalajas.\${N}"
echo -e "\${B}  Sulge aken X-nupuga → sulgub logi-aken + ngrok.\${N}"
echo -e "\${B}  Apache JÄÄB JOOKSMA (system-teenus).\${N}"
echo -e "\${B}  (Ctrl+C ignoreeritakse — kopeerimine).\${N}"
echo -e "\${B}  NB: küsib sudo parooli (Apache logid root-omanduses).\${N}"
echo ""

# Cache sudo creds FOREGROUND-is enne kui hakkame tail-i background-i panema.
# Backgrounded sudo ei suuda terminali echo-d välja lülitada (vajab
# foreground process group ownership-i), seetõttu kuvataks parool vabalt.
echo "Apache logide lugemiseks vajalik sudo parool:"
if ! sudo -v; then
  echo ""
  echo "Sudo autentimine ebaõnnestus. Sulge aken X-nupuga."
  sleep 30
  exit 1
fi
echo ""
echo "----------------------------------------------------------------"

cleanup() {
  kill \$(jobs -p) 2>/dev/null
  [ -f "${NGROK_PID_FILE}" ] && kill \$(cat "${NGROK_PID_FILE}") 2>/dev/null
  exit 0
}
trap "" INT
trap cleanup TERM HUP

# sudo siin kasutab cached credential-eid (sudo -v ülal), parooli enam ei küsi.
sudo tail -q -n 0 -f /var/log/apache2/access.log /var/log/apache2/error.log &
wait
HELPER_EOF
chmod +x "$LOG_TAIL_HELPER"

opened_log=0
for term in x-terminal-emulator gnome-terminal ptyxis konsole xfce4-terminal alacritty kitty xterm kgx; do
  if command -v "$term" >/dev/null 2>&1; then
    real_term=$(resolve_term_name "$term" || echo "$term")
    case "$real_term" in
      gnome-terminal*|ptyxis*)
        "$term" -- "$LOG_TAIL_HELPER" >/dev/null 2>&1 &
        ;;
      kitty*)
        "$term" "$LOG_TAIL_HELPER" >/dev/null 2>&1 &
        ;;
      *)
        "$term" -e "$LOG_TAIL_HELPER" >/dev/null 2>&1 &
        ;;
    esac
    opened_log=1
    break
  fi
done

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  PAIGALDUS VALMIS                              ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║                                                                ║"
printf "║  Ava brauseris:    %-44s║\n" "$NGROK_URL"
printf "║  ngrok inspector:  %-44s║\n" "http://127.0.0.1:4040"
echo "║                                                                ║"
if [ "$opened_log" -eq 1 ]; then
  echo "║  Live logi:        AVATUD ERALDI TERMINALIAKNAS (Apache)       ║"
  echo "║                    NB! Aknas küsib sudo parooli                ║"
else
  echo "║  Live logi:        ei suutnud terminali avada                  ║"
  echo "║  Käivita käsitsi:  sudo tail -f /var/log/apache2/access.log    ║"
fi
echo "║                                                                ║"
echo "║  Peatamiseks:                                                  ║"
printf "║    kill \$(cat %s)                  ║\n" "$NGROK_PID_FILE"
echo "║    sudo systemctl stop apache2                                 ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
