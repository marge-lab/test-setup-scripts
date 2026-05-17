#!/usr/bin/env bash
# Web eID Java näiterakenduse paigaldus
# Toetatud: Linux ja macOS (x86_64 / arm64). Windowsil ei tööta.
#
# Kasutus:
#   ./setup-web-eid-java.sh [REPO_DIR] [TOOLS_DIR]
# Vaikimisi:
#   REPO_DIR  = $HOME/projects/web-eid
#   TOOLS_DIR = $HOME/tools

set -euo pipefail

SCRIPT_VERSION="2.2"
REPO_DIR="${1:-${REPO_DIR:-$HOME/projects/web-eid}}"
TOOLS_DIR="${2:-${TOOLS_DIR:-$HOME/tools}}"

# --- Platvormi detektsioon -----------------------------------
case "$(uname -s)" in
  Linux)  OS_ADOPT=linux; NGROK_OS=linux;  NGROK_EXT=tgz ;;
  Darwin) OS_ADOPT=mac;   NGROK_OS=darwin; NGROK_EXT=zip ;;
  *)
    echo "VIGA: toetamata OS '$(uname -s)'. Skript töötab ainult Linuxil ja macOS-il." >&2
    exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ADOPT_ARCH=x64;     NGROK_ARCH=amd64 ;;
  arm64|aarch64) ADOPT_ARCH=aarch64; NGROK_ARCH=arm64 ;;
  *)
    echo "VIGA: toetamata arhitektuur '$(uname -m)'." >&2
    exit 1 ;;
esac

DEV_YAML="$REPO_DIR/example/src/main/resources/application-dev.yaml"
NGROK_BIN="$TOOLS_DIR/ngrok"
NGROK_PID_FILE="$TOOLS_DIR/ngrok.pid"
APP_PID_FILE="$TOOLS_DIR/app.pid"
BUILD_LOG="$TOOLS_DIR/build.log"
APP_LOG="$TOOLS_DIR/app.log"
NGROK_LOG="$TOOLS_DIR/ngrok.log"

echo "=== Web eID Java näiterakenduse paigaldus (v$SCRIPT_VERSION, $(date +%Y-%m-%d)) ==="
echo "Platvorm:  $OS_ADOPT/$ADOPT_ARCH"
echo "REPO_DIR:  $REPO_DIR"
echo "TOOLS_DIR: $TOOLS_DIR"
echo "NB! Sudo ei ole vajalik — kõik paigaldatakse kodukataloogi."
echo ""

mkdir -p "$TOOLS_DIR" "$(dirname "$REPO_DIR")"

