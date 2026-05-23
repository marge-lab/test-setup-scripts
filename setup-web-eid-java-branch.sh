#!/usr/bin/env bash
# Web eID Java näiterakenduse paigaldus — harutestimine (ngrok)
# Toetatud: Linux ja macOS (x86_64 / arm64). Windowsil ei tööta.
#
# Kasutus:
#   ./setup-web-eid-java-branch.sh                                # küsib haru
#   ./setup-web-eid-java-branch.sh --branch HARU                  # otsib substring
#   ./setup-web-eid-java-branch.sh --branch HARU REPO_DIR TOOLS_DIR
# Vaikimisi:
#   REPO_DIR  = $HOME/projects/web-eid
#   TOOLS_DIR = $HOME/tools
#
# Erinevus tavaskriptist (setup-web-eid-java.sh):
# - Lubab valida haru ja töötab selle peal
# - Stash-ib varasema skripti muudatused enne checkout-i
# - Verifitseerib ehitatud library versiooni ja git commit-i

set -euo pipefail

SCRIPT_VERSION="1.0-branch"
BRANCH=""

# Parsi --branch enne positional args
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --branch) BRANCH="$2"; shift 2 ;;
    --help|-h)
      sed -n '1,15p' "$0"; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
# Reset positional args. Kasuta if-kontrolli, sest "${ARGS[@]:-}" tühja
# massiivi puhul annab `set --` ühe TÜHJA stringi $1-na (mitte 0 argumenti).
if [ "${#ARGS[@]}" -gt 0 ]; then
  set -- "${ARGS[@]}"
else
  set --
fi

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

echo "=== Web eID Java harutestimine (v$SCRIPT_VERSION, $(date +%Y-%m-%d)) ==="
echo "Platvorm:  $OS_ADOPT/$ADOPT_ARCH"
echo "REPO_DIR:  $REPO_DIR"
echo "TOOLS_DIR: $TOOLS_DIR"
echo "NB! Sudo ei ole vajalik — kõik paigaldatakse kodukataloogi."
echo ""

mkdir -p "$TOOLS_DIR" "$(dirname "$REPO_DIR")"

