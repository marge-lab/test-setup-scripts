#!/bin/bash
set -e

# ============================================================
# Web eID .NET näiterakenduse paigaldus REMOTE-režiimis (ngrok)
# Kasutamine: bash setup-web-eid-dotnet-remote.sh
#
# Erinevus tavaskriptist (setup-web-eid-dotnet.sh):
# - Lisaks paigaldab ngrok-i ja küsib auth tokenit
# - Rakendus kuulab http://0.0.0.0:8080 (HTTP — ngrok teeb HTTPS)
# - ngrok-tunnel teeb rakenduse internetist kättesaadavaks
# - appsettings.json OriginUrl uuendatakse ngrok URL-iks
# ============================================================

TOOLS_DIR="$HOME/tools"
REPO_DIR="$HOME/projects/web-eid-dotnet"
DOTNET_ROOT="$TOOLS_DIR/dotnet"
EXAMPLE_DIR="$REPO_DIR/example/src/WebEid.AspNetCore.Example"
CSPROJ="$EXAMPLE_DIR/WebEid.AspNetCore.Example.csproj"
# .sln-fail on ühe taseme võrra ülemal, mitte .csproj-i kõrval.
SLN="$REPO_DIR/example/src/WebEid.AspNetCore.Example.sln"
DIGIDOC_DIR="$EXAMPLE_DIR/DigiDoc"
APPSETTINGS="$EXAMPLE_DIR/appsettings.json"

NGROK_BIN="$TOOLS_DIR/ngrok"
APP_PID_FILE="$TOOLS_DIR/dotnet-app.pid"
NGROK_PID_FILE="$TOOLS_DIR/ngrok.pid"
APP_LOG="$TOOLS_DIR/dotnet-app.log"
NGROK_LOG="$TOOLS_DIR/ngrok.log"
BUILD_LOG="$TOOLS_DIR/dotnet-build.log"
APP_PORT="8080"

echo "=== Web eID .NET REMOTE paigaldus (ngrok-tunnel) ==="
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

# ── 2. Repo kloonimine ────────────────────────────────────
echo ""
echo "--- [2/8] Repo ---"
if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo juba olemas, uuendan main..."
  git -C "$REPO_DIR" checkout main
  git -C "$REPO_DIR" pull
else
  git clone https://github.com/web-eid/web-eid-authtoken-validation-dotnet.git "$REPO_DIR"
fi

# ── 3. libdigidocpp-csharp ────────────────────────────────
echo ""
echo "--- [3/8] libdigidocpp-csharp ---"

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
  echo "DigiDoc failid kopeeritud"
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
  echo "Directory.Build.props loodud"
else
  echo "Directory.Build.props juba olemas"
fi

# ── 4. Source-patch-id (ProjectReference + Trust-CA) ──────
echo ""
echo "--- [4/8] Source-patch-id ---"

# 4a. WebEid.Security ProjectReference (laekoodi viide)
if grep -q "ProjectReference.*WebEid.Security" "$CSPROJ"; then
  echo "OK: WebEid.Security ProjectReference juba paigas"
else
  echo "Parandan: vahetan PackageReference -> ProjectReference..."
  sed -i 's|<PackageReference Include="WebEid\.Security" Version="[^"]*" />|<ProjectReference Include="../../../src/WebEid.Security/WebEid.Security.csproj" />|' "$CSPROJ"
  if ! grep -q "ProjectReference.*WebEid.Security" "$CSPROJ"; then
    echo "VIGA: ei suutnud PackageReference-i asendada." >&2
    exit 1
  fi
fi