# --- HTTP allalaadimine: curl või wget -----------------------
# Mõlema toetamine tähendab, et minimaalse Ubuntu installi peal
# (kus curl-i sageli pole, aga wget on) ei pea kasutaja midagi
# eraldi paigaldama.
if command -v curl >/dev/null 2>&1; then
  HTTP_TOOL="curl"
  http_download() { curl -L --fail --progress-bar -o "$1" "$2"; }
  http_get() { curl -s --max-time "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then
  HTTP_TOOL="wget"
  http_download() { wget --show-progress -q -O "$1" "$2"; }
  http_get() { wget -q --timeout="$1" --tries=1 -O - "$2"; }
else
  echo "VIGA: ei curl ega wget pole paigaldatud — ühte neist on vaja allalaadimisteks." >&2
  echo "Paigalda üks neist (näiteks): sudo apt install -y curl" >&2
  echo "                          või: sudo apt install -y wget" >&2
  exit 1
fi
echo "HTTP tööriist: $HTTP_TOOL"

# --- Cleanup -------------------------------------------------
TOKEN_HELPER=""
cleanup_on_exit() {
  local rc=$?
  # Ajutise ngrok-token abi-skripti eemaldamine
  if [ -n "${TOKEN_HELPER:-}" ] && [ -f "$TOKEN_HELPER" ]; then
    rm -f "$TOKEN_HELPER" 2>/dev/null || true
  fi
  # Vigade puhul tapame taustaprotsessid
  if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "VIGA (exit $rc) — koristame taustaprotsesse..." >&2
    for pf in "$NGROK_PID_FILE" "$APP_PID_FILE"; do
      if [ -f "$pf" ]; then
        local pid
        pid=$(cat "$pf" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pf"
      fi
    done
  fi
}
trap cleanup_on_exit EXIT

# --- [1/7] JDK 17 --------------------------------------------
echo "--- [1/7] JDK 17 ---"
JDK_DIR=$(ls -d "$TOOLS_DIR"/jdk-17.* 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$JDK_DIR" ] && [ -d "$JDK_DIR" ]; then
  echo "JDK 17 juba olemas: $(basename "$JDK_DIR"), vahele jätan"
else
  echo "Laadin uusima JDK 17 GA versiooni Adoptium-ist ($OS_ADOPT/$ADOPT_ARCH)..."
  http_download "$TOOLS_DIR/jdk17.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/17/ga/$OS_ADOPT/$ADOPT_ARCH/jdk/hotspot/normal/eclipse"
  tar -xzf "$TOOLS_DIR/jdk17.tar.gz" -C "$TOOLS_DIR/"
  rm -f "$TOOLS_DIR/jdk17.tar.gz"
  JDK_DIR=$(ls -d "$TOOLS_DIR"/jdk-17.* | sort -V | tail -1)
  echo "JDK 17 paigaldatud: $(basename "$JDK_DIR")"
fi

# macOS-il on JDK Contents/Home all
if [ "$OS_ADOPT" = "mac" ]; then
  export JAVA_HOME="$JDK_DIR/Contents/Home"
else
  export JAVA_HOME="$JDK_DIR"
fi
export PATH="$JAVA_HOME/bin:$PATH"

# rc-failide värskendamine — unikaalne markeri-blokk, vana eemaldatakse
RC_BEGIN="# >>> web-eid-java-setup JAVA_HOME >>>"
RC_END="# <<< web-eid-java-setup JAVA_HOME <<<"
update_rc_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  if grep -qF "$RC_BEGIN" "$file"; then
    awk -v b="$RC_BEGIN" -v e="$RC_END" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi
  cat >> "$file" <<EOF
$RC_BEGIN
export JAVA_HOME="$JAVA_HOME"
export PATH="\$JAVA_HOME/bin:\$PATH"
$RC_END
EOF
  echo "JAVA_HOME värskendatud failis $file"
}
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  update_rc_file "$rc"
done

java -version 2>&1 | head -1

# --- [2/7] ngrok ---------------------------------------------
echo ""
echo "--- [2/7] ngrok ---"
if [ -x "$NGROK_BIN" ]; then
  echo "ngrok juba olemas"
else
  DL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$NGROK_OS-$NGROK_ARCH.$NGROK_EXT"
  echo "Laadin ngroki: $DL"
  http_download "$TOOLS_DIR/ngrok.$NGROK_EXT" "$DL"
  if [ "$NGROK_EXT" = "tgz" ]; then
    tar -xzf "$TOOLS_DIR/ngrok.tgz" -C "$TOOLS_DIR/"
  else
    if ! command -v unzip >/dev/null 2>&1; then
      echo "VIGA: unzip puudub (vajalik macOS-i .zip pakendi jaoks)." >&2
      exit 1
    fi
    unzip -oq "$TOOLS_DIR/ngrok.zip" -d "$TOOLS_DIR/"
  fi
  rm -f "$TOOLS_DIR/ngrok.$NGROK_EXT"
  chmod +x "$NGROK_BIN"
  echo "ngrok paigaldatud"
fi
"$NGROK_BIN" version

# --- [3/7] ngrok auth token ----------------------------------
echo ""
echo "--- [3/7] ngrok auth token ---"

# Kirjuta ajutine abi-skript, mille uus terminal käivitab.
# PATH on seatud, et ngrok-i käib kasutada ilma full-path-ita.
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
# Pane ngrok-i kataloog skripti sisse (sed -i.bak portatiivne)
NGROK_DIR_REAL=$(dirname "$NGROK_BIN")
sed -i.bak "s|__NGROK_DIR__|$NGROK_DIR_REAL|" "$TOKEN_HELPER"
rm -f "$TOKEN_HELPER.bak"
chmod +x "$TOKEN_HELPER"

opened=0
if [ "$OS_ADOPT" = "mac" ]; then
  if osascript \
       -e "tell application \"Terminal\" to activate" \
       -e "tell application \"Terminal\" to do script \"bash $TOKEN_HELPER\"" \
       >/dev/null 2>&1; then
    opened=1
  fi
else
  # Linux — leia ja käivita sobiv terminal.
  # Tähelepanu: helper-skriptil on shebang (#!/bin/bash) ja chmod +x,
  # seetõttu kutsume seda OTSE (mitte "bash $HELPER"). Nii on argument
  # üksainus failitee (ilma tühikuteta), mis töötab nii modernsete kui
  # vanemate terminalide korral, sõltumata sellest, kuidas nad `-e`
  # argumenti parseerivad.
  #
  # x-terminal-emulator on Debian/Ubuntu süsteemis tavaliselt symlink
  # kasutaja vaiketerminalile (Ubuntu 25.10-l näiteks gnome-console/kgx
  # või gnome-terminal). Lahendame selle, et teaks kas tegu on
  # gnome-terminal-i tüüpi (vajab `-- cmd`) või vanema stiilis terminaliga
  # (vajab `-e cmd`).
  resolve_term_name() {
    local cmd path
    cmd=$(command -v "$1" 2>/dev/null) || return 1
    path=$(readlink -f "$cmd" 2>/dev/null || echo "$cmd")
    basename "$path"
  }

  for term in x-terminal-emulator gnome-terminal ptyxis konsole xfce4-terminal alacritty kitty xterm kgx; do
    if command -v "$term" >/dev/null 2>&1; then
      real_term=$(resolve_term_name "$term" || echo "$term")
      case "$real_term" in
        gnome-terminal*|ptyxis*)
          # Modern GNOME-stiilis: `-- cmd args`
          "$term" -- "$TOKEN_HELPER" >/dev/null 2>&1 &
          ;;
        kitty*)
          # kitty: positsiooniline
          "$term" "$TOKEN_HELPER" >/dev/null 2>&1 &
          ;;
        *)
          # konsole, alacritty, xterm, xfce4-terminal, kgx/gnome-console:
          # kõik aktsepteerivad `-e <executable>` ühe argumendina.
          "$term" -e "$TOKEN_HELPER" >/dev/null 2>&1 &
          ;;
      esac
      opened=1
      break
    fi
  done
