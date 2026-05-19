#!/bin/bash
set -e

# ============================================================
# Web eID .NET näiterakenduse paigaldus — harutestimine + ngrok (Linux)
#
# Kasutamine:
#   bash setup-web-eid-dotnet-branch-remote.sh                   # küsib haru
#   bash setup-web-eid-dotnet-branch-remote.sh --branch HARU     # otsib substring
#
# Erinevus tavaskriptist (setup-web-eid-dotnet-remote.sh):
# - Lubab valida haru ja töötab selle peal
# - Ehitab WebEid.Security NuGet paketi LOKAALSELT versioonis 1.2.0-beta1
#   (eristub GitLabi 1.2.0-st) ja example app csproj uuendatakse
#   PackageReference 1.2.0-beta1 peale
#
# Sarnaselt remote skriptiga:
# - Rakendus kuulab http://0.0.0.0:8080 — ngrok teeb HTTPS-i
# - Source-patchid Startup.cs + DigiDocConfiguration.cs (test ID-kaardi tugi
#   Production-modes)
# - ngrok auth token küsitakse eraldi terminaliaknas
# - Live logi eraldi terminaliaknas, X-nupp sulgeb kõik (app + ngrok + logi)
# ============================================================

BRANCH=""
NUGET_VERSION="1.2.0-beta1"  # lokaalselt ehitatud paketi versioon (eristub GitLabi 1.2.0-st)

