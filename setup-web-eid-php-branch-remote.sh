#!/bin/bash
set -e

# ============================================================
# Web eID PHP näiterakenduse paigaldus — harutestimine + ngrok (Linux)
#
# Kasutamine:
#   bash setup-web-eid-php-branch-remote.sh                    # küsib haru
#   bash setup-web-eid-php-branch-remote.sh --branch HARU
#   bash setup-web-eid-php-branch-remote.sh --branch HARU --with-tests
#
# Sarnaselt setup-web-eid-php-branch.sh-le, kuid:
# - paigaldab ngrok-i
# - ngrok-tunnel teeb Apache HTTPS-i (port 443) internetist kättesaadavaks
# - example/src/app.conf.php origin_url uuendatakse ngrok URL-iks
# - ngrok auth token küsitakse eraldi terminaliaknas (sama muster nagu .NET)
# ============================================================

BRANCH=""
WITH_TESTS=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --branch) BRANCH="$2"; shift 2 ;;
    --with-tests) WITH_TESTS=1; shift ;;
    *) echo "Tundmatu parameeter: $1"; exit 1 ;;
  esac
done

HOME_DIR="$HOME"
REPO_DIR="$HOME_DIR/web-eid-authtoken-validation-php"
EXAMPLE_DIR="$REPO_DIR/example"
COMPOSER_JSON="$EXAMPLE_DIR/composer.json"
APP_CONF="$EXAMPLE_DIR/src/app.conf.php"
APACHE_CONF="/etc/apache2/sites-available/web-eid-php.conf"
UPSTREAM_URL="https://github.com/web-eid/web-eid-authtoken-validation-php"

TOOLS_DIR="$HOME/tools"
NGROK_BIN="$TOOLS_DIR/ngrok"
NGROK_PID_FILE="$TOOLS_DIR/ngrok.pid"
NGROK_LOG="$TOOLS_DIR/ngrok.log"

TEST_LOG="$HOME/composer-test.log"
COMPOSER_UPDATE_LOG="$HOME/composer-update.log"

echo "=== Web eID PHP harutestimine + ngrok ==="
echo "Kodukataloog: $HOME_DIR"
[ "$WITH_TESTS" -eq 1 ] && echo "Lisaks: ühiktestid (composer test)"
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
    [ -f "$COMPOSER_UPDATE_LOG" ] && echo "Vaata: tail -40 $COMPOSER_UPDATE_LOG" >&2
  fi
}
trap cleanup_on_exit EXIT

resolve_term_name() {
  local cmd path
  cmd=$(command -v "$1" 2>/dev/null) || return 1
  path=$(readlink -f "$cmd" 2>/dev/null || echo "$cmd")
  basename "$path"
}

TOTAL_STEPS=9
[ "$WITH_TESTS" -eq 1 ] && TOTAL_STEPS=10

# ── 1. Paketid ────────────────────────────────────────────
echo "--- [1/$TOTAL_STEPS] Paketid ---"
sudo apt update -q
sudo apt install -y apache2 libapache2-mod-php php-curl phpunit php-xml composer git

# ── 2. ngrok + auth token ────────────────────────────────
echo ""
echo "--- [2/$TOTAL_STEPS] ngrok ---"
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
echo "--- [3/$TOTAL_STEPS] Apache seadistamine ---"

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

# ── 4. Repo + haru valimine ───────────────────────────────
echo ""
echo "--- [4/$TOTAL_STEPS] Repo + haru valimine ---"
if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo juba olemas, uuendan..."
  git -C "$REPO_DIR" fetch --prune origin
else
  git clone "$UPSTREAM_URL.git" "$REPO_DIR"
  git -C "$REPO_DIR" fetch --prune origin
fi

ALL_BRANCHES=$(git -C "$REPO_DIR" branch -r | sed 's|origin/||' | grep -iv "HEAD" | grep -v "^\s*main\s*$" | tr -d ' ')

if [ -z "$BRANCH" ]; then
  echo "Saadaval olevad harud:"
  echo "$ALL_BRANCHES" | nl
  read -rp "Sisesta haru number (või trüki otsingusõna): " INPUT
  if [[ "$INPUT" =~ ^[0-9]+$ ]]; then
    BRANCH=$(echo "$ALL_BRANCHES" | sed -n "${INPUT}p")
  else
    BRANCH="$INPUT"
  fi
