#!/bin/bash
# web-eid-app ehitamise ja testimise skript Ubuntu Linuxil
# Testitud: Ubuntu 24.04.4 LTS, Docker 29.1.3

set -e

WORKDIR="$HOME/claude-test"
APP_DIR="$WORKDIR/web-eid-app"
LOG_DIR="$WORKDIR/logs"
REPO="web-eid/web-eid-app"
ORIGIN="https://ria.ee"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
step() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

mkdir -p "$LOG_DIR"

# ─────────────────────────────────────────────
step "1. Haru valimine"
# ─────────────────────────────────────────────

info "Laen saadaolevad harud GitHub-ist (web-eid/web-eid-app)..."

# Kasuta gh CLI-d kui on saadaval, muidu curl
if gh --version &>/dev/null; then
    BRANCHES=$(gh api "repos/${REPO}/branches" --paginate --jq '.[].name' 2>/dev/null)
else
    BRANCHES=$(curl -s "https://api.github.com/repos/${REPO}/branches?per_page=100" \
        | python3 -c "import json,sys; [print(b['name']) for b in json.load(sys.stdin)]" 2>/dev/null)
fi

if [ -z "$BRANCHES" ]; then
    fail "Ei õnnestunud harusid laadida. Kontrolli internetiühendust."
    exit 1
fi

echo ""
echo "Saadaolevad harud:"
i=1
while IFS= read -r branch; do
    printf "  %2d) %s\n" "$i" "$branch"
    i=$((i + 1))
done <<< "$BRANCHES"

echo ""
BRANCH_COUNT=$((i - 1))
printf "Vali haru number (1-%d): " "$BRANCH_COUNT"
read -r SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "$BRANCH_COUNT" ]; then
    fail "Vigane valik: $SELECTION"
    exit 1
fi

BRANCH=$(echo "$BRANCHES" | sed -n "${SELECTION}p")
ok "Valitud haru: $BRANCH"

# ─────────────────────────────────────────────
step "2. Docker kontrollimine ja paigaldamine"
# ─────────────────────────────────────────────

if sudo docker --version &>/dev/null; then
    ok "Docker on paigaldatud: $(sudo docker --version)"
else
    info "Docker puudub — paigaldan..."
    sudo apt install -y docker.io
    ok "Docker paigaldatud"
fi

info "Testin Dockeri toimimist..."
if sudo docker run --rm hello-world &>/dev/null; then
    ok "Docker töötab"
else
    fail "Docker ei tööta — kontrolli paigaldust ja õigusi (docker grupp / sudo)"
    exit 1
fi

# ─────────────────────────────────────────────
step "3. Docker-põhine ehituse verifitseerimine (CI paketiloend)"
# ─────────────────────────────────────────────

info "Ehitan puhtas Ubuntu 24.04 konteineris (haru: $BRANCH)..."
info "Logi: $LOG_DIR/docker-build-ci.log"
info "Jälgi teises terminalis: tail -f $LOG_DIR/docker-build-ci.log"