# 4b. Force test-CA-d alati laetakse (Startup.cs).
# Web eID Security library laeb trusted CA-d keskkonna-järgi: Dev-modes
# Dev/*.cer (test ID-kaardid), Prod-modes Prod/*.cer (live ID-kaardid).
# Me jookseme Production-modes (UseForwardedHeaders ngrok-i jaoks vajalik),
# mis muidu tähendaks et test-kaardid pole trusted. Force-ime alati 'true' →
# Dev (test) CA-d laetakse alati.
#
# NB! Selle patch-iga ei usalda app live-kaartide CA-sid. Kui vajad
# live-kaarti, kasuta lokaalset skripti (setup-web-eid-dotnet.sh) ja
# muuda Startup.cs käsitsi vastupidi.
STARTUP_CS="$EXAMPLE_DIR/Startup.cs"
if grep -q 'LoadTrustedCaCertificatesFromDisk(CurrentEnvironment\.IsDevelopment())' "$STARTUP_CS"; then
  echo "Patch-in Startup.cs: force test-CA-d alati laetakse..."
  sed -i 's|LoadTrustedCaCertificatesFromDisk(CurrentEnvironment\.IsDevelopment())|LoadTrustedCaCertificatesFromDisk(true)|' "$STARTUP_CS"
  if ! grep -q 'LoadTrustedCaCertificatesFromDisk(true)' "$STARTUP_CS"; then
    echo "VIGA: Startup.cs patch ei õnnestunud — vorming võis upstream-is muutuda." >&2
    exit 1
  fi
elif grep -q 'LoadTrustedCaCertificatesFromDisk(true)' "$STARTUP_CS"; then
  echo "OK: Startup.cs juba patch-itud (test-CA-d alati laetakse)"
else
  echo "HOIATUS: Startup.cs vorming muutunud, ei leia LoadTrustedCaCertificatesFromDisk kõnet." >&2
fi

# Startup.cs middleware-i EI patchi — Production-mode upstream-i kood
# (UseHsts + UseForwardedHeaders else-harus) töötab ngrok-iga, login õnnestub.
#
# DigiDocConfiguration.cs patch (samm 4c) — laienda `if (env.IsDevelopment())`
# tingimust env-muutujaga `WEBEID_USE_TEST_TSL=true`, et test-TSL setterid
# (`setTSLUrl/setTSLCert/setTSUrl`) jõustuks ka Production-modes.
#
# digidocpp.conf-i kaudu seda EI saa teha: libdigidocpp XmlConf.cpp toetab
# ainult `tsl.autoupdate`, `tsl.cache`, `tsl.onlineDigest`, `tsl.timeOut`
# parameetreid — `tsl.url` ja `tsl.cert` on hardcoded `tslcerts.h`-s ja
# saab override-da AINULT C++ API setteritega. Seetõttu peame source-patchi.
DIGIDOC_CONF_CS="$EXAMPLE_DIR/Signing/DigiDocConfiguration.cs"
PATCH_NEW='if (env.IsDevelopment() || Environment.GetEnvironmentVariable("WEBEID_USE_TEST_TSL") == "true") /* Patched: remote test-TSL flag */'
if grep -qF "$PATCH_NEW" "$DIGIDOC_CONF_CS"; then
  echo "OK: DigiDocConfiguration.cs juba patch-itud (WEBEID_USE_TEST_TSL flag)"
elif grep -q 'if (env\.IsDevelopment())' "$DIGIDOC_CONF_CS"; then
  echo "Patch-in DigiDocConfiguration.cs: lisan WEBEID_USE_TEST_TSL flag-i..."
  sed -i "s@if (env\.IsDevelopment())@${PATCH_NEW}@" "$DIGIDOC_CONF_CS"
  if ! grep -qF "$PATCH_NEW" "$DIGIDOC_CONF_CS"; then
    echo "VIGA: DigiDocConfiguration.cs patch ei õnnestunud — upstream'i vorming võis muutuda." >&2
    exit 1
  fi
else
  echo "HOIATUS: DigiDocConfiguration.cs vorming muutunud — ei leia 'if (env.IsDevelopment())' kõnet." >&2
fi

# ── 5. ngrok ──────────────────────────────────────────────
echo ""
echo "--- [5/8] ngrok ---"
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

# ── 6. ngrok auth token ───────────────────────────────────
echo ""
echo "--- [6/8] ngrok auth token ---"

# Ajutine abi-skript uue terminali-akna jaoks
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