fi

MATCHES=$(echo "$ALL_BRANCHES" | grep -i "$BRANCH" || true)
# NB: ÄRA kasuta `echo "$MATCHES" | grep -c . || echo 0` mustrit. Kui
# MATCHES on tühi, grep väljastab "0" ja exit 1, siis `|| echo 0` lisab
# veel ühe "0" — tulemus "0\n0", mis lõhub `[ -eq 0 ]` võrdluse.
if [ -z "$MATCHES" ]; then
  MATCH_COUNT=0
else
  MATCH_COUNT=$(echo "$MATCHES" | grep -c .)
fi

if [ "$MATCH_COUNT" -eq 0 ]; then
  echo "VIGA: haru '$BRANCH' ei leitud. Saadaolevad harud:"
  echo "$ALL_BRANCHES"
  exit 1
elif [ "$MATCH_COUNT" -gt 1 ]; then
  echo "Leiti mitu haru, vali üks:"
  echo "$MATCHES" | nl
  read -rp "Sisesta number: " CHOICE
  BRANCH=$(echo "$MATCHES" | sed -n "${CHOICE}p")
else
  BRANCH=$(echo "$MATCHES" | head -1)
fi

echo "Valitud haru: $BRANCH"

if ! git -C "$REPO_DIR" diff --quiet HEAD; then
  echo "Stashin kohalikud muudatused (varasem skripti käivitus)..."
  git -C "$REPO_DIR" stash push -m "auto-stash $(date +%s)" >/dev/null
fi

git -C "$REPO_DIR" checkout "$BRANCH"
git -C "$REPO_DIR" pull origin "$BRANCH"
echo "Aktiivne haru: $(git -C $REPO_DIR branch --show-current)"

# ── 5. Composer.json muutmine (dev-BRANCH + repositories) ─
echo ""
echo "--- [5/$TOTAL_STEPS] composer.json: dev-$BRANCH ---"

if [ ! -f "$COMPOSER_JSON" ]; then
  echo "VIGA: $COMPOSER_JSON puudub"
  exit 1
fi

cp "$COMPOSER_JSON" "$COMPOSER_JSON.bak"

python3 - "$COMPOSER_JSON" "$BRANCH" "$UPSTREAM_URL" <<'PY'
import json, sys
path, branch, url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r") as f:
    data = json.load(f)
pkg = "web-eid/web-eid-authtoken-validation-php"
data.setdefault("require", {})
data["require"][pkg] = f"dev-{branch}"
data.setdefault("repositories", [])
# NB: "git" tüüp (mitte "vcs") — vcs+github.com kasutab GitHub API-d, mis
# nõuab autentimist ja kukub `Could not authenticate against github.com`
# veaga --no-interaction modes. "git" tüüp kasutab tavalist git clone'i,
# mis avalike repode jaoks on piisav ja API-d ei vaja.
git_url = url + ".git" if not url.endswith(".git") else url
if not any(isinstance(r, dict) and r.get("url") == git_url for r in data["repositories"]):
    data["repositories"].append({"type": "git", "url": git_url})
with open(path, "w") as f:
    json.dump(data, f, indent=4)
    f.write("\n")
PY

echo "✓ composer.json uuendatud"
echo ""
echo "--- Verify that the version was changed (git diff): ---"
git -C "$REPO_DIR" diff -- "$COMPOSER_JSON" | grep -E "^[+-].*(web-eid-authtoken-validation-php|vcs|github\.com)" | head -20 \
  || echo "HOIATUS: git diff ei näita oodatud muudatust"
echo "---"

# ── 6. Composer update ────────────────────────────────────
echo ""
echo "--- [6/$TOTAL_STEPS] composer update ---"
cd "$EXAMPLE_DIR"
if ! composer update --no-interaction > "$COMPOSER_UPDATE_LOG" 2>&1; then
  echo "VIGA: composer update kukus. Logi viimased 40 rida:" >&2
  tail -40 "$COMPOSER_UPDATE_LOG" >&2
  exit 1
fi

INSTALLED=$(grep -E "Installing|Locking" "$COMPOSER_UPDATE_LOG" \
  | grep "web-eid-authtoken-validation-php" | head -1)
