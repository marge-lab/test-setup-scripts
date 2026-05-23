#!/usr/bin/env python3
"""
Web eID .NET naiterakenduse paigaldus + ngrok (remote) -- Windows / macOS.

Erinevus setup-web-eid-dotnet.py-st (kohalik):
- Paigaldab lisaks ngrok-i ja kysib auth-tokenit
- Rakendus kuulab HTTP 0.0.0.0:8080, ngrok teeb HTTPS-i
- ASPNETCORE_ENVIRONMENT=Production alati (ngrok-i UseForwardedHeaders-i jaoks)
- --profile dev: source-patch Startup.cs + DigiDocConfiguration.cs
  (sunnib test-CA-d ja test-TSL-i ka Production-modes — vajalik kuna ngrok
  noaab ASP.NET-i Production-modes jooksmist, aga test-kaardid eeldavad
  Dev-modes konfiguratsiooni)
- --profile prod: digidocpp.conf ts.url-iga (live-kaardid)
- appsettings.json OriginUrl uuendatakse iga jooksu ajal ngrok-URL-iks

Kasutus:
   Windows:  setup-web-eid-dotnet-remote.cmd [--profile dev|prod]
             python setup-web-eid-dotnet-remote.py [--profile dev|prod]
   macOS:    python3 setup-web-eid-dotnet-remote.py [--profile dev|prod]

Sotluvused: ainult Python stdlib (urllib, subprocess, pathlib, shutil, zipfile,
tarfile). EI vaja `pip install` kasku.
"""

import argparse
import getpass
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

# --- Python versiooni kontroll ----------------------------------------------
if sys.version_info < (3, 8):
    print(f"VIGA: vajab Python 3.8+, paigaldatud {sys.version_info.major}.{sys.version_info.minor}")
    sys.exit(1)

# --- Argumendid -------------------------------------------------------------
_arg_parser = argparse.ArgumentParser(
    description="Web eID .NET naiterakenduse paigaldus + ngrok (Windows / macOS)",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=(
        "Profiilid:\n"
        "  dev   = test ID-kaardid; ASP.NET jookseb Production-modes\n"
        "          (ngrok-i jaoks), aga source-patch tagab test-CA-d ja\n"
        "          test-TSL-i kasutamise (--profile dev on vaikimisi)\n"
        "  prod  = live ID-kaardid; ASP.NET jookseb Production-modes\n"
        "          (loomulik); ts.url ulekirjutamine digidocpp.conf-iga"
    ),
)
_arg_parser.add_argument(
    "--profile",
    choices=["dev", "prod"],
    default="dev",
    help="Kaivitusprofiil: dev (test-kaardid, vaikimisi) voi prod (live-kaardid)",
)
ARGS = _arg_parser.parse_args()
PROFILE = ARGS.profile

# --- UTF-8 konsool ----------------------------------------------------------
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass
    os.system("")  # luliata ANSI varvid Windows Terminal-is

# --- Konfiguratsioon --------------------------------------------------------
HOME = Path.home()
TOOLS_DIR = HOME / "tools"
PROJECTS_DIR = HOME / "projects"
REPO_DIR = PROJECTS_DIR / "web-eid-dotnet"
EXAMPLE_DIR = REPO_DIR / "example" / "src" / "WebEid.AspNetCore.Example"
CSPROJ = EXAMPLE_DIR / "WebEid.AspNetCore.Example.csproj"
SLN = REPO_DIR / "example" / "src" / "WebEid.AspNetCore.Example.sln"
DIGIDOC_DIR = EXAMPLE_DIR / "DigiDoc"
STARTUP_CS = EXAMPLE_DIR / "Startup.cs"
DIGIDOC_CONFIG_CS = EXAMPLE_DIR / "Signing" / "DigiDocConfiguration.cs"
APPSETTINGS_JSON = EXAMPLE_DIR / "appsettings.json"

IS_WINDOWS = sys.platform == "win32"
IS_MACOS = sys.platform == "darwin"

if IS_WINDOWS:
    LIBDIGIDOCPP_BASE = Path(os.environ.get("ProgramFiles", "C:\\Program Files")) / "libdigidocpp"
    NATIVE_LIB_NAME = "digidoc_csharp.dll"
    NGROK_BIN = TOOLS_DIR / "ngrok.exe"
    NGROK_DL_URL = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
    NGROK_ARCHIVE_NAME = "ngrok.zip"