sudo docker run --rm ubuntu:24.04 bash -c "
  export DEBIAN_FRONTEND=noninteractive
  export QT_QPA_PLATFORM=offscreen
  export DEBFULLNAME='Test Build'
  export DEBEMAIL='test@test.ee'

  echo '--- Paigaldan sõltuvused (CI paketiloend) ---'
  apt update -qq && apt install --no-install-recommends -y \
    git ca-certificates build-essential pkg-config cmake libpcsclite-dev libssl-dev \
    libgtest-dev libgl-dev libqt6svg6-dev qt6-tools-dev qt6-tools-dev-tools \
    qt6-l10n-tools fakeroot devscripts debhelper lintian lsb-release

  echo '--- Kloonimine ---'
  git clone --recurse-submodules https://github.com/web-eid/web-eid-app.git
  cd web-eid-app
  git checkout ${BRANCH}

  echo '--- Ehitamine (./build.sh) ---'
  ./build.sh

  echo '--- Kontroll: .deb failid ---'
  ls ../*.deb
" > "$LOG_DIR/docker-build-ci.log" 2>&1 || true

if grep -q "dpkg-deb: building" "$LOG_DIR/docker-build-ci.log"; then
    ok "Docker ehitus õnnestus — .deb failid loodud"
    grep "dpkg-deb: building" "$LOG_DIR/docker-build-ci.log" | while read -r line; do
        info "  $line"
    done
else
    fail "Docker ehitus ebaõnnestus — vaata logi: $LOG_DIR/docker-build-ci.log"
    tail -20 "$LOG_DIR/docker-build-ci.log"
    exit 1
fi

# ─────────────────────────────────────────────
step "4. Kohalik sõltuvuste paigaldamine"
# ─────────────────────────────────────────────

info "Paigaldan CI paketiloendi otse hostmasinasse..."
sudo apt install -y \
    git ca-certificates build-essential pkg-config cmake libpcsclite-dev libssl-dev \
    libgtest-dev libgl-dev libqt6svg6-dev qt6-tools-dev qt6-tools-dev-tools \
    qt6-l10n-tools fakeroot devscripts debhelper lintian lsb-release
ok "Sõltuvused paigaldatud"

# ─────────────────────────────────────────────
step "5. Kohalik ehitus (testkaardiga testimiseks)"
# ─────────────────────────────────────────────

if [ -d "$APP_DIR" ]; then
    info "web-eid-app on juba kloonitud — uuendan..."
    cd "$APP_DIR"
    git fetch origin
else
    info "Kloonimine..."
    cd "$WORKDIR"
    git clone --recurse-submodules https://github.com/web-eid/web-eid-app.git
    cd "$APP_DIR"
fi

info "Laen haru: $BRANCH"
git checkout "$BRANCH"
git pull origin "$BRANCH" 2>/dev/null || true
ok "Harul $BRANCH (commit: $(git log --oneline -1))"

info "Ehitan rakendust..."
export DEBFULLNAME="Test Build"
export DEBEMAIL="test@test.ee"
if ! echo "" | ./build.sh; then
    fail "Kohalik ehitus ebaõnnestus"
    exit 1
fi
ok "Ehitus lõpetatud"

WEBEID_BIN="$APP_DIR/obj-x86_64-linux-gnu/src/app/web-eid"
if [ ! -f "$WEBEID_BIN" ]; then
    fail "Executable ei leitud: $WEBEID_BIN"
    exit 1
fi
ok "Executable: $WEBEID_BIN"

# ─────────────────────────────────────────────
step "6. Rakenduse testimine testkaardiga"
# ─────────────────────────────────────────────

echo ""
echo "⚠️  Veendu et kaardilugeja ja testkaart on ühendatud!"
echo "   Vajuta Enter jätkamiseks..."
read -r

# ── L-5a: get-signing-certificate ──
info "Testin: get-signing-certificate"
CERT_OUTPUT=$("$WEBEID_BIN" -c get-signing-certificate \
    "{\"origin\":\"$ORIGIN\"}" 2>/dev/null)

if echo "$CERT_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'certificate' in d" 2>/dev/null; then
    ok "get-signing-certificate — sertifikaat saadud"
    CERT=$(echo "$CERT_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['certificate'])")
else
    fail "get-signing-certificate ebaõnnestus"
    echo "$CERT_OUTPUT"
    exit 1
fi

# ── L-5b: authenticate ──
info "Testin: authenticate (SHA-384 automaatne valik)"
NONCE=$(openssl rand -base64 32)
AUTH_OUTPUT=$("$WEBEID_BIN" -c authenticate \
    "{\"origin\":\"$ORIGIN\",\"challengeNonce\":\"$NONCE\"}" 2>/dev/null)

if echo "$AUTH_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'algorithm' in d and 'signature' in d" 2>/dev/null; then
    ALGO=$(echo "$AUTH_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['algorithm'])" 2>/dev/null || echo "?")
    ok "authenticate — JWT token saadud (algoritm: $ALGO)"
else
    fail "authenticate ebaõnnestus"
    echo "$AUTH_OUTPUT"
    exit 1
fi

# ── L-5c: sign SHA-384 ──
info "Testin: sign SHA-384"
HASH=$(echo -n "test document" | openssl dgst -sha384 -binary | base64)
SIGN_OUTPUT=$("$WEBEID_BIN" -c sign \
    "{\"origin\":\"$ORIGIN\",\"hash\":\"$HASH\",\"hashFunction\":\"SHA-384\",\"certificate\":\"$CERT\"}" 2>/dev/null)

if echo "$SIGN_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'signature' in d" 2>/dev/null; then
    SIGN_ALGO=$(echo "$SIGN_OUTPUT" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); a=d['signatureAlgorithm']; print(a['cryptoAlgorithm']+' '+a['hashFunction'])" 2>/dev/null)
    ok "sign SHA-384 — allkiri saadud (algoritm: $SIGN_ALGO)"
else
    fail "sign ebaõnnestus"
    echo "$SIGN_OUTPUT"
    exit 1
fi

# ─────────────────────────────────────────────
step "7. Kokkuvõte"
# ─────────────────────────────────────────────

echo ""
ok "Docker ehitus (CI paketiloend)   — .deb failid loodud"
ok "Kohalik ehitus (haru: $BRANCH)   — rakendus ehitatud"
ok "get-signing-certificate          — sertifikaat saadud"
ok "authenticate                     — JWT token saadud (algoritm: $ALGO)"
ok "sign SHA-384                     — allkiri saadud (algoritm: $SIGN_ALGO)"
echo ""
info "Haru: $BRANCH"
info "Logid: $LOG_DIR/"
info "Executable: $WEBEID_BIN"