while [[ $# -gt 0 ]]; do
  case $1 in
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "Tundmatu parameeter: $1"; exit 1 ;;
  esac
done

TOOLS_DIR="$HOME/tools"
REPO_DIR="$HOME/projects/web-eid-dotnet"
DOTNET_ROOT="$TOOLS_DIR/dotnet"
EXAMPLE_DIR="$REPO_DIR/example/src/WebEid.AspNetCore.Example"
CSPROJ="$EXAMPLE_DIR/WebEid.AspNetCore.Example.csproj"
DIGIDOC_DIR="$EXAMPLE_DIR/DigiDoc"
LOCAL_NUGET="$TOOLS_DIR/local-nuget"
APPSETTINGS="$EXAMPLE_DIR/appsettings.json"
STARTUP_CS="$EXAMPLE_DIR/Startup.cs"
DIGIDOC_CONF_CS="$EXAMPLE_DIR/Signing/DigiDocConfiguration.cs"
# .sln-fail on ühe taseme võrra ülemal, mitte .csproj-i kõrval.
SLN="$REPO_DIR/example/src/WebEid.AspNetCore.Example.sln"

NGROK_BIN="$TOOLS_DIR/ngrok"
APP_PID_FILE="$TOOLS_DIR/dotnet-app.pid"
NGROK_PID_FILE="$TOOLS_DIR/ngrok.pid"
APP_LOG="$TOOLS_DIR/dotnet-app.log"
NGROK_LOG="$TOOLS_DIR/ngrok.log"
BUILD_LOG="$TOOLS_DIR/dotnet-build.log"
APP_PORT="8080"

echo "=== Web eID .NET harutestimine + ngrok ==="
echo "Lokaalne NuGet versioon: $NUGET_VERSION"
echo "NB! Skript võib küsida sudo parooli (libdigidocpp-csharp paigaldamiseks)."
echo ""

mkdir -p "$TOOLS_DIR" "$HOME/projects"

# Cleanup trap — vea korral tapa taustaprotsessid (app + ngrok), eemalda token-helper
TOKEN_HELPER=""
cleanup_on_exit() {
  local rc=$?
  if [ -n "${TOKEN_HELPER:-}" ] && [ -f "$TOKEN_HELPER" ]; then
    rm -f "$TOKEN_HELPER" 2>/dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "VIGA (exit $rc) — koristame taustaprotsesse..." >&2
    for pf in "$APP_PID_FILE" "$NGROK_PID_FILE"; do
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

# ── 1. .NET 8 SDK ─────────────────────────────────────────
echo "--- [1/9] .NET 8 SDK ---"
if [ -f "$DOTNET_ROOT/dotnet" ] && "$DOTNET_ROOT/dotnet" --version 2>/dev/null | grep -q "^8\."; then
  echo ".NET 8 juba olemas: $("$DOTNET_ROOT/dotnet" --version)"
else
  echo "Laadin .NET 8 SDK..."
  wget --show-progress https://dot.net/v1/dotnet-install.sh -O "$TOOLS_DIR/dotnet-install.sh"
  chmod +x "$TOOLS_DIR/dotnet-install.sh"
  "$TOOLS_DIR/dotnet-install.sh" --channel 8.0 --install-dir "$DOTNET_ROOT"
  echo ".NET 8 paigaldatud"
fi

export DOTNET_ROOT="$DOTNET_ROOT"
export PATH="$DOTNET_ROOT:$PATH"

if ! grep -q "DOTNET_ROOT=$TOOLS_DIR/dotnet" ~/.bashrc 2>/dev/null; then
  echo "" >> ~/.bashrc
  echo "export DOTNET_ROOT=$TOOLS_DIR/dotnet" >> ~/.bashrc
  echo "export PATH=\$DOTNET_ROOT:\$PATH" >> ~/.bashrc
fi

dotnet --version

# ── 2. Repo kloonimine + haru valimine ────────────────────
echo ""
echo "--- [2/9] Repo + haru valimine ---"
if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo juba olemas, uuendan..."
  git -C "$REPO_DIR" fetch --prune origin
else
  git clone https://github.com/web-eid/web-eid-authtoken-validation-dotnet.git "$REPO_DIR"
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

MATCHES=$(echo "$ALL_BRANCHES" | grep -i "$BRANCH")
MATCH_COUNT=$(echo "$MATCHES" | grep -c . 2>/dev/null || echo 0)

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

# Stash kohalikud muudatused (varasem käivitamine võis csproj-i/source-patche muuta)
if ! git -C "$REPO_DIR" diff --quiet HEAD; then
  echo "Stashin kohalikud muudatused (varasem skripti käivitus)..."
  git -C "$REPO_DIR" stash push -m "auto-stash $(date +%s)" >/dev/null
fi

git -C "$REPO_DIR" checkout "$BRANCH"
git -C "$REPO_DIR" pull origin "$BRANCH"
echo "Aktiivne haru: $(git -C $REPO_DIR branch --show-current)"

# ── 3. Lokaalne NuGet build ───────────────────────────────
echo ""
echo "--- [3/9] Lokaalne NuGet build (WebEid.Security $NUGET_VERSION) ---"

cd "$REPO_DIR"
find src -name "obj" -type d -exec rm -rf {} + 2>/dev/null || true
find src -name "bin" -type d -exec rm -rf {} + 2>/dev/null || true

rm -rf "$LOCAL_NUGET"
mkdir -p "$LOCAL_NUGET"

# WebEid.Security.csproj-is on `GeneratePackageOnBuild=true`, seega
# `dotnet build` toodab .nupkg-i automaatselt bin/Release/-i.
dotnet build --configuration Release --verbosity quiet \
  -p:Version="$NUGET_VERSION" \
  -p:PackageVersion="$NUGET_VERSION" \
  src/WebEid.Security/WebEid.Security.csproj

NUPKG_FILE="$REPO_DIR/src/WebEid.Security/bin/Release/WebEid.Security.$NUGET_VERSION.nupkg"
if [ ! -f "$NUPKG_FILE" ]; then
  echo "VIGA: lokaalne .nupkg fail ei tekkinud: $NUPKG_FILE"
  ls -la "$REPO_DIR/src/WebEid.Security/bin/Release/"
  exit 1
fi

cp "$NUPKG_FILE" "$LOCAL_NUGET/"
echo "✓ Lokaalne NuGet pakett: $(ls $LOCAL_NUGET/*.nupkg | xargs -n1 basename)"
echo "✓ Asukoht: $LOCAL_NUGET/"
echo "✓ Suurus: $(du -h $LOCAL_NUGET/*.nupkg | cut -f1)"

dotnet nuget remove source "WebEid-Local" 2>/dev/null || true
dotnet nuget add source "$LOCAL_NUGET" --name "WebEid-Local"

# Vaheta csproj viide WebEid.Security peale lokaalsele versioonile.
# Käsitleme kaks juhtu:
#  (a) <ProjectReference ...WebEid.Security.csproj /> — main-haru vorming
#  (b) <PackageReference Include="WebEid.Security" Version="X.Y.Z" /> — mõned harud
# Mõlemad sed-id on idempotentsed (kui ei matchi, ei tee midagi).
sed -i 's|<ProjectReference Include=".*WebEid\.Security\.csproj" />|<PackageReference Include="WebEid.Security" Version="'"$NUGET_VERSION"'" />|' "$CSPROJ"
sed -i 's|<PackageReference Include="WebEid\.Security" Version="[^"]*" />|<PackageReference Include="WebEid.Security" Version="'"$NUGET_VERSION"'" />|' "$CSPROJ"
echo "✓ csproj uuendatud: PackageReference WebEid.Security $NUGET_VERSION"

echo ""
echo "--- Verify that the number was changed (git diff): ---"
git -C "$REPO_DIR" diff -- "$CSPROJ" | grep -E "^[+-].*WebEid\.Security" || echo "HOIATUS: git diff ei näita WebEid.Security muudatust!"
echo "---"

if grep -q "PackageReference Include=\"WebEid.Security\" Version=\"$NUGET_VERSION\"" "$CSPROJ"; then
  echo "✓ KINNITUS: csproj sisaldab PackageReference WebEid.Security $NUGET_VERSION"
else
  echo "VIGA: csproj-is ei ole PackageReference WebEid.Security $NUGET_VERSION!"
  grep "WebEid.Security" "$CSPROJ"
  exit 1
fi

# ── 4. libdigidocpp-csharp + Directory.Build.props ────────
echo ""
echo "--- [4/9] libdigidocpp-csharp ---"

SO_FILE="$DIGIDOC_DIR/libdigidoc_csharp.so"

if [ -f "$SO_FILE" ] && [ -f "$DIGIDOC_DIR/digidoc.cs" ]; then
  echo "DigiDoc failid juba olemas repos"
else
  if ! ls /usr/include/digidocpp_csharp/digidoc.cs /usr/lib/x86_64-linux-gnu/libdigidoc_csharp.so &>/dev/null; then
    echo "libdigidocpp-csharp pakk pole paigaldatud — paigaldame nüüd (sudo)..."
    if ! sudo apt install -y libdigidocpp-csharp; then
      echo "Esimene paigaldus kukus — uuendame apt nimekirja ja proovime uuesti..."
      sudo apt update
      sudo apt install -y libdigidocpp-csharp
    fi
  else
    echo "libdigidocpp-csharp on juba süsteemselt paigaldatud"
  fi

  echo "Kopeerin DigiDoc failid süsteemist repo-sse..."
  cp /usr/include/digidocpp_csharp/*.cs "$DIGIDOC_DIR/"
  cp /usr/lib/x86_64-linux-gnu/libdigidoc_csharp.so "$DIGIDOC_DIR/"
fi

BUILD_PROPS="$EXAMPLE_DIR/Directory.Build.props"
if [ ! -f "$BUILD_PROPS" ]; then
  cat > "$BUILD_PROPS" <<'EOF'
<Project>
  <ItemGroup>
    <None Update="DigiDoc/libdigidoc_csharp.so">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </None>
  </ItemGroup>
</Project>
EOF
  echo "Directory.Build.props loodud"
else
  echo "Directory.Build.props juba olemas"
fi

# ── 5. Source-patchid (test ID-kaardi tugi Production-modes) ─
echo ""
echo "--- [5/9] Source-patchid (Startup.cs + DigiDocConfiguration.cs) ---"

# 5a. Startup.cs — force test-CA-d alati laetakse.
# Production-modes (vajalik ngrok-i jaoks UseForwardedHeaders pärast) muidu
# laeb ainult Prod/*.cer (live-kaardid). Force-ime 'true' → Dev/*.cer (test) laetakse.
if [ ! -f "$STARTUP_CS" ]; then
  echo "HOIATUS: $STARTUP_CS puudub — jätan patch'i vahele" >&2
elif grep -q 'LoadTrustedCaCertificatesFromDisk(CurrentEnvironment\.IsDevelopment())' "$STARTUP_CS"; then
  echo "Patch-in Startup.cs: force LoadTrustedCaCertificatesFromDisk(true)..."
  sed -i 's|LoadTrustedCaCertificatesFromDisk(CurrentEnvironment\.IsDevelopment())|LoadTrustedCaCertificatesFromDisk(true)|' "$STARTUP_CS"
  if ! grep -q 'LoadTrustedCaCertificatesFromDisk(true)' "$STARTUP_CS"; then
    echo "VIGA: Startup.cs patch ei õnnestunud" >&2
    exit 1
  fi
elif grep -q 'LoadTrustedCaCertificatesFromDisk(true)' "$STARTUP_CS"; then
  echo "OK: Startup.cs juba patch-itud"
else
  echo "HOIATUS: Startup.cs vorming muutunud — ei leia LoadTrustedCaCertificatesFromDisk kõnet." >&2
fi

# 5b. DigiDocConfiguration.cs — WEBEID_USE_TEST_TSL flag laiendab if-tingimust
# Test-TSL setterid (setTSLUrl/setTSLCert/setTSUrl) jõustuvad ka Production-modes.
PATCH_NEW='if (env.IsDevelopment() || Environment.GetEnvironmentVariable("WEBEID_USE_TEST_TSL") == "true") /* Patched: remote test-TSL flag */'
if [ ! -f "$DIGIDOC_CONF_CS" ]; then
  echo "HOIATUS: $DIGIDOC_CONF_CS puudub — jätan patch'i vahele" >&2
elif grep -q 'WEBEID_USE_TEST_TSL' "$DIGIDOC_CONF_CS"; then
  # Patch juba olemas (ükskõik mis täpse kommentaariga) — ära patch-i topelt
  echo "OK: DigiDocConfiguration.cs juba patch-itud (sisaldab WEBEID_USE_TEST_TSL)"
elif grep -q 'if (env\.IsDevelopment())' "$DIGIDOC_CONF_CS"; then
  echo "Patch-in DigiDocConfiguration.cs: lisan WEBEID_USE_TEST_TSL flag-i..."
  sed -i "s@if (env\.IsDevelopment())@${PATCH_NEW}@" "$DIGIDOC_CONF_CS"
  if ! grep -qF "$PATCH_NEW" "$DIGIDOC_CONF_CS"; then
    echo "VIGA: DigiDocConfiguration.cs patch ei õnnestunud" >&2
    exit 1
  fi
else
  echo "HOIATUS: DigiDocConfiguration.cs vorming muutunud — ei leia 'if (env.IsDevelopment())' kõnet." >&2
fi

# ── 6. ngrok + auth token eraldi terminalis ──────────────
echo ""
echo "--- [6/9] ngrok ---"
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

# ── 7. TSL cache + build ──────────────────────────────────
echo ""
echo "--- [7/9] TSL cache ja example-app build ---"
mkdir -p ~/.digidocpp/tsl
touch ~/.digidocpp/tsl/EE_T.xml
echo "~/.digidocpp/tsl/EE_T.xml OK (test ID-kaardi tugi)"

# Defensiivne: eemalda tühi EE.xml (lõhuks TSL init-i parse-veaga)
if [ -f ~/.digidocpp/tsl/EE.xml ] && [ ! -s ~/.digidocpp/tsl/EE.xml ]; then
  echo "Eemaldan tühja ~/.digidocpp/tsl/EE.xml"
  rm ~/.digidocpp/tsl/EE.xml
fi

# Defensiivne: eemalda vana digidocpp.conf (segab libdigidocpp init-i)
if [ -f "$HOME/.digidocpp/digidocpp.conf" ] && \
   grep -q "open-eid.github.io/test-TL" "$HOME/.digidocpp/digidocpp.conf" 2>/dev/null; then
  echo "Eemaldan vana ~/.digidocpp/digidocpp.conf"
  rm "$HOME/.digidocpp/digidocpp.conf"
fi

if [ -f "$SLN" ]; then
  BUILD_TARGET="$SLN"
else
  BUILD_TARGET="$CSPROJ"
fi
echo "Build target: $(basename $BUILD_TARGET)"

if ! dotnet restore "$BUILD_TARGET" > "$BUILD_LOG" 2>&1; then
  echo "VIGA: dotnet restore kukus. Viimased 40 rida logist:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
if ! dotnet build "$BUILD_TARGET" >> "$BUILD_LOG" 2>&1; then
  echo "VIGA: dotnet build kukus. Viimased 40 rida logist:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
echo "Build OK (logi: $BUILD_LOG)"

mkdir -p "$EXAMPLE_DIR/bin/Debug/net8.0"
cp "$SO_FILE" "$EXAMPLE_DIR/bin/Debug/net8.0/" 2>/dev/null || true

# Versiooni- ja haru kontroll
echo ""
echo "--- Versiooni- ja haru kontroll ---"
echo "csproj viide: $(grep 'WebEid.Security' $CSPROJ | tr -d ' ')"

EXAMPLE_DLL="$EXAMPLE_DIR/bin/Debug/net8.0/WebEid.Security.dll"
echo "(1) WebEid.Security.dll sisemine versioon (strings):"
if [ -f "$EXAMPLE_DLL" ]; then
  DLL_VERSION=$(strings "$EXAMPLE_DLL" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+-beta" | head -1)
  if [ -n "$DLL_VERSION" ]; then
    echo "    ✓ $DLL_VERSION"
    echo "    (Versiooni järel '+' märgi taga on git commit hash millest pakk ehitati)"
  else
    echo "    HOIATUS: $NUGET_VERSION versiooni DLL-is ei leitud!"
    strings "$EXAMPLE_DLL" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | head -3
  fi
else
  echo "    HOIATUS: $EXAMPLE_DLL puudub"
fi

echo "(2) Git haru ja commit:"
echo "    Haru:     $(git -C $REPO_DIR branch --show-current)"
echo "    Commit:   $(git -C $REPO_DIR rev-parse HEAD)"
echo "    Lühike:   $(git -C $REPO_DIR rev-parse --short HEAD)"
echo "    Pealkiri: $(git -C $REPO_DIR log -1 --pretty=format:'%s')"
echo "    Autor:    $(git -C $REPO_DIR log -1 --pretty=format:'%an <%ae>')"
echo "    Kuupäev:  $(git -C $REPO_DIR log -1 --pretty=format:'%ai')"

# ── 8. ngrok tunnel + appsettings + käivitus ─────────────
echo ""
echo "--- [8/9] ngrok tunnel + rakenduse käivitamine ---"

# Tapa vana ngrok
if [ -f "$NGROK_PID_FILE" ]; then
  old_pid=$(cat "$NGROK_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$NGROK_PID_FILE"
fi

# ngrok HTTP tunnel pordile $APP_PORT
nohup "$NGROK_BIN" http "$APP_PORT" --log=stdout > "$NGROK_LOG" 2>&1 &
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

# Uuenda appsettings.json — OriginUrl peab vastama ngrok URL-ile
if [ ! -f "$APPSETTINGS" ]; then
  echo "VIGA: $APPSETTINGS ei eksisteeri" >&2
  exit 1
fi
sed -i.bak "s|\"OriginUrl\": \"[^\"]*\"|\"OriginUrl\": \"$NGROK_URL\"|" "$APPSETTINGS"
rm -f "$APPSETTINGS.bak"
echo "appsettings.json uuendatud: OriginUrl = $NGROK_URL"

# Tapa vana app
if [ -f "$APP_PID_FILE" ]; then
  old_pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 2
  fi
  rm -f "$APP_PID_FILE"
fi

# Vabasta port $APP_PORT
if command -v lsof >/dev/null 2>&1; then
  port_pids=$(lsof -ti :"$APP_PORT" 2>/dev/null || true)
  if [ -n "$port_pids" ]; then
    echo "Vabastame pordi $APP_PORT (PID-id: $port_pids)"
    # shellcheck disable=SC2086
    kill -9 $port_pids 2>/dev/null || true
    sleep 1
  fi
fi

# Käivita app HTTP-na 0.0.0.0:$APP_PORT — ngrok teeb HTTPS-i.
# ASPNETCORE_ENVIRONMENT=Production — UseForwardedHeaders ngrok-i jaoks vajalik.
# WEBEID_USE_TEST_TSL=true — DigiDocConfiguration.cs patch loeb seda.
# --no-launch-profile — vältida launchSettings.json (port 44391, HTTPS).
nohup env ASPNETCORE_URLS="http://0.0.0.0:$APP_PORT" \
        ASPNETCORE_ENVIRONMENT="Production" \
        WEBEID_USE_TEST_TSL="true" \
  dotnet run --project "$CSPROJ" --no-launch-profile \
  > "$APP_LOG" 2>&1 &
echo $! > "$APP_PID_FILE"

echo "Ootan rakenduse käivitumist (~60 sek)..."
APP_OK=0
for i in $(seq 1 30); do
  if grep -q "Now listening on\|Application started" "$APP_LOG" 2>/dev/null; then
    APP_OK=1
    break
  fi
  if grep -qE "Unhandled exception|FATAL|address already in use" "$APP_LOG" 2>/dev/null; then
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
echo "Rakendus on üleval!"

# ── 9. Live-logi monitooring eraldi terminaliaknas ───────
echo ""
echo "--- [9/9] Live-logi monitooring ---"

LOG_TAIL_HELPER="$TOOLS_DIR/log-tail-helper.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; M='\033[1;35m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid .NET HARU + ngrok — LIVE LOGI\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${M}  Haru:\${N}              $BRANCH"
echo -e "\${M}  Commit:\${N}            $(git -C $REPO_DIR rev-parse --short HEAD)"
echo -e "\${M}  NuGet versioon:\${N}    $NUGET_VERSION (lokaalne)"
echo ""
echo -e "\${Y}  Ava brauseris:\${N}     ${NGROK_URL}"
echo -e "\${Y}  ngrok inspector:\${N}   http://127.0.0.1:4040"
echo -e "\${Y}  App log:\${N}           ${APP_LOG}"
echo ""
echo -e "\${B}  Akna sulgemine:\${N}    X-nupp (sulgeb AINULT akna; app + ngrok jäävad taustaks)"
echo -e "\${B}                     Ctrl+C ignoreeritakse — saad teksti kopeerida (nt ngrok URL)"
echo ""
echo -e "\${B}  Logi uuesti avada:\${N} bash ${LOG_TAIL_HELPER}"
echo ""
echo -e "\${B}  App + ngrok peatada:\${N}"
echo -e "\${B}    kill \\\$(cat ${APP_PID_FILE})\${N}"
echo -e "\${B}    kill \\\$(cat ${NGROK_PID_FILE})\${N}"
echo ""
echo "  (TSL signature spam on filtreeritud välja.)"
echo "----------------------------------------------------------------"

# Ctrl+C ignoreeritakse, et kopeerimine töötaks. X-nupp (SIGHUP) sulgeb
# AINULT logi-akna — taustal jooksvaid dotnet- ja ngrok-protsesse ei
# puututa. Kasutaja peatab need eraldi kill-käskudega (banneril näha).
trap '' INT

tail -n 0 -f "${APP_LOG}" | grep --line-buffered -vE 'TSL\.cpp:24'
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
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  PAIGALDUS VALMIS — .NET haru + ngrok"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Haru:             $BRANCH"
echo "  Commit:           $(git -C $REPO_DIR rev-parse --short HEAD)"
echo "  NuGet versioon:   $NUGET_VERSION (lokaalne)"
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
echo "  Logi uuesti avada (kui sulgesid akna):"
echo "    bash $LOG_TAIL_HELPER"
echo "    (või otse:  tail -n 0 -f $APP_LOG | grep -v 'TSL.cpp:24')"
echo ""
echo "  App + ngrok peatada:"
echo "    kill \$(cat $APP_PID_FILE)"
echo "    kill \$(cat $NGROK_PID_FILE)"
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo ""