elif IS_MACOS:
    LIBDIGIDOCPP_BASE = Path("/Library/libdigidocpp")
    NATIVE_LIB_NAME = "libdigidoc_csharp.dylib"
    NGROK_BIN = TOOLS_DIR / "ngrok"
    _arch = "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64"
    NGROK_DL_URL = f"https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-{_arch}.tgz"
    NGROK_ARCHIVE_NAME = "ngrok.tgz"
else:
    print("VIGA: see skript on moeldud ainult Windowsile ja macOS-ile.")
    print("Linuxi kasutajatel — kasuta setup-web-eid-dotnet-remote.sh skripti.")
    sys.exit(1)

APP_PORT = 8080
APP_URL_LOCAL = f"http://0.0.0.0:{APP_PORT}"  # mis app kuulab
NGROK_API = "http://localhost:4040/api/tunnels"

# Globaalne ngrok-protsess (suletakse skripti lopus). Python 3.8+ touslikuks
# kasutame lihtsalt None-i ilma tyypide-uniooni-syntaxita.
NGROK_PROC = None

# --- Varvid ----------------------------------------------------------------
G = "\033[1;32m"; Y = "\033[1;33m"; R = "\033[1;31m"; B = "\033[1;34m"; N = "\033[0m"

# --- Abi-funktsioonid -------------------------------------------------------
def step(num: int, total: int, title: str) -> None:
    print(f"\n{G}--- [{num}/{total}] {title} ---{N}")

def info(msg: str) -> None:
    print(f"  {msg}")

def warn(msg: str) -> None:
    print(f"  {Y}HOIATUS:{N} {msg}")

def fail(msg: str, exit_code: int = 1) -> None:
    print(f"\n{R}VIGA:{N} {msg}", file=sys.stderr)
    cleanup_ngrok()
    sys.exit(exit_code)

def cleanup_ngrok():
    """Tapa ngrok-protsess kui see veel jookseb (skripti lopus)."""
    global NGROK_PROC
    if NGROK_PROC and NGROK_PROC.poll() is None:
        info("Tapan ngrok-tunneli...")
        NGROK_PROC.terminate()
        try:
            NGROK_PROC.wait(timeout=3)
        except subprocess.TimeoutExpired:
            NGROK_PROC.kill()
        NGROK_PROC = None

def run(cmd, *, check=True, capture=False, cwd=None, env=None):
    cmd_display = " ".join(str(c) for c in cmd)
    info(f"$ {cmd_display}")
    kwargs = {"check": check, "cwd": cwd, "env": env}
    if capture:
        kwargs["capture_output"] = True
        kwargs["text"] = True
        kwargs["encoding"] = "utf-8"
    return subprocess.run(cmd, **kwargs)

def has_command(name: str) -> bool:
    return shutil.which(name) is not None

def ask_yn(prompt: str, default_yes: bool = True) -> bool:
    default_label = "Y/n" if default_yes else "y/N"
    while True:
        answer = input(f"  {Y}? {prompt} [{default_label}]:{N} ").strip().lower()
        if not answer:
            return default_yes
        if answer in ("y", "yes", "j", "jah"): return True
        if answer in ("n", "no", "ei"): return False
        print("  Vasta 'y' voi 'n' (Enter = vaikimisi)")

def refresh_path_from_registry():
    if not IS_WINDOWS: return
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + "
             "[Environment]::GetEnvironmentVariable('Path','User')"],
            capture_output=True, text=True, encoding="utf-8", check=True,
        )
        new_path = result.stdout.strip()
        if new_path:
            os.environ["PATH"] = new_path
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

def winget_install(package_id: str, friendly_name: str):
    if not IS_WINDOWS:
        fail(f"winget on ainult Windows. Paigalda {friendly_name} kasitsi.")
    if not has_command("winget"):
        fail("winget pole leitav. Uuenda Windows-i App Installer-i Microsoft Store-ist.")
    info(f"Paigaldan {friendly_name} winget-iga...")
    result = run([
        "winget", "install", "--id", package_id, "--source", "winget",
        "--accept-source-agreements", "--accept-package-agreements", "--silent",
    ], check=False)
    OK_EXIT_CODES = {0, 3010, 1641, 2316632107}
    if result.returncode not in OK_EXIT_CODES:
        warn(f"winget exit code {result.returncode} — proovin edasi")
    elif result.returncode == 2316632107:
        info(f"{friendly_name} oli juba paigaldatud")
    refresh_path_from_registry()