resolve_term_name() {
  local cmd path
  cmd=$(command -v "$1" 2>/dev/null) || return 1
  path=$(readlink -f "$cmd" 2>/dev/null || echo "$cmd")
  basename "$path"
}

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
echo "--- [7/8] TSL cache ja build ---"
# EE_T.xml = Eesti TEST-TSL. Faili olemasolu (isegi tühjana) on libdigidocpp
# library-le flag: "luba test ID-kaardi sertifikaate". Library täidab sisu
# ise õigesti, kui hakkab esimest korda test-CA-d valideerima.
# ÄRA EEMALDA — ilma selleta jääb test ID-kaartidega autentimine katki.
mkdir -p ~/.digidocpp/tsl
touch ~/.digidocpp/tsl/EE_T.xml
echo "~/.digidocpp/tsl/EE_T.xml OK (test ID-kaardi tugi)"

# Defensiivne: kui kunagi varem on tühi ~/.digidocpp/tsl/EE.xml maha jäänud
# (nt eelnev katse), eemalda see. Libdigidocpp eeldab kas valiidset XML-i
# või et faili pole — tühi fail annab "Start tag expected" parser-vea ja
# jätab TSL store nulli ("Loaded 0 certificates into TSL certificate store").
if [ -f ~/.digidocpp/tsl/EE.xml ] && [ ! -s ~/.digidocpp/tsl/EE.xml ]; then
  echo "Eemaldan tühja ~/.digidocpp/tsl/EE.xml (lõhuks TSL init-i)"
  rm ~/.digidocpp/tsl/EE.xml
fi

# digidocpp.conf-i ei kasutame — libdigidocpp ei toeta tsl.url ega tsl.cert
# parameetreid (need on hardcoded tslcerts.h-s, override ainult C++ API kaudu).
# Test-TSL setterid kutsutakse DigiDocConfiguration.cs-st (vt patch sammus 4c)
# kui WEBEID_USE_TEST_TSL=true env-muutuja on seatud.
#
# Eemalda vana digidocpp.conf, kui see varasemast skripti versioonist maha
# jäänud — segab libdigidocpp init-i tühjade param-väärtustega.
if [ -f "$HOME/.digidocpp/digidocpp.conf" ] && \
   grep -q "open-eid.github.io/test-TL" "$HOME/.digidocpp/digidocpp.conf" 2>/dev/null; then
  echo "Eemaldan vana ~/.digidocpp/digidocpp.conf (eelnev skripti versioon — ei toiminud)"
  rm "$HOME/.digidocpp/digidocpp.conf"
fi

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

# ── 8. ngrok tunnel + appsettings + start ─────────────────
echo ""
echo "--- [8/8] ngrok tunnel + rakenduse käivitamine ---"