# --- HTTP allalaadimine: curl või wget -----------------------
if command -v curl >/dev/null 2>&1; then
  HTTP_TOOL="curl"
  http_download() { curl -L --fail --progress-bar -o "$1" "$2"; }
  http_get() { curl -s --max-time "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then
  HTTP_TOOL="wget"
  http_download() { wget --show-progress -q -O "$1" "$2"; }
  http_get() { wget -q --timeout="$1" --tries=1 -O - "$2"; }
else
  echo "VIGA: ei curl ega wget pole paigaldatud." >&2
  echo "Paigalda üks neist: sudo apt install -y curl" >&2
  exit 1
fi
echo "HTTP tööriist: $HTTP_TOOL"

# --- Cleanup -------------------------------------------------
TOKEN_HELPER=""
cleanup_on_exit() {
  local rc=$?
  if [ -n "${TOKEN_HELPER:-}" ] && [ -f "$TOKEN_HELPER" ]; then
    rm -f "$TOKEN_HELPER" 2>/dev/null || true
  fi
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

resolve_term_name() {
  local cmd path
  cmd=$(command -v "$1" 2>/dev/null) || return 1
  path=$(readlink -f "$cmd" 2>/dev/null || echo "$cmd")
  basename "$path"
}

# --- [1/8] JDK 17 --------------------------------------------
echo ""
echo "--- [1/8] JDK 17 ---"
JDK_DIR=$(ls -d "$TOOLS_DIR"/jdk-17.* 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$JDK_DIR" ] && [ -d "$JDK_DIR" ]; then
  echo "JDK 17 juba olemas: $(basename "$JDK_DIR")"
else
  echo "Laadin uusima JDK 17 GA versiooni Adoptium-ist ($OS_ADOPT/$ADOPT_ARCH)..."
  http_download "$TOOLS_DIR/jdk17.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/17/ga/$OS_ADOPT/$ADOPT_ARCH/jdk/hotspot/normal/eclipse"
  tar -xzf "$TOOLS_DIR/jdk17.tar.gz" -C "$TOOLS_DIR/"
  rm -f "$TOOLS_DIR/jdk17.tar.gz"
  JDK_DIR=$(ls -d "$TOOLS_DIR"/jdk-17.* | sort -V | tail -1)
  echo "JDK 17 paigaldatud: $(basename "$JDK_DIR")"
fi

if [ "$OS_ADOPT" = "mac" ]; then
  export JAVA_HOME="$JDK_DIR/Contents/Home"
else
  export JAVA_HOME="$JDK_DIR"
fi
export PATH="$JAVA_HOME/bin:$PATH"

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

# --- [2/8] ngrok ---------------------------------------------
echo ""
echo "--- [2/8] ngrok ---"
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
      echo "VIGA: unzip puudub." >&2
      exit 1
    fi
    unzip -oq "$TOOLS_DIR/ngrok.zip" -d "$TOOLS_DIR/"
  fi
  rm -f "$TOOLS_DIR/ngrok.$NGROK_EXT"
  chmod +x "$NGROK_BIN"
  echo "ngrok paigaldatud"
fi
"$NGROK_BIN" version

# --- [3/8] ngrok auth token ----------------------------------
echo ""
echo "--- [3/8] ngrok auth token ---"

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
if [ "$OS_ADOPT" = "mac" ]; then
  if osascript \
       -e "tell application \"Terminal\" to activate" \
       -e "tell application \"Terminal\" to do script \"bash $TOKEN_HELPER\"" \
       >/dev/null 2>&1; then
    opened=1
  fi
else
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

# --- [4/8] Repo + haru valimine ------------------------------
echo ""
echo "--- [4/8] Repo + haru valimine ---"
if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo juba olemas, fetch --prune..."
  git -C "$REPO_DIR" fetch --prune origin
else
  git clone https://github.com/web-eid/web-eid-authtoken-validation-java.git "$REPO_DIR"
  git -C "$REPO_DIR" fetch --prune origin
fi
chmod +x "$REPO_DIR/example/mvnw" 2>/dev/null || true

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

# Stash kohalikud muudatused (varasem skripti käivitus võis application-dev.yaml-i muuta).
# Märgime AUTO_STASH_CREATED=1, et hiljem (pärast õnnestunud checkout+pull-i) saaks
# selle drop-ida — muidu koguneb iga jooksuga uus stash kasutaja `git stash list`-i.
AUTO_STASH_CREATED=0
if ! git -C "$REPO_DIR" diff --quiet HEAD; then
  echo "Stashin kohalikud muudatused (varasem skripti käivitus)..."
  git -C "$REPO_DIR" stash push -m "auto-stash $(date +%s)" >/dev/null
  AUTO_STASH_CREATED=1
fi

git -C "$REPO_DIR" checkout "$BRANCH"
git -C "$REPO_DIR" pull origin "$BRANCH" --ff-only || \
  echo "HOIATUS: ff-only pull ebaõnnestus — jätkan kohaliku HEAD-iga."
chmod +x "$REPO_DIR/example/mvnw" 2>/dev/null || true

# Drop auto-stash kui me selle lõime — checkout+pull õnnestusid, vana
# (eelmise jooksu) sisu pole enam vaja. Skript on iga repo-toiminguni
# ainuke kirjutaja, seega `stash@{0}` on garanteeritult meie loodud stash.
if [ "$AUTO_STASH_CREATED" -eq 1 ]; then
  git -C "$REPO_DIR" stash drop "stash@{0}" >/dev/null 2>&1 || true
fi

# --- Haru ja commit-i verifikatsioon -----------------------
CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
LOCAL_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD)
LOCAL_COMMIT_SHORT=$(git -C "$REPO_DIR" rev-parse --short HEAD)
REMOTE_COMMIT=$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
COMMIT_SUBJECT=$(git -C "$REPO_DIR" log -1 --pretty=format:'%s')
COMMIT_DATE=$(git -C "$REPO_DIR" log -1 --pretty=format:'%ci')

echo ""
echo "──────────── HARU + COMMIT VERIFIKATSIOON ────────────"
echo "Soovitud haru:     $BRANCH"
echo "Aktiivne haru:     $CURRENT_BRANCH"

if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo ""
  echo "VIGA: aktiivne haru ('$CURRENT_BRANCH') ei kattu soovituga ('$BRANCH')."
  echo "      Checkout ebaõnnestus — peatan."
  exit 1
fi
echo "  → haru kontroll OK ✓"

echo "Kohalik commit:    $LOCAL_COMMIT"
if [ -n "$REMOTE_COMMIT" ]; then
  echo "Remote commit:     $REMOTE_COMMIT"
  if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
    echo "  → commit sünkroonis origin/$BRANCH-iga ✓"
  else
    echo "  HOIATUS: kohalik commit erineb origin/$BRANCH-st (võib-olla ff-only pull ebaõnnestus)."
  fi
else
  echo "  HOIATUS: origin/$BRANCH commit-i ei õnnestunud lugeda."
fi
echo "Commit lühike:     $LOCAL_COMMIT_SHORT"
echo "Pealkiri:          $COMMIT_SUBJECT"
echo "Kuupäev:           $COMMIT_DATE"
echo "──────────────────────────────────────────────────────"
echo ""

# --- Build-log live monitor (eraldi terminaliaknas) ---------
BUILD_LOG_TAIL_HELPER="$TOOLS_DIR/.web-eid-java-build-tail.sh"
cat > "$BUILD_LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; M='\033[1;35m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid Java HARU — EHITUSE LIVE LOGI (Maven)\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${M}  Haru:\${N}    $BRANCH"
echo -e "\${M}  Commit:\${N}  $(git -C $REPO_DIR rev-parse --short HEAD)"
echo ""
echo -e "\${Y}  Logi:\${N}    ${BUILD_LOG}"
echo ""
echo -e "\${B}  Iga Maven-i samm jookseb allpool reaalajas.\${N}"
echo -e "\${B}  Versioonide kontroll: otsi 'Building' / 'Installing' / 'version'.\${N}"
echo -e "\${B}  Sulge aken X-nupuga kui valmis.\${N}"
echo -e "\${B}  (Ctrl+C ignoreeritakse — kopeerimine.)\${N}"
echo ""
echo "----------------------------------------------------------------"

trap "" INT
trap 'kill \$(jobs -p) 2>/dev/null; exit 0' TERM HUP

tail -F "${BUILD_LOG}" 2>/dev/null &
wait
HELPER_EOF
chmod +x "$BUILD_LOG_TAIL_HELPER"

opened_build_log=0
if [ "$OS_ADOPT" = "mac" ]; then
  if osascript \
       -e "tell application \"Terminal\" to activate" \
       -e "tell application \"Terminal\" to do script \"bash $BUILD_LOG_TAIL_HELPER\"" \
       >/dev/null 2>&1; then
    opened_build_log=1
  fi
else
  for term in x-terminal-emulator gnome-terminal ptyxis konsole xfce4-terminal alacritty kitty xterm kgx; do
    if command -v "$term" >/dev/null 2>&1; then
      real_term=$(resolve_term_name "$term" || echo "$term")
      case "$real_term" in
        gnome-terminal*|ptyxis*) "$term" -- "$BUILD_LOG_TAIL_HELPER" >/dev/null 2>&1 & ;;
        kitty*)                  "$term" "$BUILD_LOG_TAIL_HELPER" >/dev/null 2>&1 & ;;
        *)                       "$term" -e "$BUILD_LOG_TAIL_HELPER" >/dev/null 2>&1 & ;;
      esac
      opened_build_log=1
      break
    fi
  done