echo "✓ Composer update OK"
[ -n "$INSTALLED" ] && echo "✓ Paigaldatud: $INSTALLED"

echo ""
echo "--- Versiooni- ja haru kontroll ---"
echo "    Haru:     $(git -C $REPO_DIR branch --show-current)"
echo "    Commit:   $(git -C $REPO_DIR rev-parse HEAD)"
echo "    Lühike:   $(git -C $REPO_DIR rev-parse --short HEAD)"
echo "    Pealkiri: $(git -C $REPO_DIR log -1 --pretty=format:'%s')"
echo "    Autor:    $(git -C $REPO_DIR log -1 --pretty=format:'%an <%ae>')"
echo "    Kuupäev:  $(git -C $REPO_DIR log -1 --pretty=format:'%ai')"

# ── 7. Sertifikaadid ──────────────────────────────────────
echo ""
echo "--- [7/$TOTAL_STEPS] Sertifikaadid ---"
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

# ── 8. ngrok tunnel + app.conf.php uuendamine ─────────────
echo ""
echo "--- [8/$TOTAL_STEPS] ngrok tunnel + app.conf.php ---"

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
# Sellega ngrok teeb TLS lokaali poole ja serveerib avalikku HTTPS-i.
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

# ── 9. Ühiktestid (kui --with-tests) ─────────────────────
if [ "$WITH_TESTS" -eq 1 ]; then
  echo ""
  echo "--- [9/$TOTAL_STEPS] Teegi ühiktestid ---"
  echo "NB! Testid jooksevad valitud haru ($BRANCH) lähtekoodi vastu."
  cd "$REPO_DIR"

  : > "$TEST_LOG"
  if ! composer install --no-interaction >> "$TEST_LOG" 2>&1; then
    echo "VIGA: composer install kukus. Logi viimased 30 rida:" >&2
    tail -30 "$TEST_LOG" >&2
    exit 1
  fi

  echo "Jooksutan: composer test (logi: $TEST_LOG)..."
  TEST_RC=0
  composer test >> "$TEST_LOG" 2>&1 || TEST_RC=$?

  # Statistika-rivi (Tests: 142, Assertions: 269, Failures: 1, ...)
  TEST_SUMMARY=$(tail -30 "$TEST_LOG" | grep -E "^(OK|FAILURES|ERRORS|Tests:|Time:|Memory:|There (was|were) [0-9]+ (failure|error))" | head -10)

  echo ""
  if [ "$TEST_RC" -eq 0 ]; then
    echo "================================================================="
    echo "    ✓  KÕIK ÜHIKTESTID LÄBISID"
    echo "================================================================="
    echo ""
    [ -n "$TEST_SUMMARY" ] && echo "$TEST_SUMMARY"
  else
    echo "#################################################################"
    echo "##                                                             ##"
    echo "##    ✗  ÜHIKTESTID KUKUSID  (rc=$TEST_RC)"
    echo "##                                                             ##"
    echo "#################################################################"
    echo ""
    [ -n "$TEST_SUMMARY" ] && { echo "$TEST_SUMMARY"; echo ""; }

    # Nopi kukkunud testide loend (PHPUnit format: "1) Class::method")
    FAILED_TESTS=$(grep -E "^[0-9]+\) " "$TEST_LOG" || true)
    if [ -n "$FAILED_TESTS" ]; then
      echo "Kukkunud testid:"
      echo "$FAILED_TESTS" | sed 's/^/    /'
      echo ""

      # Esimese testi method-nimi --filter argumendiks
      FIRST_METHOD=$(echo "$FAILED_TESTS" | head -1 | sed -nE 's/^[0-9]+\) .+::([a-zA-Z0-9_]+).*$/\1/p')
      if [ -n "$FIRST_METHOD" ]; then
        echo "Debug esimese kukkunud testi vastu (kopeeri ja jooksuta):"
        echo "    cd $REPO_DIR && vendor/phpunit/phpunit/phpunit --no-coverage --debug --filter $FIRST_METHOD"
        echo ""
      fi
    fi

    echo "Täielik logi vaatamiseks (ANSI värvidega):"
    echo "    less -R $TEST_LOG"

    # Ava test-logi automaatselt eraldi terminaliaknas (less -R).
    # Ainult kukkumise korral — edukal läbimisel pole vaja detaili vaadata.
    TEST_VIEWER="$HOME/.web-eid-php-test-viewer.sh"
    cat > "$TEST_VIEWER" <<HELPER_EOF