# --- 1. .NET 8 SDK ----------------------------------------------------------
def step_dotnet_sdk():
    step(1, 15, ".NET 8 SDK")
    if has_command("dotnet"):
        result = run(["dotnet", "--list-sdks"], capture=True, check=False)
        if result.returncode == 0 and any(l.startswith("8.") for l in result.stdout.splitlines()):
            info(".NET 8 SDK juba paigaldatud")
            run(["dotnet", "--version"])
            return
    info(".NET 8 SDK pole paigaldatud.")
    if not ask_yn("Paigaldada .NET 8 SDK?"):
        fail("Skript vajab .NET 8 SDK-d. Loobun.")
    if IS_WINDOWS:
        winget_install("Microsoft.DotNet.SDK.8", ".NET 8 SDK")
    else:
        if has_command("brew"):
            run(["brew", "install", "--cask", "dotnet-sdk"])
        else:
            fail("macOS-il vajab Homebrew-d. Paigalda: https://brew.sh")

# --- 2. Git -----------------------------------------------------------------
def step_git():
    step(2, 15, "Git")
    if has_command("git"):
        run(["git", "--version"], capture=True)
        info("Git juba paigaldatud")
        return
    if not ask_yn("Paigaldada Git?"): fail("Skript vajab Git-i.")
    if IS_WINDOWS:
        winget_install("Git.Git", "Git for Windows")
    else:
        run(["xcode-select", "--install"], check=False)

# --- 3. libdigidocpp MSI ----------------------------------------------------
def is_libdigidocpp_installed():
    return (LIBDIGIDOCPP_BASE / "include" / "digidocpp_csharp").is_dir()

