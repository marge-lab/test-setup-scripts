#!/bin/bash
set -e

# ============================================================
# Web eID .NET näiterakenduse paigaldus — main haru (Linux)
# Kasutamine: bash setup-web-eid-dotnet.sh
# ============================================================

TOOLS_DIR="$HOME/tools"
REPO_DIR="$HOME/projects/web-eid-dotnet"
DOTNET_ROOT="$TOOLS_DIR/dotnet"
EXAMPLE_DIR="$REPO_DIR/example/src/WebEid.AspNetCore.Example"
CSPROJ="$EXAMPLE_DIR/WebEid.AspNetCore.Example.csproj"
# .sln-fail on ühe taseme võrra ülemal, mitte .csproj-i kõrval.
SLN="$REPO_DIR/example/src/WebEid.AspNetCore.Example.sln"
DIGIDOC_DIR="$EXAMPLE_DIR/DigiDoc"

echo "=== Web eID .NET näiterakenduse paigaldus (main) ==="
echo "NB! Skript võib küsida sudo parooli (libdigidocpp-csharp paigaldamiseks)."
echo ""

mkdir -p "$TOOLS_DIR" "$HOME/projects"

# Cleanup trap — vea korral tapa taustaprotsess kui see käivitati.
# PID-fail luuakse sammus 6, aga viidatakse siin et trap teaks seda otsida.
APP_PID_FILE="$TOOLS_DIR/dotnet-app.pid"
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
echo "--- [1/6] .NET 8 SDK ---"
if [ -f "$DOTNET_ROOT/dotnet" ] && "$DOTNET_ROOT/dotnet" --version 2>/dev/null | grep -q "^8\."; then
  echo ".NET 8 juba olemas: $("$DOTNET_ROOT/dotnet" --version)"
else
  echo "Laadin .NET 8 SDK..."
  # Ilma -q-ta — vea korral (DNS, võrk, 404) näeb kasutaja kohe miks
  # allalaadimine kukus, mitte hiljem segast `chmod` viga puuduva faili
  # peale.
  wget --show-progress https://dot.net/v1/dotnet-install.sh -O "$TOOLS_DIR/dotnet-install.sh"
  chmod +x "$TOOLS_DIR/dotnet-install.sh"
  # dotnet-install.sh ei toeta --quiet flag-i. Vaikimisi pole see lärmakas.
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

# ── 2. Repo kloonimine ────────────────────────────────────
echo ""
echo "--- [2/6] Repo ---"
if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo juba olemas, uuendan main..."
  git -C "$REPO_DIR" checkout main
  git -C "$REPO_DIR" pull
else
  git clone https://github.com/web-eid/web-eid-authtoken-validation-dotnet.git "$REPO_DIR"
fi

# ── 3. libdigidocpp-csharp (allkirjastamiseks) ────────────
echo ""
echo "--- [3/6] libdigidocpp-csharp ---"

SO_FILE="$DIGIDOC_DIR/libdigidoc_csharp.so"

if [ -f "$SO_FILE" ] && [ -f "$DIGIDOC_DIR/digidoc.cs" ]; then
  echo "DigiDoc failid juba olemas repos"
else
  # Kui süsteemne libdigidocpp-csharp pole paigaldatud, paigaldame apt-iga.
  # See pakk on id.ee apt-repos eraldi põhipakkidest (libdigidocpp1 jne) —
  # kasutaja peab selle olema lubanud või laseme apt-il automaatselt paigaldada.
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
  echo "DigiDoc failid kopeeritud"
fi

# Veendu et .so kopeeritakse build output'i.
# Kasutame Directory.Build.props-i — MSBuild merge-ib selle automaatselt
# example app-i ehitusse, ilma et peaks .csproj-i ennast muutma. See on
# robustne upstream-i .csproj vormingumuudatuste vastu (varasem sed-iga
# .csproj-i muutmine kukus vaikselt, kui upstream paigutas XML-i ümber).
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

# ── 4. Veendu et ProjectReference on paigas ───────────────
echo ""
echo "--- [4/6] WebEid.Security viide ---"
if grep -q "ProjectReference.*WebEid.Security" "$CSPROJ"; then
  echo "OK: ProjectReference (lokaalne lähtekood)"
else
  echo "Parandan: vahetan PackageReference -> ProjectReference..."
  sed -i 's|<PackageReference Include="WebEid\.Security" Version="[^"]*" />|<ProjectReference Include="../../../src/WebEid.Security/WebEid.Security.csproj" />|' "$CSPROJ"
  # Veendu, et sed tegelikult midagi muutis. Kui upstream-is on multi-line
  # vorming (`<PackageReference>` eraldi `<Version>` elemendiga vms), siis
  # sed ei matchi ja PackageReference jääks alles ilma vihjet andmata.
  if ! grep -q "ProjectReference.*WebEid.Security" "$CSPROJ"; then
    echo "VIGA: ei suutnud PackageReference-i asendada ProjectReference-iga." >&2
    echo "Tõenäoliselt on upstream-i $CSPROJ vorming muutunud" >&2
    echo "(nt multi-line PackageReference). Vaata fail käsitsi üle." >&2
    exit 1
  fi
fi

