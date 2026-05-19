#!/bin/bash
set -e

# ============================================================
# Web eID .NET näiterakenduse paigaldus — harutestimine (Linux)
#
# Kasutamine:
#   bash setup-web-eid-dotnet-branch.sh                   # küsib haru
#   bash setup-web-eid-dotnet-branch.sh --branch HARU     # otsib substring
#
# Erinevus tavaskriptist (setup-web-eid-dotnet.sh):
# - Lubab valida haru ja töötab selle peal
# - Ehitab WebEid.Security NuGet paketi LOKAALSELT versioonis 1.2.0-beta1
#   (eristub GitLabi 1.2.0-st)
# - Example app csproj uuendatakse PackageReference 1.2.0-beta1 peale
# - Lisaks toob live logi eraldi terminaliaknasse
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
# .sln-fail on ühe taseme võrra ülemal, mitte .csproj-i kõrval.
SLN="$REPO_DIR/example/src/WebEid.AspNetCore.Example.sln"

APP_PID_FILE="$TOOLS_DIR/dotnet-app.pid"
APP_LOG="$TOOLS_DIR/dotnet-app.log"
BUILD_LOG="$TOOLS_DIR/dotnet-build.log"

echo "=== Web eID .NET harutestimine ==="
echo "Lokaalne NuGet versioon: $NUGET_VERSION"
echo "NB! Skript võib küsida sudo parooli (libdigidocpp-csharp paigaldamiseks)."
echo ""

mkdir -p "$TOOLS_DIR" "$HOME/projects"

# Cleanup trap — vea korral tapa taustaprotsess
cleanup_on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$APP_PID_FILE" ]; then
    local pid
    pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "" >&2
      echo "VIGA (exit $rc) — koristame taustaprotsessi (PID $pid)..." >&2
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$APP_PID_FILE"
  fi
}
trap cleanup_on_exit EXIT

# ── 1. .NET 8 SDK ─────────────────────────────────────────
echo "--- [1/8] .NET 8 SDK ---"
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
echo "--- [2/8] Repo ---"
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

# Stash kohalikud muudatused (varasem käivitamine võis csproj-i muuta)
if ! git -C "$REPO_DIR" diff --quiet HEAD; then
  echo "Stashin kohalikud muudatused (varasem skripti käivitus)..."
  git -C "$REPO_DIR" stash push -m "auto-stash $(date +%s)" >/dev/null
fi

git -C "$REPO_DIR" checkout "$BRANCH"
git -C "$REPO_DIR" pull origin "$BRANCH"
echo "Aktiivne haru: $(git -C $REPO_DIR branch --show-current)"

# ── 3. Lokaalne NuGet build ───────────────────────────────
echo ""
echo "--- [3/8] Lokaalne NuGet build (WebEid.Security $NUGET_VERSION) ---"

cd "$REPO_DIR"
find src -name "obj" -type d -exec rm -rf {} + 2>/dev/null || true
find src -name "bin" -type d -exec rm -rf {} + 2>/dev/null || true

rm -rf "$LOCAL_NUGET"
mkdir -p "$LOCAL_NUGET"

# WebEid.Security.csproj-is on `GeneratePackageOnBuild=true`, seega
# `dotnet build` toodab .nupkg-i automaatselt bin/Release/-i.
# -p:Version + -p:PackageVersion sunnivad versiooni üle.
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

# ── 4. libdigidocpp-csharp ────────────────────────────────
echo ""
echo "--- [4/8] libdigidocpp-csharp ---"

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

# Directory.Build.props — MSBuild merge-ib selle automaatselt example app-i ehitusse
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
  echo "Directory.Build.props loodud: libdigidoc_csharp.so kopeeritakse build output'i"
else
  echo "Directory.Build.props juba olemas"
fi

# ── 5. TSL cache ──────────────────────────────────────────
echo ""
echo "--- [5/8] TSL cache ---"
# EE_T.xml = Eesti TEST-TSL. Faili olemasolu (isegi tühjana) on libdigidocpp
# library-le flag: "luba test ID-kaardi sertifikaate".
mkdir -p ~/.digidocpp/tsl
touch ~/.digidocpp/tsl/EE_T.xml
echo "~/.digidocpp/tsl/EE_T.xml OK (test ID-kaardi tugi)"

# ── 6. Example app build ──────────────────────────────────
echo ""
echo "--- [6/8] Example app build ---"