def step_libdigidocpp():
    step(3, 15, "libdigidocpp (dev-teek, MITTE DigiDoc4 Client)")
    if is_libdigidocpp_installed():
        info(f"libdigidocpp on juba paigaldatud: {LIBDIGIDOCPP_BASE}")
        return
    info("libdigidocpp pole paigaldatud.")
    info("Allikas: https://github.com/open-eid/libdigidocpp/releases (uusim x64.msi)")
    if not IS_WINDOWS:
        fail("macOS libdigidocpp paigaldus pole veel implementeeritud.")
    if not ask_yn("Paigaldada libdigidocpp uusim x64 MSI?"):
        fail("Skript vajab libdigidocpp-d. Loobun.")

    api_url = "https://api.github.com/repos/open-eid/libdigidocpp/releases/latest"
    info(f"Otsin uusima release-i...")
    req = urllib.request.Request(api_url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        release = json.load(response)
    info(f"Uusim release: {release.get('tag_name', '?')}")
    msi_asset = next((a for a in release.get("assets", []) if "x64.msi" in a["name"].lower()), None)
    if not msi_asset:
        fail("Ei leidnud x64.msi-d release-ist.")
    msi_path = TOOLS_DIR / msi_asset["name"]
    size_mb = msi_asset.get("size", 0) // (1024 * 1024)
    info(f"Laen alla: {msi_asset['name']} ({size_mb} MB)")
    urllib.request.urlretrieve(msi_asset["browser_download_url"], msi_path)
    info(f"Paigaldan MSI-d (Windows kysib UAC-loa)...")
    result = subprocess.run(["msiexec", "/i", str(msi_path), "/passive", "/norestart"], check=False)
    if result.returncode not in (0, 3010):
        fail(f"MSI paigaldus ebaonnestus (exit {result.returncode})")
    if not is_libdigidocpp_installed():
        fail(f"libdigidocpp ei leitud {LIBDIGIDOCPP_BASE}")
    info(f"libdigidocpp paigaldatud: {LIBDIGIDOCPP_BASE}")

# --- 4. ngrok download + extract --------------------------------------------
def step_ngrok_install():
    step(4, 15, "ngrok install (download + extract)")
    if NGROK_BIN.is_file():
        info(f"ngrok juba paigaldatud: {NGROK_BIN}")
        # Lisa TOOLS_DIR PATH-i, et `ngrok` kasud tootaksid jooksvas seansis
        if str(TOOLS_DIR) not in os.environ.get("PATH", ""):
            os.environ["PATH"] = f"{TOOLS_DIR}{os.pathsep}{os.environ['PATH']}"
        return
    info(f"Laen ngrok: {NGROK_DL_URL}")
    archive = TOOLS_DIR / NGROK_ARCHIVE_NAME
    urllib.request.urlretrieve(NGROK_DL_URL, archive)
    info(f"Pakin lahti: {archive}")
    if archive.suffix == ".zip":
        import zipfile
        with zipfile.ZipFile(archive) as z:
            z.extractall(TOOLS_DIR)
    else:
        import tarfile
        with tarfile.open(archive) as t:
            t.extractall(TOOLS_DIR)
    archive.unlink()
    if not IS_WINDOWS:
        NGROK_BIN.chmod(0o755)
    # Lisa PATH-i jooksvas seansis
    os.environ["PATH"] = f"{TOOLS_DIR}{os.pathsep}{os.environ['PATH']}"
    info(f"ngrok paigaldatud: {NGROK_BIN}")
    run([str(NGROK_BIN), "version"])

# --- 5. ngrok auth token ----------------------------------------------------
def get_ngrok_config_path() -> Path:
    if IS_WINDOWS:
        return HOME / "AppData" / "Local" / "ngrok" / "ngrok.yml"
    return HOME / "Library" / "Application Support" / "ngrok" / "ngrok.yml"

def step_ngrok_auth():
    step(5, 15, "ngrok auth token")
    config_path = get_ngrok_config_path()
    if config_path.is_file() and "authtoken:" in config_path.read_text(encoding="utf-8", errors="ignore"):
        info(f"ngrok auth-token juba seadistatud: {config_path}")
        if not ask_yn("Soovid uut tokenit lisada (asendab vana)?", default_yes=False):
            return

    info("Vaja ngrok auth-tokenit.")
    info("Tokeni leiad: https://dashboard.ngrok.com/get-started/your-authtoken (tasuta konto piisab).")
    print()
    info("Sisestada saab KOLMEL viisil — vali enda jaoks sobivaim:")
    info("")
    info("  1. ENV-MUUTUJA (kasige, kui scriptid jooksutad mitu korda)")
    info("     cmd:        set NGROK_AUTH_TOKEN=2xxxxx... && setup-web-eid-dotnet-remote.cmd")
    info("     PowerShell: $env:NGROK_AUTH_TOKEN='2xxxxx...'; .\\setup-web-eid-dotnet-remote.cmd")
    info("")
    info("  2. FAILIST (ohutu, paste pole vaja)")
    info(f"     Salvesta token faili: {HOME / 'ngrok-auth-token.txt'}")
    info("     Sisu: AINULT token, ilma ’ngrok config add-authtoken’ kasuta.")
    info("     Pärast esimest jooksu kustuta fail käsitsi (token on juba ngrok.yml-is).")
    info("")
    info("  3. KÄSITSI siia konsooli VARJATUD sisestusega")
    info("     NB! Paste TÖÖTAB, aga ekraanile MIDAGI EI TULE — see on normaalne.")
    info("     Paremklikk paste cmd-aknas / Ctrl+V Windows Terminal-is, siis Enter.")
    info("")

    # 1. Proovi env-muutujat
    token = os.environ.get("NGROK_AUTH_TOKEN", "").strip()
    if token:
        info("Token loetud NGROK_AUTH_TOKEN env-muutujast.")
    else:
        # 2. Proovi failist
        token_file = HOME / "ngrok-auth-token.txt"
        if token_file.is_file():
            token = token_file.read_text(encoding="utf-8").strip()
            info(f"Token loetud failist: {token_file}")
            info(f"NB! Kustuta see fail käsitsi kui pole enam vaja (sisaldab tokeni plaintekstis).")
        else:
            # 3. Käsitsi sisestus — getpass (varjatud).
            # NB! Windows paste-iga: paremklikk cmd-is VOI Ctrl+V Windows Terminal-is.
            # Paste tootab, lihtsalt ekraanile midagi ei kuvata (see ON taotluslik).
            # Kui paste tundub mitte-tootavat → vajuta ikkagi Enter — token on
            # stdin-puhvris ja saadetakse skripti. Kui sisestus on tyhi → fallback
            # nahtav input() (paste-i debugimiseks).
            print()
            try:
                token = getpass.getpass(
                    f"  {Y}? Kleebi token (varjatud — paste tootab kuid ekraanile midagi ei kuvata, siis Enter):{N} "
                ).strip()
            except (EOFError, KeyboardInterrupt):
                fail("Token sisestus katkestatud.")

            # Kui getpass tagastas tyhja (paste reaalselt ei tootanud, voi kasutaja
            # vajutas kogemata Enter), paku nahtavat fallback-i.
            if not token:
                info("Varjatud sisestus oli tyhi. Proovime nahtava sisestusega:")
                info("(NB! Token jaab terminali scrollback-i — kustuta hiljem cmd Clear-iga.)")
                try:
                    token = input(f"  {Y}? Kleebi token (NAHTAV):{N} ").strip()
                except (EOFError, KeyboardInterrupt):
                    fail("Token sisestus katkestatud.")

    if not token or len(token) < 20:
        fail("Token tyhi voi liiga lyhike. Loobun.")

    # NB: ei kasuta run()-i, kuna see trykiks tokeni ekraanile. Skript kutsub
    # subprocess.run otseselt + nakitab info-logist <REDACTED>.
    info("$ ngrok config add-authtoken <REDACTED>")
    result = subprocess.run(
        [str(NGROK_BIN), "config", "add-authtoken", token],
        check=False,
    )
    if result.returncode != 0:
        fail(f"ngrok config add-authtoken ebaonnestus (exit code {result.returncode})")
    info(f"ngrok auth-token salvestatud: {config_path}")
    info("Token on nuud puusivalt ngrok.yml-is, edaspidi pole vaja uuesti sisestada.")

# --- 6. Repo kloonimine -----------------------------------------------------
def step_clone_repo():
    step(6, 15, "Repo kloonimine")
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    if (REPO_DIR / ".git").is_dir():
        info(f"Repo juba olemas: {REPO_DIR}")
        run(["git", "-C", str(REPO_DIR), "checkout", "main"], check=False)
        run(["git", "-C", str(REPO_DIR), "pull", "--ff-only"], check=False)
    else:
        run(["git", "clone",
             "https://github.com/web-eid/web-eid-authtoken-validation-dotnet.git",
             str(REPO_DIR)])

# --- 7. Patch .csproj -------------------------------------------------------
def step_patch_csproj():
    step(7, 15, "WebEid.Security viide (PackageReference -> ProjectReference)")
    if not CSPROJ.is_file():
        fail(f"{CSPROJ} puudub")
    content = CSPROJ.read_text(encoding="utf-8")
    if "ProjectReference" in content and "WebEid.Security.csproj" in content:
        info(f"OK: juba kasutab ProjectReference-i")
        return
    pattern = r'<PackageReference Include="WebEid\.Security" Version="[^"]*" />'
    replacement = '<ProjectReference Include="../../../src/WebEid.Security/WebEid.Security.csproj" />'
    new, count = re.subn(pattern, replacement, content)
    if count == 0:
        fail(f"Ei suutnud PackageReference-i asendada {CSPROJ}-is")
    CSPROJ.write_text(new, encoding="utf-8")
    info(f"OK: {CSPROJ.name} uuendatud")

# --- 8. CA-sertifikaatide kontroll (Dev + Prod kaustad) --------------------
def step_ensure_ca_certs() -> None:
    """Lae alla puuduvad ESTEID CA-sertifikaadid Certificates/Dev/ ja /Prod/ alla.

    Upstream-i repos voivad puududa uuemad CA-d (nt ESTEID2025). Kui kasutaja
    kaart on signeeritud sellise CA-ga, autentimine kukub
    `CertificateNotTrustedException`-iga. See samm tagab, et kaks aktuaalset
    versiooni (2018, 2025) on alati olemas mõlemas kataloogis.
    """
    step(8, 15, "CA-sertifikaatide kontroll (Dev + Prod kaustad)")
    cert_dev = EXAMPLE_DIR / "Certificates" / "Dev"
    cert_prod = EXAMPLE_DIR / "Certificates" / "Prod"
    cert_dev.mkdir(parents=True, exist_ok=True)
    cert_prod.mkdir(parents=True, exist_ok=True)

    # Live CA-d (Prod-kausta) — kasutaja paris ID-kaardi sertifikaadi-vanemad
    live_cas = [
        ("ESTEID2018.cer", "https://c.sk.ee/esteid2018.der.crt"),
        ("ESTEID2025.cer", "https://crt.eidpki.ee/ESTEID2025.crt"),
    ]
    # Test CA-d (Dev-kausta) — test-kaartide sertifikaadi-vanemad
    test_cas = [
        ("TEST_of_ESTEID2018.cer", "https://sk.ee/upload/files/TEST_of_ESTEID2018.der.crt"),
        ("TestESTEID2025.cer", "https://installer.id.ee/media/id2025/TestChain/TestESTEID2025.crt"),
    ]

    def _ensure(name: str, url: str, target_dir: Path, label: str) -> None:
        dst = target_dir / name
        if dst.is_file() and dst.stat().st_size > 0:
            info(f"{label}: {name} juba olemas ({dst.stat().st_size} B)")
            return
        try:
            urllib.request.urlretrieve(url, dst)
            info(f"{label}: {name} alla laaditud ({dst.stat().st_size} B)")
        except Exception as e:
            warn(f"{label}: {name} download ebaonnestus ({e}). Kui sul on selle CA-ga kaart, autentimine voib kukkuda.")

    info("Live CA-d (Prod/):")
    for name, url in live_cas:
        _ensure(name, url, cert_prod, "  Live")
    info("Test CA-d (Dev/):")
    for name, url in test_cas:
        _ensure(name, url, cert_dev, "  Test")


# --- 9. Patch Startup.cs + DigiDocConfiguration.cs (ainult --profile dev) ---
def step_source_patches_dev():
    """Production-modes test-CA-de ja test-TSL-i sundimine — AINULT --profile dev.

    Vajalik kuna ngrok-i jaoks peab ASPNETCORE_ENVIRONMENT olema Production
    (ForwardedHeaders middleware), aga test-kaardid eeldavad Dev-mode konf-i.
    """
    if PROFILE != "dev":
        step(9, 15, "Source-patchid (skipitud — prod-profile ei vaja)")
        info("Prod-profile: live-CA-d ja live-TSL kasutusel — source-patche pole vaja.")
        return

    step(9, 15, "Source-patchid: Startup.cs + DigiDocConfiguration.cs (dev-profile)")

    # Startup.cs — sunni test-CA-de laadimine ka Production-modes
    if STARTUP_CS.is_file():
        content = STARTUP_CS.read_text(encoding="utf-8")
        OLD = "LoadTrustedCaCertificatesFromDisk(CurrentEnvironment.IsDevelopment())"
        NEW = "LoadTrustedCaCertificatesFromDisk(true)"
        if NEW in content:
            info("Startup.cs juba patch-itud (test-CA-d)")
        elif OLD in content:
            STARTUP_CS.write_text(content.replace(OLD, NEW), encoding="utf-8")
            info("Startup.cs patch-itud: test-CA-d ka Production-modes")
        else:
            warn(f"Startup.cs vorming muutunud — ei leidnud '{OLD}'")
    else:
        warn(f"{STARTUP_CS} ei eksisteeri")

    # DigiDocConfiguration.cs — env-var-flag WEBEID_USE_TEST_TSL
    if DIGIDOC_CONFIG_CS.is_file():
        content = DIGIDOC_CONFIG_CS.read_text(encoding="utf-8")
        PATCH_NEW = ('if (env.IsDevelopment() || Environment.GetEnvironmentVariable'
                     '("WEBEID_USE_TEST_TSL") == "true") /* Patched: remote test-TSL flag */')
        if "WEBEID_USE_TEST_TSL" in content:
            info("DigiDocConfiguration.cs juba patch-itud (test-TSL flag)")
        elif "if (env.IsDevelopment())" in content:
            new = content.replace("if (env.IsDevelopment())", PATCH_NEW)
            DIGIDOC_CONFIG_CS.write_text(new, encoding="utf-8")
            info("DigiDocConfiguration.cs patch-itud: WEBEID_USE_TEST_TSL flag")
        else:
            warn(f"DigiDocConfiguration.cs vorming muutunud")
    else:
        warn(f"{DIGIDOC_CONFIG_CS} ei eksisteeri")

# --- 9. Copy .cs files ------------------------------------------------------
def step_copy_cs_bindings():
    step(10, 15, "libdigidocpp C# bindings (.cs failid) projektisse")
    DIGIDOC_DIR.mkdir(parents=True, exist_ok=True)
    cs_source = LIBDIGIDOCPP_BASE / "include" / "digidocpp_csharp"
    if not cs_source.is_dir():
        fail(f"libdigidocpp C# bindings ei leitud: {cs_source}")
    cs_files = list(cs_source.glob("*.cs"))
    for cs_file in cs_files:
        shutil.copy2(cs_file, DIGIDOC_DIR / cs_file.name)
    info(f"C# bindings kopeeritud: {len(cs_files)} faili")

# --- 10. Test-TSL flag (ainult --profile dev) -------------------------------
def step_tsl_flag():
    if PROFILE == "prod":
        step(11, 15, "TSL config (prod-profile — EE_T.xml ei vaja)")
        info("Live-kaardid kasutavad live TSL-i.")
        return
    step(11, 15, "Test-TSL flag (EE_T.xml)")
    if IS_WINDOWS:
        appdata = Path(os.environ.get("APPDATA", HOME / "AppData" / "Roaming"))
        tsl_dir = appdata / "digidocpp" / "tsl"
    else:
        tsl_dir = HOME / ".digidocpp" / "tsl"
    tsl_dir.mkdir(parents=True, exist_ok=True)
    ee_t = tsl_dir / "EE_T.xml"
    ee_t.touch(exist_ok=True)
    info(f"OK: {ee_t}")

# --- 11. Build --------------------------------------------------------------
def step_build():
    step(12, 15, "Ehitamine (dotnet restore + build)")
    build_target = str(SLN) if SLN.is_file() else str(CSPROJ)
    info(f"Build target: {Path(build_target).name}")
    run(["dotnet", "restore", build_target])
    run(["dotnet", "build", build_target, "--configuration", "Debug"])

# --- 12. Start ngrok tunnel + update appsettings.json -----------------------
def step_ngrok_tunnel():
    global NGROK_PROC
    step(13, 15, "ngrok tunnel kaivitamine")
    info(f"Kaivitan: ngrok http {APP_PORT}")
    ngrok_log = TOOLS_DIR / "ngrok.log"
    NGROK_PROC = subprocess.Popen(
        [str(NGROK_BIN), "http", str(APP_PORT), "--log=stdout"],
        stdout=open(ngrok_log, "w"),
        stderr=subprocess.STDOUT,
    )
    info("Ootan ngrok-i tunneli avamist...")
    public_url = None
    for i in range(20):
        time.sleep(1)
        try:
            with urllib.request.urlopen(NGROK_API, timeout=2) as r:
                data = json.load(r)
                for tunnel in data.get("tunnels", []):
                    if tunnel.get("proto") == "https":
                        public_url = tunnel["public_url"]
                        break
            if public_url:
                break
        except Exception:
            pass
    if not public_url:
        # Naita logi sisu, et kasutaja naeks miks ngrok ei toonud (auth-token,
        # network, port-konflikt jms). Logi viimased 1000 baiti — piisav vea jaoks.
        log_tail = ""
        try:
            log_text = ngrok_log.read_text(encoding="utf-8", errors="replace")
            log_tail = log_text[-1000:] if log_text else "(logi tyhi)"
        except Exception as e:
            log_tail = f"(logi lugemine ebaonnestus: {e})"
        fail(
            f"ngrok URL-i ei saadud 20 sek jooksul.\n\n"
            f"=== ngrok.log viimased read ({ngrok_log}) ===\n{log_tail}\n=== logi lopp ===\n\n"
            f"Tavalised pohjused:\n"
            f"  - Auth-token vale voi puudub → jooksuta skripti uuesti, sisesta uus token\n"
            f"  - Port {APP_PORT} juba kasutuses → vabasta voi muuda APP_PORT skriptis\n"
            f"  - Network/firewall blokk → kontrolli VPN-i, ettevotte proksit"
        )
    info(f"ngrok URL: {public_url}")

    # Uuenda appsettings.json
    if not APPSETTINGS_JSON.is_file():
        fail(f"{APPSETTINGS_JSON} puudub")
    content = APPSETTINGS_JSON.read_text(encoding="utf-8")
    new = re.sub(r'"OriginUrl"\s*:\s*"[^"]*"', f'"OriginUrl": "{public_url}"', content)
    APPSETTINGS_JSON.write_text(new, encoding="utf-8")
    info(f"appsettings.json uuendatud: OriginUrl = {public_url}")
    return public_url

# --- 13. Copy native libs + digidocpp.conf (prod) ---------------------------
def step_copy_native_libs():
    step(14, 15, "libdigidocpp natiivteegid build output-i")
    bin_dir = EXAMPLE_DIR / "bin" / "Debug" / "net8.0"
    if not bin_dir.is_dir():
        fail(f"Build output ei eksisteeri: {bin_dir}")
    info(f"Kopeerin: {LIBDIGIDOCPP_BASE} -> {bin_dir}")
    copied = 0
    for item in LIBDIGIDOCPP_BASE.rglob("*"):
        if item.is_file():
            rel = item.relative_to(LIBDIGIDOCPP_BASE)
            if rel.parts and rel.parts[0] == "include":
                continue
            dst = bin_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, dst)
            copied += 1
    info(f"Kopeeritud: {copied} faili")

    if PROFILE == "prod":
        conf_path = bin_dir / "digidocpp.conf"
        conf_path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<configuration>\n'
            '  <param name="ts.url" lock="false">https://eid-dd.ria.ee/ts</param>\n'
            '</configuration>\n',
            encoding="utf-8",
        )
        info(f"Prod-profile: loodud {conf_path} (ts.url = https://eid-dd.ria.ee/ts)")