fi

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

# --- [4/7] Repo kloonimine -----------------------------------
echo ""
echo "--- [4/7] Repo kloonimine ---"
if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo juba olemas, uuendan..."
  if ! git -C "$REPO_DIR" pull --ff-only; then
    echo "HOIATUS: git pull ebaõnnestus (kohalikud muudatused?). Jätkan olemasoleva HEAD-iga."
  fi
else
  git clone https://github.com/web-eid/web-eid-authtoken-validation-java.git "$REPO_DIR"
fi
# Windowsis kloonitud repol võib mvnw exec bit puududa
chmod +x "$REPO_DIR/example/mvnw" 2>/dev/null || true

# --- [5/7] Root library ehitus -------------------------------
echo ""
echo "--- [5/7] Root library ehitus (~1 min) ---"
echo "Logi: $BUILD_LOG"
cd "$REPO_DIR/example"
if ! ./mvnw -f ../pom.xml clean install -B > "$BUILD_LOG" 2>&1; then
  echo "VIGA: root library ehitus ebaõnnestus. Viimased 40 rida logist:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
echo "Root library installitud lokaalsesse Maven cache'i"

# --- [6/7] Example app ehitus --------------------------------
echo ""
echo "--- [6/7] Example app ehitus (~1 min) ---"
cd "$REPO_DIR/example"
if ! ./mvnw clean package -B >> "$BUILD_LOG" 2>&1; then
  echo "VIGA: example app ehitus ebaõnnestus. Viimased 40 rida logist:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
JAR=$(find target -maxdepth 1 -name 'web-eid-springboot-example-*.jar' ! -name '*-original.jar' | head -1)
if [ -z "$JAR" ]; then
  echo "VIGA: ehitatud JAR-i ei leitud kaustas target/" >&2
  exit 1
fi
echo "JAR ehitatud: $JAR"

# --- [7/7] ngrok tunnel + rakenduse käivitamine --------------
echo ""
echo "--- [7/7] ngrok tunnel + rakenduse käivitamine ---"