# Kui .sln on olemas, kasuta seda, muidu .csproj
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

# (1) DLL sisemise versiooni kontroll — tõestab et lokaalne pakk on kasutusel
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

# (2) Git haru + commit hash
echo "(2) Git haru ja commit:"
echo "    Haru:     $(git -C $REPO_DIR branch --show-current)"
echo "    Commit:   $(git -C $REPO_DIR rev-parse HEAD)"
echo "    Lühike:   $(git -C $REPO_DIR rev-parse --short HEAD)"
echo "    Pealkiri: $(git -C $REPO_DIR log -1 --pretty=format:'%s')"
echo "    Autor:    $(git -C $REPO_DIR log -1 --pretty=format:'%an <%ae>')"
echo "    Kuupäev:  $(git -C $REPO_DIR log -1 --pretty=format:'%ai')"

# ── 7. Käivitamine ────────────────────────────────────────
echo ""
echo "--- [7/8] Käivitamine ---"

# Tapa vana protsess PID-faili järgi
if [ -f "$APP_PID_FILE" ]; then
  old_pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "Tapan vana .NET protsessi (PID $old_pid)"
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$APP_PID_FILE"
fi

cd "$EXAMPLE_DIR"
nohup dotnet run --project "$CSPROJ" \
  > "$APP_LOG" 2>&1 &
echo $! > "$APP_PID_FILE"

echo "Ootan rakenduse käivitumist (~30 sek)..."
APP_OK=0
for i in $(seq 1 30); do
  if grep -q "Now listening on\|Application started" "$APP_LOG" 2>/dev/null; then
    APP_OK=1
    echo "Rakendus on üleval!"
    grep "Now listening on" "$APP_LOG" | head -1
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

# ── 8. Live-logi monitooring eraldi terminaliaknas ───────
echo ""
echo "--- [8/8] Live-logi monitooring ---"

LOG_TAIL_HELPER="$TOOLS_DIR/log-tail-helper.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; M='\033[1;35m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid .NET HARU — LIVE LOGI\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${M}  Haru:\${N}            $BRANCH"
echo -e "\${M}  Commit:\${N}          $(git -C $REPO_DIR rev-parse --short HEAD)"
echo -e "\${M}  NuGet versioon:\${N}  $NUGET_VERSION (lokaalne)"
echo ""
echo -e "\${Y}  Ava brauseris:\${N}  https://localhost:44391"
echo -e "\${Y}  App log:\${N}        ${APP_LOG}"
echo ""
echo -e "\${B}  Iga ID-kaardi tegevus (auth/sign/cert/OCSP) ilmub allpool reaalajas.\${N}"
echo -e "\${B}  TSL signature spam on filtreeritud välja.\${N}"
echo -e "\${B}  Sulge aken X-nupuga → sulgub KÕIK ühe klikiga: app + logi.\${N}"
echo -e "\${B}  (Ctrl+C ignoreeritakse, et teksti saaks kopeerida.)\${N}"
echo ""
echo "----------------------------------------------------------------"

cleanup() {
  kill \$(jobs -p) 2>/dev/null
  [ -f "${APP_PID_FILE}" ] && kill \$(cat "${APP_PID_FILE}") 2>/dev/null
  exit 0
}
trap '' INT
trap cleanup TERM HUP

tail -n 0 -f "${APP_LOG}" | grep --line-buffered -vE 'TSL\.cpp:24' &
wait
HELPER_EOF
chmod +x "$LOG_TAIL_HELPER"

resolve_term_name() {
  local cmd path
  cmd=$(command -v "$1" 2>/dev/null) || return 1
  path=$(readlink -f "$cmd" 2>/dev/null || echo "$cmd")
  basename "$path"
}

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
printf "║  NuGet versioon:   %-44s║\n" "$NUGET_VERSION (lokaalne)"
echo "║                                                                ║"
echo "║  Ava brauseris:    https://localhost:44391                     ║"
echo "║                                                                ║"
if [ "$opened_log" -eq 1 ]; then
  echo "║  Live logi:        AVATUD ERALDI TERMINALIAKNAS                ║"
else
  echo "║  Live logi:        ei suutnud terminali avada                  ║"
  printf "║  Käivita käsitsi:  tail -f %-36s║\n" "$APP_LOG"
fi
echo "║                                                                ║"
printf "║  Peatamiseks:      kill \$(cat %-26s║\n" "$APP_PID_FILE)"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