#!/bin/bash
# Composer-test logi viewer — avaneb less-iga, Q väljub.
# Akna X-nupp sulgeb akna otse (less saab SIGHUP-i).
clear
echo "Composer-test logi: ${TEST_LOG}"
echo "Haru: ${BRANCH}"
echo ""
echo "less: Q-välju  /-otsi  n-järgmine  g/G-algus/lõpp  Space/b-leht"
echo "Otsing kukkunud testile: /FAILURES  või  /^[0-9]+\\) "
echo ""
exec less -R "${TEST_LOG}"
HELPER_EOF
    chmod +x "$TEST_VIEWER"

    for term in x-terminal-emulator gnome-terminal ptyxis konsole xfce4-terminal alacritty kitty xterm kgx; do
      if command -v "$term" >/dev/null 2>&1; then
        real_term=$(resolve_term_name "$term" || echo "$term")
        case "$real_term" in
          gnome-terminal*|ptyxis*) "$term" -- "$TEST_VIEWER" >/dev/null 2>&1 & ;;
          kitty*)                  "$term" "$TEST_VIEWER" >/dev/null 2>&1 & ;;
          *)                       "$term" -e "$TEST_VIEWER" >/dev/null 2>&1 & ;;
        esac
        echo ""
        echo "→ Test-logi avatud eraldi terminaliaknas (less -R)"
        break
      fi
    done
  fi
fi

# ── Live-logi monitooring eraldi terminaliaknas ──────────
LAST_STEP=$([ "$WITH_TESTS" -eq 1 ] && echo "10" || echo "9")
echo ""
echo "--- [$LAST_STEP/$TOTAL_STEPS] Live-logi monitooring ---"

LOG_TAIL_HELPER="$HOME/.web-eid-php-log-tail.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; M='\033[1;35m'; C='\033[1;36m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid PHP HARU + ngrok — LIVE LOGI (Apache)\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${M}  Haru:\${N}            $BRANCH"
echo -e "\${M}  Commit:\${N}          $(git -C $REPO_DIR rev-parse --short HEAD)"
echo ""
echo -e "\${Y}  Avalik URL:\${N}     $NGROK_URL"
echo -e "\${C}  ngrok inspector:\${N} http://127.0.0.1:4040"
echo -e "\${Y}  Logid:\${N}          /var/log/apache2/access.log + error.log"
echo ""
echo -e "\${B}  Iga päring (auth/cert) ilmub allpool reaalajas.\${N}"
echo -e "\${B}  Sulge aken X-nupuga → sulgub logi-aken + ngrok.\${N}"
echo -e "\${B}  Apache JÄÄB JOOKSMA (system-teenus).\${N}"
echo -e "\${B}  (Ctrl+C ignoreeritakse — kopeerimine).\${N}"
echo -e "\${B}  NB: küsib sudo parooli (Apache logid root-omanduses).\${N}"
echo ""
echo "----------------------------------------------------------------"

cleanup() {
  kill \$(jobs -p) 2>/dev/null
  [ -f "${NGROK_PID_FILE}" ] && kill \$(cat "${NGROK_PID_FILE}") 2>/dev/null
  exit 0
}
trap "" INT
trap cleanup TERM HUP

sudo tail -n 0 -f /var/log/apache2/access.log /var/log/apache2/error.log &
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
printf "║  Haru:             %-44s║\n" "$BRANCH"
printf "║  Commit:           %-44s║\n" "$(git -C $REPO_DIR rev-parse --short HEAD)"
echo "║                                                                ║"
printf "║  Ava brauseris:    %-44s║\n" "$NGROK_URL"
printf "║  ngrok inspector:  %-44s║\n" "http://127.0.0.1:4040"
echo "║                                                                ║"
if [ "$WITH_TESTS" -eq 1 ]; then
  printf "║  Ühiktestid logi:  %-44s║\n" "$TEST_LOG"
  echo "║                                                                ║"
fi
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