# --- 14. Run app (ngrok + dotnet) -------------------------------------------
def step_run_app(public_url: str):
    step(15, 15, f"Rakenduse kaivitamine ({public_url})")
    env = os.environ.copy()
    env["ASPNETCORE_ENVIRONMENT"] = "Production"  # alati Production (ngrok ForwardedHeaders)
    env["ASPNETCORE_URLS"] = APP_URL_LOCAL
    if PROFILE == "dev":
        env["WEBEID_USE_TEST_TSL"] = "true"  # aktiveerib test-TSL DigiDocConfiguration.cs-is

    profile_explanation = (
        "test ID-kaardid (test-CA + test-TSL source-patchidega)"
        if PROFILE == "dev"
        else "live ID-kaardid (digidocpp.conf ts.url-iga)"
    )
    print()
    print(f"{G}════════════════════════════════════════════════════════════════{N}")
    print(f"{G}  Brauser:        {public_url}{N}")
    print(f"{G}  ngrok inspector: http://127.0.0.1:4040{N}")
    print(f"{G}  Profile: {PROFILE} ({profile_explanation}){N}")
    print(f"{G}  ASP.NET env: Production (ALATI remote-modes — ngrok-i jaoks){N}")
    print(f"{G}════════════════════════════════════════════════════════════════{N}")
    print()
    print(f"  {Y}Brauser avaneb automaatselt 8 sek parast app-i kaivitust.{N}")
    print(f"  {Y}Peatamiseks: Ctrl+C selles aknas (peatab nii app-i kui ngrok-i).{N}")
    print()

    import threading
    def open_browser_delayed():
        time.sleep(8)
        webbrowser.open(public_url)
    threading.Thread(target=open_browser_delayed, daemon=True).start()

    try:
        run([
            "dotnet", "run", "--project", str(CSPROJ),
            "--configuration", "Debug", "--no-build", "--no-launch-profile",
        ], check=False, env=env)
    except KeyboardInterrupt:
        print("\nRakendus peatatud (Ctrl+C).")
    finally:
        cleanup_ngrok()