fi

if [ "$opened_build_log" -eq 1 ]; then
  echo "→ Ehituse live-logi avatud eraldi terminaliaknas"
else
  echo "HOIATUS: ei suutnud build-logi terminali avada. Logi: $BUILD_LOG"
fi
echo ""

# --- [5/8] Root library ehitus (sisaldab ühikteste) ---------
echo ""
echo "--- [5/8] Root library ehitus (~1 min, ühiktestid kaasas) ---"
echo "Logi: $BUILD_LOG"
cd "$REPO_DIR/example"
if ! ./mvnw -f ../pom.xml clean install -B > "$BUILD_LOG" 2>&1; then
  echo "VIGA: root library ehitus/testid ebaõnnestus. Viimased 40 rida logist:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
echo "Root library installitud lokaalsesse Maven cache'i"

# Ühiktestide kokkuvõte build-logist
echo ""
echo "--- Ühiktestide kokkuvõte ---"
TEST_SUMMARY=$(grep -E "^\[INFO\] Tests run: [0-9]+" "$BUILD_LOG" | tail -5 || true)
if [ -n "$TEST_SUMMARY" ]; then
  echo "$TEST_SUMMARY"
else
  grep -E "Tests run|BUILD SUCCESS|BUILD FAILURE" "$BUILD_LOG" | tail -10 || true
fi
echo "---"

# Library versiooni kontroll Maven cache'is
echo ""
echo "--- Library versiooni kontroll ---"
# Proovi mitut mustrit — "Installing .../web-eid-authtoken-validation/X.Y.Z..." VÕI
# "Building Web eID ... X.Y.Z" VÕI pom.xml-i <version>
LIB_VERSION=$(grep -oE "Installing .+web-eid-authtoken-validation/[0-9]+\.[0-9]+\.[0-9]+[^/]*" "$BUILD_LOG" 2>/dev/null \
  | head -1 | sed 's|.*/||' || true)
if [ -z "$LIB_VERSION" ]; then
  LIB_VERSION=$(grep -oE "Building [^ ]*web-eid-authtoken-validation[^ ]* [0-9]+\.[0-9]+\.[0-9]+[^ ]*" "$BUILD_LOG" 2>/dev/null \
    | head -1 | awk '{print $NF}' || true)
fi
if [ -z "$LIB_VERSION" ] && [ -f "$REPO_DIR/pom.xml" ]; then
  LIB_VERSION=$(grep -m1 -oE "<version>[0-9]+\.[0-9]+\.[0-9]+[^<]*</version>" "$REPO_DIR/pom.xml" 2>/dev/null \
    | sed -E 's|</?version>||g' || true)