# Tapa vana ngrok PID-faili järgi
if [ -f "$NGROK_PID_FILE" ]; then
  old_pid=$(cat "$NGROK_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$NGROK_PID_FILE"
fi

# Käivita ngrok HTTP-tunnel pordile $APP_PORT (kus app hakkab kuulama)
nohup "$NGROK_BIN" http "$APP_PORT" --log=stdout > "$NGROK_LOG" 2>&1 &
echo $! > "$NGROK_PID_FILE"

# Loe ngrok-i avalik URL lokaalsest API-st (stabiilsem kui logi parsimine)
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
  echo "Kontrolli auth tokenit ja võrguühendust. ngrok logi viimased 20 rida:" >&2
  tail -20 "$NGROK_LOG" >&2
  exit 1
fi
echo "Tunnel: $NGROK_URL"

# Uuenda appsettings.json — OriginUrl peab vastama ngrok URL-ile,
# muidu Web eID library lükkab autentimispäringud Origin-i mittevastavusega tagasi.
if [ ! -f "$APPSETTINGS" ]; then
  echo "VIGA: $APPSETTINGS ei eksisteeri (repo struktuur muutunud?)" >&2
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
#
# ASPNETCORE_ENVIRONMENT=Production — kohustuslik ngrok-i jaoks. Upstream
# Startup.cs lülitab `UseForwardedHeaders()` (mis loeb `X-Forwarded-Proto`
# header-i) sisse AINULT mitte-Dev-modes. Dev-modes oleks `UseHttpsRedirection()`
# aktiivne, mis lõhuks ngrok-i (HTTP→HTTPS redirect-loop). LISAKS Dev-mode
# katsetus lõpetas AuthTokenSignatureValidationException-iga login-flow's.
#
# Test-kaardi tugi tuleb env-mode-st EI sõltu:
# - Auth: Startup.cs patch sammus [4/8] sunnib `LoadTrustedCaCertificatesFromDisk(true)`
#         → test CA-d (Certificates/Dev/*.cer) laetakse alati, ka Production-modes.
# - Sign: DigiDocConfiguration.cs patch sammus [4/8] 4c laiendab `if`-tingimust
#         env-muutujaga `WEBEID_USE_TEST_TSL=true` (allpool) → setTSLUrl/Cert/TSUrl
#         setterid kutsutakse ka Production-modes.
#
# --no-launch-profile keelab launchSettings.json sätted (mis muidu paneks
# rakenduse kuulama https://localhost:44391, mis ngrok-i jaoks ei sobi).
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

# ── Live-logi monitooring eraldi terminaliaknas ────────────
# Loo helper-skript, mis trükib URL-i, banneri ja jookseb tail -f-i.
# Filtreerime välja libdigidocpp TSL-i spammi, et oleks näha tegelikud
# päringud (cert-laadimine, OCSP, allkirja-tegevused).
LOG_TAIL_HELPER="$TOOLS_DIR/log-tail-helper.sh"
cat > "$LOG_TAIL_HELPER" <<HELPER_EOF
#!/bin/bash
# Värvid (kui terminal toetab)
G='\033[1;32m'  # roheline-paks
Y='\033[1;33m'  # kollane-paks
B='\033[1;34m'  # sinine-paks
N='\033[0m'     # reset

clear
echo -e "\${G}================================================================\${N}"
echo -e "\${G}  WebEid .NET REMOTE — LIVE LOGI\${N}"
echo -e "\${G}================================================================\${N}"
echo ""
echo -e "\${Y}  Ava brauseris:\${N}  ${NGROK_URL}"
echo -e "\${Y}  App log:\${N}        ${APP_LOG}"
echo -e "\${Y}  ngrok inspector:\${N} http://127.0.0.1:4040"
echo ""
echo -e "\${B}  Iga ID-kaardi tegevus (auth/sign/cert/OCSP) ilmub allpool reaalajas.\${N}"
echo -e "\${B}  TSL signature spam on filtreeritud välja.\${N}"
echo -e "\${B}  Sulge aken X-nupuga → sulgub KÕIK ühe klikiga: app + ngrok + logi.\${N}"
echo -e "\${B}  (Ctrl+C ignoreeritakse, et teksti saaks kopeerida — nt ngrok URL-i.)\${N}"
echo ""
echo "----------------------------------------------------------------"

# Ühe-tegevuse sulgemine: kui kasutaja klõpsab X-nuppu, terminal saadab
# SIGHUP — cleanup tapab tail-i, dotnet-rakenduse JA ngrok-tunneli.
# Vastasel juhul peaks kasutaja eraldi tegema kill-käske teises terminalis.
#
# SIGINT (Ctrl+C) ignoreeritakse — paljud terminal-id mappivad Ctrl+C
# kopeerimiseks (Windows Terminal, VS Code, GNOME Terminal valitud teksti
# puhul). Hoiame seda puutumata, et kasutaja saaks ngrok URL-i kopeerida.
cleanup() {
  kill \$(jobs -p) 2>/dev/null
  [ -f "${APP_PID_FILE}" ] && kill \$(cat "${APP_PID_FILE}") 2>/dev/null
  [ -f "${NGROK_PID_FILE}" ] && kill \$(cat "${NGROK_PID_FILE}") 2>/dev/null
  exit 0
}
trap '' INT
trap cleanup TERM HUP

tail -n 0 -f "${APP_LOG}" | grep --line-buffered -vE 'TSL\.cpp:24' &
wait
HELPER_EOF
chmod +x "$LOG_TAIL_HELPER"

# Ava uus terminal — sama muster nagu ngrok auth-token-i puhul
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

# Suur, selge lõpu-banner
echo ""
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  PAIGALDUS VALMIS                              ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║                                                                ║"
printf "║  Ava brauseris:    %-44s║\n" "$NGROK_URL"
echo "║                                                                ║"
printf "║  ngrok inspector:  %-44s║\n" "http://127.0.0.1:4040"
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