# ── 5. TSL cache + build ──────────────────────────────────
echo ""
echo "--- [5/6] TSL cache ja build ---"
# EE_T.xml = Eesti TEST-TSL. Faili olemasolu (isegi tühjana) on libdigidocpp
# library-le flag: "luba test ID-kaardi sertifikaate". Library täidab sisu
# ise õigesti, kui hakkab esimest korda test-CA-d valideerima.
# ÄRA EEMALDA — ilma selleta jääb test ID-kaartidega autentimine katki,
# sest test CA-d pole production TSL-is ja jäävad usaldamatuks.
mkdir -p ~/.digidocpp/tsl
touch ~/.digidocpp/tsl/EE_T.xml
echo "~/.digidocpp/tsl/EE_T.xml OK (test ID-kaardi tugi)"

BUILD_LOG="$TOOLS_DIR/dotnet-build.log"
if ! dotnet restore "$SLN" > "$BUILD_LOG" 2>&1; then
  echo "VIGA: dotnet restore kukus. Viimased 40 rida logist:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
if ! dotnet build "$SLN" >> "$BUILD_LOG" 2>&1; then
  echo "VIGA: dotnet build kukus. Viimased 40 rida logist:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
echo "Build OK (logi: $BUILD_LOG)"

# Kopeeri .so ka praeguseks käivituseks
mkdir -p "$EXAMPLE_DIR/bin/Debug/net8.0"
cp "$SO_FILE" "$EXAMPLE_DIR/bin/Debug/net8.0/" 2>/dev/null || true

# ── 6. Käivitamine ────────────────────────────────────────
echo ""
echo "--- [6/6] Käivitamine ---"
# Tapa vana protsess PID-faili järgi (mitte `pkill -f`-ga, mis võiks
# match-ida ka mõne muu dotnet-protsessi käsurea järgi).
if [ -f "$APP_PID_FILE" ]; then
  old_pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "Tapan vana .NET protsessi (PID $old_pid)"
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$APP_PID_FILE"
fi

nohup dotnet run --project "$CSPROJ" \
  > "$TOOLS_DIR/dotnet-app.log" 2>&1 &
echo $! > "$APP_PID_FILE"

echo "Ootan rakenduse käivitumist (~20 sek)..."
for i in {1..20}; do
  if grep -q "Now listening on\|Application started" "$TOOLS_DIR/dotnet-app.log" 2>/dev/null; then
    echo "Rakendus on üleval!"
    grep "Now listening on" "$TOOLS_DIR/dotnet-app.log" | head -1
    break
  fi
  if grep -q "Unhandled exception\|FATAL" "$TOOLS_DIR/dotnet-app.log" 2>/dev/null; then
    echo "VIGA: rakendus ei käivitunud. Vaata: tail -30 $TOOLS_DIR/dotnet-app.log"
    exit 1
  fi
  sleep 2
done

# ── Live-logi monitooring eraldi terminaliaknas ────────────
APP_LOG="$TOOLS_DIR/dotnet-app.log"
LOG_TAIL_HELPER="$TOOLS_DIR/log-tail-helper.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; N='\033[0m'
clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid .NET — LIVE LOGI\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${Y}  Ava brauseris:\${N}     https://localhost:44391"
echo -e "\${Y}  App log:\${N}           ${APP_LOG}"
echo ""
echo -e "\${B}  Akna sulgemine:\${N}    X-nupp (sulgeb AINULT akna; app jääb taustaks)"
echo -e "\${B}                     Ctrl+C ignoreeritakse — saad teksti kopeerida"
echo ""
echo -e "\${B}  Logi uuesti avada:\${N} bash ${LOG_TAIL_HELPER}"
echo ""
echo -e "\${B}  App peatada:\${N}       kill \\\$(cat ${APP_PID_FILE})"
echo ""
echo "  (TSL signature spam on filtreeritud välja.)"
echo "----------------------------------------------------------------"

# Ctrl+C ignoreeritakse, et kopeerimine töötaks. X-nupp (SIGHUP) sulgeb
# AINULT logi-akna — dotnet-rakendust ei puututa (banner näitab kuidas
# peatada).
trap '' INT

tail -n 0 -f "${APP_LOG}" | grep --line-buffered -vE 'TSL\.cpp:24'
HELPER_EOF
chmod +x "$LOG_TAIL_HELPER"

# Terminal-detektsioon (sama muster nagu Java/remote skriptis)
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
echo "════════════════════════════════════════════════════════════════════"
echo "  PAIGALDUS VALMIS — .NET (lokaalne)"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Ava brauseris:    https://localhost:44391"
echo ""
if [ "$opened_log" -eq 1 ]; then
  echo "  Live logi:        AVATUD ERALDI TERMINALIAKNAS"
  echo "                    X-nupp sulgeb akna (app jääb taustaks)"
else
  echo "  Live logi:        ei suutnud terminali avada"
fi
echo ""
echo "  Logi uuesti avada (kui sulgesid akna):"
echo "    bash $LOG_TAIL_HELPER"
echo "    (või otse:  tail -n 0 -f $APP_LOG | grep -v 'TSL.cpp:24')"
echo ""
echo "  App peatada:"
echo "    kill \$(cat $APP_PID_FILE)"
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo ""