fi
if [ -n "$LIB_VERSION" ]; then
  echo "✓ Lokaalsesse Maven cache'i installitud versioon: $LIB_VERSION"
else
  echo "HOIATUS: build-logist ei õnnestunud nopida installitud versiooni"
  grep -E "Building .* web-eid" "$BUILD_LOG" | head -3 || true
fi

# --- [6/8] Example app ehitus --------------------------------
echo ""
echo "--- [6/8] Example app ehitus (~1 min) ---"
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

# --- [7/8] ngrok tunnel + app käivitus -----------------------
echo ""
echo "--- [7/8] ngrok tunnel + rakenduse käivitamine ---"

if [ -f "$NGROK_PID_FILE" ]; then
  old_pid=$(cat "$NGROK_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$NGROK_PID_FILE"
fi

nohup "$NGROK_BIN" http 8080 --log=stdout > "$NGROK_LOG" 2>&1 &
echo $! > "$NGROK_PID_FILE"

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
  tail -20 "$NGROK_LOG" >&2
  exit 1
fi
echo "Tunnel: $NGROK_URL"

if [ ! -f "$DEV_YAML" ]; then
  echo "VIGA: $DEV_YAML ei eksisteeri (repo struktuur muutunud?)" >&2
  exit 1
fi
sed -i.bak "s|local-origin:.*|local-origin: \"$NGROK_URL\"|" "$DEV_YAML"
rm -f "$DEV_YAML.bak"
echo "application-dev.yaml uuendatud: local-origin = $NGROK_URL"

if [ -f "$APP_PID_FILE" ]; then
  old_pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 2
  fi
  rm -f "$APP_PID_FILE"
fi

if command -v lsof >/dev/null 2>&1; then
  port_pids=$(lsof -ti :8080 2>/dev/null || true)
  if [ -n "$port_pids" ]; then
    echo "Vabastame pordi 8080 (PID-id: $port_pids)"
    # shellcheck disable=SC2086
    kill -9 $port_pids 2>/dev/null || true
    sleep 1
  fi
fi

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

# --- [8/8] Live-logi monitooring -----------------------------
echo ""
echo "--- [8/8] Live-logi monitooring ---"

LOG_TAIL_HELPER="$TOOLS_DIR/log-tail-helper.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; M='\033[1;35m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid Java HARU — LIVE LOGI\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${M}  Haru:\${N}              $BRANCH"
echo -e "\${M}  Commit:\${N}            $(git -C $REPO_DIR rev-parse --short HEAD)"
echo ""
echo -e "\${Y}  Ava brauseris:\${N}     ${NGROK_URL}"
echo -e "\${Y}  ngrok inspector:\${N}   http://127.0.0.1:4040"
echo -e "\${Y}  App log:\${N}           ${APP_LOG}"
echo ""
echo -e "\${B}  Akna sulgemine:\${N}    X-nupp (sulgeb AINULT akna; app + ngrok jäävad taustaks)"
echo -e "\${B}                     Ctrl+C ignoreeritakse — saad teksti kopeerida"
echo ""
echo -e "\${B}  Logi uuesti avada:\${N} bash ${LOG_TAIL_HELPER}"
echo ""
echo -e "\${B}  App + ngrok peatada:\${N}"
echo -e "\${B}    kill \\\$(cat ${APP_PID_FILE})\${N}"
echo -e "\${B}    kill \\\$(cat ${NGROK_PID_FILE})\${N}"
echo ""
echo "----------------------------------------------------------------"

trap '' INT

tail -n 0 -f "${APP_LOG}"
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
echo "════════════════════════════════════════════════════════════════════"
echo "  PAIGALDUS VALMIS — Java HARU"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Haru:             $BRANCH"
echo "  Commit:           $(git -C $REPO_DIR rev-parse --short HEAD)"
[ -n "${LIB_VERSION:-}" ] && echo "  Library versioon: $LIB_VERSION (lokaalsesse Maven cache'i installitud)"
echo ""
echo "  Ava brauseris:    $NGROK_URL"
echo "  ngrok inspector:  http://127.0.0.1:4040"
echo ""
if [ "$opened_log" -eq 1 ]; then
  echo "  Live logi:        AVATUD ERALDI TERMINALIAKNAS"
  echo "                    X-nupp sulgeb akna (app + ngrok jäävad taustaks)"
else
  echo "  Live logi:        ei suutnud terminali avada"
fi
echo ""
echo "  Logi uuesti avada:"
echo "    bash $LOG_TAIL_HELPER"
echo "    (või otse:  tail -n 0 -f $APP_LOG)"
echo ""
echo "  App + ngrok peatada:"
echo "    kill \$(cat $APP_PID_FILE)"
echo "    kill \$(cat $NGROK_PID_FILE)"
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo ""