# --- Main -------------------------------------------------------------------
def main():
    profile_label = "Production + dev-source-patchid (test ID-kaardid)" if PROFILE == "dev" \
                    else "Production (live ID-kaardid)"
    print(f"{G}=== Web eID .NET naiterakenduse paigaldus + ngrok ==={N}")
    print(f"  Profile:  {PROFILE}  ({profile_label})")
    print(f"  Platvorm: {platform.system()} {platform.machine()}")
    print(f"  Python:   {sys.version.split()[0]}")
    print(f"  Repo:     {REPO_DIR}")
    print(f"  ngrok:    {NGROK_BIN}")
    print()
    TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    refresh_path_from_registry()

    try:
        step_dotnet_sdk()
        step_git()
        step_libdigidocpp()
        step_ngrok_install()
        step_ngrok_auth()
        step_clone_repo()
        step_patch_csproj()
        step_ensure_ca_certs()
        step_source_patches_dev()
        step_copy_cs_bindings()
        step_tsl_flag()
        step_build()
        public_url = step_ngrok_tunnel()
        step_copy_native_libs()
        step_run_app(public_url)
    except KeyboardInterrupt:
        print("\nKatkestatud kasutaja poolt (Ctrl+C).")
        cleanup_ngrok()
        sys.exit(130)
    except subprocess.CalledProcessError as e:
        cleanup_ngrok()
        fail(f"Kask ebaonnestus (exit code {e.returncode}): {' '.join(str(c) for c in e.cmd)}")

if __name__ == "__main__":
    main()