# Tapa vana ngrok PID-faili järgi
if [ -f "$NGROK_PID_FILE" ]; then
  old_pid=$(cat "$NGROK_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$NGROK_PID_FILE"
fi

# Käivita ngrok taustal (nohup et shell sulgemine ei tapaks)
nohup "$NGROK_BIN" http 8080 --log=stdout > "$NGROK_LOG" 2>&1 &
echo $! > "$NGROK_PID_FILE"

# URL ngrok-i lokaalsest API-st (stabiilsem kui logi parsimine)
echo "Ootan ngrok tunneli avamist..."
NGROK_URL=""
for i in $(seq 1 20); do
  if command -v jq >/dev/null 2>&1; then
    NGROK_URL=$(http_get 2 http://localhost:4040/api/tunnels 2>/dev/null \
      | jq -r '.tunnels[]? | select(.proto=="https") | .public_url' 2>/dev/null \
      | head -1 || true)
  else
    NGROK_URL=$(http_get 2 http://localhost:4040/api/tunnels 2>/dev/null \
      | grep -oE 'https://[^"]+\.ngrok[^"]*' | head -1 || true)
  fi
  [ -n "$NGROK_URL" ] && break
  sleep 1
done
if [ -z "$NGROK_URL" ]; then
  echo "VIGA: ngrok tunnel ei avanenud 20 sek jooksul." >&2
  echo "Kontrolli auth tokenit ja võrguühendust. ngrok logi viimased 20 rida:" >&2
  tail -20 "$NGROK_LOG" >&2
  exit 1
fi
echo "Tunnel: $NGROK_URL"

# Uuenda application-dev.yaml — sed -i.bak töötab nii GNU kui BSD sed-iga
if [ ! -f "$DEV_YAML" ]; then
  echo "VIGA: $DEV_YAML ei eksisteeri (repo struktuur muutunud?)" >&2
  exit 1
fi
sed -i.bak "s|local-origin:.*|local-origin: \"$NGROK_URL\"|" "$DEV_YAML"
rm -f "$DEV_YAML.bak"
echo "application-dev.yaml uuendatud: local-origin = $NGROK_URL"

# Tapa vana app PID-faili järgi
if [ -f "$APP_PID_FILE" ]; then
  old_pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 2
  fi
  rm -f "$APP_PID_FILE"
fi

# Vabasta port 8080 — portatiivne (lsof töötab nii Linuxil kui macOS-il)
if command -v lsof >/dev/null 2>&1; then
  port_pids=$(lsof -ti :8080 2>/dev/null || true)
  if [ -n "$port_pids" ]; then
    echo "Vabastame pordi 8080 (PID-id: $port_pids)"
    # shellcheck disable=SC2086
    kill -9 $port_pids 2>/dev/null || true
    sleep 1
  fi
fi

# Käivita rakendus
cd "$REPO_DIR/example"
nohup ./mvnw spring-boot:run -Dspring-boot.run.profiles=dev > "$APP_LOG" 2>&1 &
echo $! > "$APP_PID_FILE"

echo "Ootan rakenduse käivitumist (~60 sek)..."
APP_OK=0
for i in $(seq 1 30); do
  if grep -q "Started WebEidSpringbootExampleApplication" "$APP_LOG" 2>/dev/null; then
    APP_OK=1
    break
  fi
  if grep -qE "APPLICATION FAILED TO START|BindException|Port .* was already in use|Caused by:" "$APP_LOG" 2>/dev/null; then
    echo "VIGA: rakendus ei käivitunud. Logi viimased 40 rida:" >&2
    tail -40 "$APP_LOG" >&2
    exit 1
  fi
  sleep 2
done
if [ "$APP_OK" -ne 1 ]; then
  echo "VIGA: rakendus ei käivitunud 60 sek jooksul. Logi viimased 40 rida:" >&2
  tail -40 "$APP_LOG" >&2
  exit 1
fi

# ── Live-logi monitooring eraldi terminaliaknas ────────────
LOG_TAIL_HELPER="$TOOLS_DIR/log-tail-helper.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid Java — LIVE LOGI\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${Y}  Ava brauseris:\${N}  ${NGROK_URL}"
echo -e "\${Y}  App log:\${N}        ${APP_LOG}"
echo -e "\${Y}  ngrok log:\${N}      ${NGROK_LOG}"
echo -e "\${Y}  ngrok inspector:\${N} http://127.0.0.1:4040"
echo ""
echo -e "\${B}  Iga ID-kaardi tegevus (auth/sign/cert/OCSP) ilmub allpool reaalajas.\${N}"
echo -e "\${B}  Ctrl+C või sulge aken kui lõpetad.\${N}"
echo ""
echo "----------------------------------------------------------------"
tail -n 0 -f "${APP_LOG}"
HELPER_EOF
chmod +x "$LOG_TAIL_HELPER"

# resolve_term_name juba defineeritud ülal sammus 3
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
echo "║                                                                ║"
echo "║  ngrok inspector:  http://127.0.0.1:4040                       ║"
echo "║                                                                ║"
if [ "$opened_log" -eq 1 ]; then
  echo "║  Live logi:        AVATUD ERALDI TERMINALIAKNAS                ║"
else
  echo "║  Live logi:        ei suutnud terminali avada                  ║"
  printf "║  Käivita käsitsi:  tail -f %-36s║\n" "$APP_LOG"
fi
echo "║                                                                ║"
echo "║  Peatamiseks:                                                  ║"
printf "║    kill \$(cat %s)              ║\n" "$APP_PID_FILE"
printf "║    kill \$(cat %s)                  ║\n" "$NGROK_PID_FILE"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
