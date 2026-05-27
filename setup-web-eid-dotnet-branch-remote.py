#!/usr/bin/env python3
"""
Web eID .NET haru-test + ngrok (remote) -- Windows / macOS.

Erinevus setup-web-eid-dotnet-remote.py-st (main-haru):
  - Kasutaja saab valida haru (--branch arg voi interaktiivne menuu)
  - WebEid.Security ehitatakse LOKAALSE NuGet-paketi-na 1.2.0-beta1
  - example .csproj kasutab PackageReference (lokaalsele NuGet-le)

Muu logika sama mis main-remote:
  - ngrok-tunneli kaudu kuvatakse rakendus HTTPS-iga internetti
  - ASPNETCORE_ENVIRONMENT=Production alati (UseForwardedHeaders)
  - --profile dev: source-patch test-CA-d ja test-TSL Production-modes
  - --profile prod: digidocpp.conf ts.url-iga (live-kaardid)

Kasutus:
   Windows:  setup-web-eid-dotnet-branch-remote.cmd
             setup-web-eid-dotnet-branch-remote.cmd --branch HARU
             python setup-web-eid-dotnet-branch-remote.py [--branch HARU] [--profile dev|prod]
   macOS:    python3 setup-web-eid-dotnet-branch-remote.py [--branch HARU] [--profile dev|prod]

Sotluvused: ainult Python stdlib.
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
_arg_parser.add_argument(
    "--branch",
    default=None,
    help="Haru nimi (substring match). Kui puudub, kysitakse interaktiivselt.",
)
ARGS = _arg_parser.parse_args()
PROFILE = ARGS.profile
BRANCH_ARG = ARGS.branch

# Lokaalse NuGet-paketi versioon — eristub upstream GitLab-i versioonist.
NUGET_VERSION = "1.2.0-beta1"

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
LOCAL_NUGET = TOOLS_DIR / "local-nuget"

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
    step(1, 18, ".NET 8 SDK")
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
    step(2, 18, "Git")
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
    step(3, 18, "libdigidocpp (dev-teek, MITTE DigiDoc4 Client)")
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
    step(4, 18, "ngrok install (download + extract)")
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
    step(5, 18, "ngrok auth token")
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

# --- 6. Repo kloonimine + haru valimine -------------------------------------
def _list_recent_branches() -> list:
    result = subprocess.run(
        ["git", "-C", str(REPO_DIR), "for-each-ref",
         "--sort=-committerdate", "--count=20",
         "--format=%(refname:short)", "refs/remotes/origin/"],
        capture_output=True, check=False, text=True, encoding="utf-8",
    )
    if result.returncode != 0:
        return []
    branches = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line == "origin/HEAD" or line == "origin/main":
            continue
        if line.startswith("origin/"):
            branches.append(line[len("origin/"):])
        if len(branches) >= 10:
            break
    return branches


def _select_branch_interactive() -> str:
    branches = _list_recent_branches()
    if not branches:
        warn("Ei suutnud harude nimekirja tuua — sisesta haru-nimi kasitsi.")
        return input("Haru: ").strip()
    print()
    print(f"{G}Vali haru (viimati uuendatud):{N}")
    for i, br in enumerate(branches, 1):
        print(f"  {i:2d}. {br}")
    print(f"   m. main (vaikimisi)")
    print(f"   k. kasitsi sisestamine")
    while True:
        choice = input(f"Valik [1-{len(branches)}/m/k]: ").strip().lower()
        if choice in ("", "m"):
            return "main"
        if choice == "k":
            return input("Haru: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(branches):
            return branches[int(choice) - 1]
        print(f"  Vigane valik, proovi uuesti.")


def step_clone_repo():
    step(6, 18, "Repo kloonimine + haru valimine")
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    if (REPO_DIR / ".git").is_dir():
        info(f"Repo juba olemas: {REPO_DIR}")
        info("Uuendan origin-i (git fetch)...")
        run(["git", "-C", str(REPO_DIR), "fetch", "origin", "--prune"], check=False)
    else:
        run(["git", "clone",
             "https://github.com/web-eid/web-eid-authtoken-validation-dotnet.git",
             str(REPO_DIR)])

    # Haru valimine
    if BRANCH_ARG:
        result = subprocess.run(
            ["git", "-C", str(REPO_DIR), "branch", "-a"],
            capture_output=True, check=True, text=True, encoding="utf-8",
        )
        candidates = []
        for line in result.stdout.splitlines():
            br = line.strip().lstrip("* ").strip()
            if br.startswith("remotes/origin/"):
                br = br[len("remotes/origin/"):]
            if br == "HEAD" or "->" in br:
                continue
            if BRANCH_ARG in br:
                candidates.append(br)
        unique = list(dict.fromkeys(candidates))
        if not unique:
            fail(f"Ei leidnud uhtegi haru millele '{BRANCH_ARG}' sobiks.")
        if len(unique) > 1:
            warn(f"Mitu sobivat haru leiti: {', '.join(unique)}")
            print("Vali tapne haru:")
            for i, b in enumerate(unique, 1):
                print(f"  {i}. {b}")
            idx = int(input(f"Valik [1-{len(unique)}]: ").strip())
            branch = unique[idx - 1]
        else:
            branch = unique[0]
    else:
        branch = _select_branch_interactive()

    info(f"Valitud haru: {Y}{branch}{N}")
    # Viska eelmise jooksu .csproj-patch (samm 6) ara, muidu git checkout keeldub
    # ("Your local changes ... would be overwritten by checkout"). Patch tehakse hiljem uuesti.
    run(["git", "-C", str(REPO_DIR), "checkout", "--", "."], check=False)
    run(["git", "-C", str(REPO_DIR), "checkout", branch])
    run(["git", "-C", str(REPO_DIR), "pull", "--ff-only"], check=False)


# --- 7. Lokaalne NuGet build (WebEid.Security 1.2.0-beta1) ------------------
def step_local_nuget_build():
    step(7, 18, f"Lokaalne NuGet build (WebEid.Security {NUGET_VERSION})")
    sec_proj = REPO_DIR / "src" / "WebEid.Security" / "WebEid.Security.csproj"
    if not sec_proj.is_file():
        fail(f"WebEid.Security.csproj puudub: {sec_proj}")

    for sub in (REPO_DIR / "src").rglob("obj"):
        if sub.is_dir():
            shutil.rmtree(sub, ignore_errors=True)
    for sub in (REPO_DIR / "src").rglob("bin"):
        if sub.is_dir():
            shutil.rmtree(sub, ignore_errors=True)

    if LOCAL_NUGET.exists():
        shutil.rmtree(LOCAL_NUGET, ignore_errors=True)
    LOCAL_NUGET.mkdir(parents=True, exist_ok=True)

    run([
        "dotnet", "build", "--configuration", "Release", "--verbosity", "quiet",
        f"-p:Version={NUGET_VERSION}",
        f"-p:PackageVersion={NUGET_VERSION}",
        str(sec_proj),
    ])

    nupkg = sec_proj.parent / "bin" / "Release" / f"WebEid.Security.{NUGET_VERSION}.nupkg"
    if not nupkg.is_file():
        fail(f"Lokaalne .nupkg ei tekkinud: {nupkg}")
    shutil.copy2(nupkg, LOCAL_NUGET / nupkg.name)
    info(f"OK: lokaalne NuGet pakett: {nupkg.name}")
    info(f"Asukoht: {LOCAL_NUGET}")

    subprocess.run(
        ["dotnet", "nuget", "remove", "source", "WebEid-Local"],
        capture_output=True, check=False,
    )
    run(["dotnet", "nuget", "add", "source", str(LOCAL_NUGET), "--name", "WebEid-Local"])


# --- 8. Patch .csproj -------------------------------------------------------
def step_patch_csproj():
    step(8, 18, f"WebEid.Security viide → PackageReference {NUGET_VERSION}")
    if not CSPROJ.is_file():
        fail(f"{CSPROJ} puudub")
    content = CSPROJ.read_text(encoding="utf-8")
    target = f'<PackageReference Include="WebEid.Security" Version="{NUGET_VERSION}" />'
    if target in content:
        info(f"OK: juba kasutab PackageReference {NUGET_VERSION}")
        return
    pat_project = r'<ProjectReference Include="[^"]*WebEid\.Security\.csproj"\s*/>'
    pat_package = r'<PackageReference Include="WebEid\.Security" Version="[^"]*"\s*/>'
    new_content, count_p = re.subn(pat_project, target, content)
    new_content, count_k = re.subn(pat_package, target, new_content)
    if count_p + count_k == 0:
        fail(f"Ei suutnud {CSPROJ.name}-is WebEid.Security viidet asendada.")
    CSPROJ.write_text(new_content, encoding="utf-8")
    info(f"OK: {CSPROJ.name} uuendatud — PackageReference WebEid.Security {NUGET_VERSION}")

# --- 8. CA-sertifikaatide kontroll (Dev + Prod kaustad) --------------------
def step_ensure_ca_certs() -> None:
    """Lae alla puuduvad ESTEID CA-sertifikaadid Certificates/Dev/ ja /Prod/ alla.

    Upstream-i repos voivad puududa uuemad CA-d (nt ESTEID2025). Kui kasutaja
    kaart on signeeritud sellise CA-ga, autentimine kukub
    `CertificateNotTrustedException`-iga. See samm tagab, et kaks aktuaalset
    versiooni (2018, 2025) on alati olemas mõlemas kataloogis.
    """
    step(9, 18, "CA-sertifikaatide kontroll (Dev + Prod kaustad)")
    cert_dev = EXAMPLE_DIR / "Certificates" / "Dev"
    cert_prod = EXAMPLE_DIR / "Certificates" / "Prod"
    cert_dev.mkdir(parents=True, exist_ok=True)
    cert_prod.mkdir(parents=True, exist_ok=True)

    # Live CA-d (Prod-kausta) — kasutaja paris ID-kaardi sertifikaadi-vanemad.
    # ESTEID2018 = SK ID Solutions AS-i CA, mis signeeris kaardid kuni
    # 2025 novembrini (IDEMIA kaardid). ESTEID2025 = uus CA, mida SK kasutab
    # alates 2025 novembrist (uled minek Zetes-Thales kaartidele).
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


# --- 10. Certificates/ inspection (uus) -----------------------------------
def _git_status_files(subdir):
    """Tagasta dict {relative_path: status_char} subdir-i kohta."""
    if not subdir.is_dir():
        return {}
    files = {}
    for p in subdir.rglob("*"):
        if p.is_file():
            rel = p.relative_to(REPO_DIR)
            files[str(rel).replace("\\", "/")] = " "
    res = subprocess.run(
        ["git", "-C", str(REPO_DIR), "status", "--porcelain=v1", "--",
         str(subdir.relative_to(REPO_DIR)).replace("\\", "/")],
        capture_output=True, check=False, text=True, encoding="utf-8",
    )
    if res.returncode == 0:
        for line in res.stdout.splitlines():
            if len(line) < 4:
                continue
            x_y = line[:2]
            path = line[3:].strip()
            if x_y == "??":
                files[path] = "?"
            elif "M" in x_y:
                files[path] = "M"
            elif "A" in x_y:
                files[path] = "A"
            elif "!" in x_y:
                files[path] = "!"
    return files


def step_inspect_certificates():
    """Naita branch-i Certificates/Prod ja Certificates/Dev sisu (source-pool).

    NB! See on SOURCE-vaade (mida git checkout andis), MITTE bin-vaade.
    bin/Certificates/-i naitab samm 18 lopubanner pohja peal (disk-kontroll).
    """
    step(10, 18, "Certificates/Prod + Certificates/Dev kontroll (source)")
    cert_prod = EXAMPLE_DIR / "Certificates" / "Prod"
    cert_dev = EXAMPLE_DIR / "Certificates" / "Dev"

    def _print_dir(label, dir_path):
        print()
        print(f"  {B}{label}: {dir_path}{N}")
        if not dir_path.is_dir():
            print(f"    (kausta pole)")
            return
        files = _git_status_files(dir_path)
        if not files:
            print(f"    (kaust on tyhi)")
            return
        for path, status in sorted(files.items()):
            name = Path(path).name
            if status == "?":
                tag = f"{Y}untracked{N} (jaanuk eelmisest jooksust voi step_ensure_ca_certs download)"
            elif status == "M":
                tag = f"{Y}modified{N}"
            elif status == "A":
                tag = f"{Y}added (staged){N}"
            elif status == "!":
                tag = f"{R}ignored{N}"
            else:
                tag = f"{G}tracked (haru osa){N}"
            print(f"    {name:40s}  {tag}")

    _print_dir("Live CA-d (Prod/)", cert_prod)
    _print_dir("Test CA-d (Dev/)", cert_dev)
    print()
    info(f"NB! See on SOURCE-vaade. Lopubanner naitab mis joudis BIN-i (runtime).")


# --- 11. Patch Startup.cs + DigiDocConfiguration.cs (ainult --profile dev) ---
def step_source_patches_dev():
    """Production-modes test-CA-de ja test-TSL-i sundimine — AINULT --profile dev.

    Vajalik kuna ngrok-i jaoks peab ASPNETCORE_ENVIRONMENT olema Production
    (ForwardedHeaders middleware), aga test-kaardid eeldavad Dev-mode konf-i.

    NB! Esmalt taastame Startup.cs ja DigiDocConfiguration.cs git HEAD-ist.
    Põhjus: kui kasutaja jooksis varem --profile dev ja siis vahetas
    --profile prod-iks, jäi Startup.cs-i `LoadTrustedCaCertificatesFromDisk(true)`
    (test-CA-de laadimine). Tagajärg: prod-profile-i ajal laaditi
    Certificates/Dev/ kausta test-CA-d, mitte Certificates/Prod/ live-CA-d.
    Live-kaardi autentimine kukub CertificateNotTrustedException-iga, kuigi
    cert-failid ja chain on õiged.
    """
    step(11, 18, "Source-patchid: Startup.cs + DigiDocConfiguration.cs")

    # Taasta lähekood git HEAD-ist (eemaldab eelmise profile-i jäänukid)
    for f in (STARTUP_CS, DIGIDOC_CONFIG_CS):
        if f.is_file():
            result = subprocess.run(
                ["git", "-C", str(REPO_DIR), "checkout", "HEAD", "--", str(f)],
                capture_output=True, check=False, text=True,
            )
            if result.returncode == 0:
                info(f"Taastatud git HEAD-ist: {f.name}")
            else:
                warn(f"git checkout {f.name} ebaõnnestus: {result.stderr.strip()}")

    if PROFILE != "dev":
        info("Prod-profile: live-CA-d ja live-TSL kasutusel — source-patche pole vaja.")
        return

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


# --- 12. CertificateLoader.cs + .csproj patchid (log-tostuse jaoks) --------
def step_instrument_cert_loader():
    """Lisa Console.WriteLine CertificateLoader.cs-i + .csproj cer-copy direktiiv.

    Pohjus: upstream CertificateLoader.cs EI logi sertide laadimist. Test-
    raportite jaoks on vaja log-tostust ('CertificateLoader luges molemad cer-failid
    sisse'). Lisaks: kui Certificates/Prod/ voi Dev/ sisaldab uusi cer-faile aga
    .csproj-i pole copy-direktiivi olemas, MSBuild ei kopeeri neid bin-i ja
    app ei loe neid.

    Sammud:
      1. Reverti CertificateLoader.cs git HEAD-ist (eelmise jooksu patch tagasi)
      2. Lisa CertificateLoader.cs-i Console.WriteLine per loaded cert
      3. Kontrolli .csproj-i; lisa cer-copy direktiiv kui puudub
    """
    step(12, 18, "CertificateLoader.cs instrumenteerimine + .csproj cer-copy")

    cert_loader = EXAMPLE_DIR / "Certificates" / "CertificateLoader.cs"

    if cert_loader.is_file():
        result = subprocess.run(
            ["git", "-C", str(REPO_DIR), "checkout", "HEAD", "--", str(cert_loader)],
            capture_output=True, check=False, text=True,
        )
        if result.returncode == 0:
            info(f"Taastatud git HEAD-ist: {cert_loader.name}")
    else:
        warn(f"{cert_loader} puudub -- ei saa instrumenteerida")
        return

    content = cert_loader.read_text(encoding="utf-8")
    OLD_BODY = (
        "            return new FileReader(GetCertPath(isTest), \"*.cer\").ReadFiles()\n"
        "                .Select(file => new X509Certificate2(file))\n"
        "                .ToArray();"
    )
    NEW_BODY = (
        "            var path = GetCertPath(isTest);\n"
        "            System.Console.WriteLine($\"[CertificateLoader] Loading from: {path}\");\n"
        "            var certs = new FileReader(path, \"*.cer\").ReadFiles()\n"
        "                .Select(file => new X509Certificate2(file))\n"
        "                .ToArray();\n"
        "            foreach (var c in certs) System.Console.WriteLine($\"[CertificateLoader] Loaded: Subject={c.Subject}, NotAfter={c.NotAfter:yyyy-MM-dd}\");\n"
        "            return certs;"
    )
    if "[CertificateLoader] Loaded:" in content:
        info("CertificateLoader.cs juba instrumenteeritud")
    elif OLD_BODY in content:
        cert_loader.write_text(content.replace(OLD_BODY, NEW_BODY), encoding="utf-8")
        info("CertificateLoader.cs instrumenteeritud (Console.WriteLine per laaditud cer)")
    else:
        warn("CertificateLoader.cs vorming muutunud -- ei suutnud patchida")

    csproj_content = CSPROJ.read_text(encoding="utf-8")
    has_copy_directive = (
        'Update="Certificates\\**\\*.cer"' in csproj_content
        or 'Update="Certificates/**/*.cer"' in csproj_content
    )
    if has_copy_directive:
        info(".csproj juba sisaldab Certificates/**/*.cer copy-direktiivi")
    else:
        insert = (
            '  <ItemGroup>\n'
            '    <None Update="Certificates/**/*.cer">\n'
            '      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>\n'
            '    </None>\n'
            '  </ItemGroup>\n'
            '</Project>'
        )
        new_csproj = csproj_content.replace('</Project>', insert)
        if new_csproj == csproj_content:
            warn(".csproj-is </Project> tag-i ei leitud -- ei suutnud patchida")
        else:
            CSPROJ.write_text(new_csproj, encoding="utf-8")
            info(".csproj patchitud: Certificates/**/*.cer kopeeritakse bin-i")


# --- 13. Copy .cs files ------------------------------------------------------
def step_copy_cs_bindings():
    step(13, 18, "libdigidocpp C# bindings (.cs failid) projektisse")
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
        step(14, 18, "TSL config (prod-profile — EE_T.xml ei vaja)")
        info("Live-kaardid kasutavad live TSL-i.")
        return
    step(14, 18, "Test-TSL flag (EE_T.xml)")
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
    step(15, 18, "Ehitamine (dotnet restore + build)")

    # Tapa kõik vanad WebEid.AspNetCore.Example protsessid mis eelmistest käivitustest
    # alles ja hoiavad bin/Debug/net8.0/*.dll faile lukus. Ilma selleta kukub build
    # MSB3027 (Could not copy ... file is locked) veaga.
    if platform.system() == "Windows":
        subprocess.run(
            ["taskkill", "/F", "/IM", "WebEid.AspNetCore.Example.exe"],
            capture_output=True, check=False,
        )
    else:
        subprocess.run(["pkill", "-f", "WebEid.AspNetCore.Example"], check=False)

    build_target = str(SLN) if SLN.is_file() else str(CSPROJ)
    info(f"Build target: {Path(build_target).name}")
    # NB: --no-incremental sunnib dotnet build-i alati taasehitama. Vajalik kui
    # step_ensure_ca_certs (samm 8) on hiljuti lisanud uue CA-faili — incremental
    # build voib vaata, et "lahtekood ei muutunud" ja ei kopeeri uut .cer-i bin
    # output-i. Tagajarg: app loeb vana CA-listi ja autentimine kukub
    # CertificateNotTrustedException-iga, hoolimata sellest, et fail on
    # source-Certificates/Prod/-is olemas.
    run(["dotnet", "restore", build_target])
    run(["dotnet", "build", build_target, "--configuration", "Debug", "--no-incremental"])

# --- 12. Start ngrok tunnel + update appsettings.json -----------------------
def step_ngrok_tunnel():
    global NGROK_PROC
    step(16, 18, "ngrok tunnel kaivitamine")
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
    step(17, 18, "libdigidocpp natiivteegid build output-i")
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

# --- Sertide laadimise verifitseerija (DISK-pohine, profile-agnostiline) ----
CERT_ERROR_RE = re.compile(
    r'(CryptographicException|X509Certificate\w*Exception|'
    r'FileNotFoundException[^\n]*\.cer|Unhandled exception)',
    re.IGNORECASE,
)
APP_START_RE = re.compile(r'Now listening on|Application started')
ANSI_RE = re.compile(r'\x1b\[[0-9;]*m')


def _list_cert_files(dir_path):
    if not dir_path.is_dir():
        return None
    return sorted(dir_path.glob("*.cer"))


def _emit(line, logf=None):
    """Tryki rida konsooli (varvidega) ja kui logf antud, ka faili (ilma ANSI)."""
    print(line)
    if logf is not None:
        clean = ANSI_RE.sub('', line)
        logf.write(clean + '\n')
        logf.flush()


def _print_cert_verification(errors, bin_dir, log_file, logf=None):
    """Trukk verifitseerimise banneri konsooli + valikuliselt logi-faili."""
    cert_prod = bin_dir / "Certificates" / "Prod"
    cert_dev = bin_dir / "Certificates" / "Dev"

    _emit("", logf)
    _emit(f"{B}=================================================================={N}", logf)
    _emit(f"{B}  SERTIDE LAADIMISE KONTROLL (profile={PROFILE}){N}", logf)
    _emit(f"{B}=================================================================={N}", logf)

    if errors:
        _emit(f"  {R}EXCEPTION-EID LEITUD logist (sertide laadimine kukkus?):{N}", logf)
        for line in errors[:5]:
            _emit(f"    {R}{line[:200]}{N}", logf)
        if len(errors) > 5:
            _emit(f"    {R}... veel {len(errors) - 5} viga (vaata logi: {log_file}){N}", logf)
    else:
        _emit(f"  {G}OK -- exception-eid puuduvad (app kaivitus normaalselt){N}", logf)

    _emit("", logf)
    _emit(f"  {B}Build-output-is deploitud CA-failid:{N}", logf)

    prod_files = _list_cert_files(cert_prod)
    _emit(f"  Live CA-d  ({cert_prod}):", logf)
    if prod_files is None:
        _emit(f"    {R}(kausta pole olemas -- build kukkus?){N}", logf)
    elif not prod_files:
        _emit(f"    {Y}(tyhi){N}", logf)
    else:
        for c in prod_files:
            _emit(f"    {c.name:40s} {c.stat().st_size} B", logf)

    dev_files = _list_cert_files(cert_dev)
    _emit(f"  Test CA-d  ({cert_dev}):", logf)
    if dev_files is None:
        _emit(f"    {Y}(kausta pole olemas){N}", logf)
    elif not dev_files:
        _emit(f"    {Y}(tyhi){N}", logf)
    else:
        for c in dev_files:
            _emit(f"    {c.name:40s} {c.stat().st_size} B", logf)

    # Profile-spetsiifiline jareldus
    _emit("", logf)
    if PROFILE == "dev":
        _emit(f"  {B}--profile dev: app loeb test-CA-d Dev/-st{N}", logf)
        test_thales = cert_dev / "TestESTEID2025.cer"
        if test_thales.is_file() and test_thales.stat().st_size > 0:
            _emit(f"  {G}>>> Dev/TestESTEID2025.cer ON OLEMAS ({test_thales.stat().st_size} B){N}", logf)
            _emit(f"  {G}    Test Thales-kaart peaks autentimisel TOOLE HAKKAMA.{N}", logf)
        else:
            _emit(f"  {R}>>> Dev/TestESTEID2025.cer PUUDUB{N}", logf)
            _emit(f"  {R}    Test Thales-kaart autentides KUKUB.{N}", logf)
    else:  # prod
        _emit(f"  {B}--profile prod: app loeb live-CA-d Prod/-st{N}", logf)
        live_thales = cert_prod / "ESTEID2025.cer"
        if live_thales.is_file() and live_thales.stat().st_size > 0:
            _emit(f"  {G}>>> Prod/ESTEID2025.cer ON OLEMAS ({live_thales.stat().st_size} B){N}", logf)
            _emit(f"  {G}    Live Thales-kaart peaks autentimisel TOOLE HAKKAMA.{N}", logf)
        else:
            _emit(f"  {R}>>> Prod/ESTEID2025.cer PUUDUB{N}", logf)
            _emit(f"  {R}    Live Thales-kaart autentides KUKUB.{N}", logf)

    _emit(f"{B}=================================================================={N}", logf)
    _emit("", logf)


def _stream_with_cert_check(proc, logf, log_file, bin_dir):
    """Loe dotnet run stdout rida-haaval, kirjuta konsooli + faili, jalgi vigu."""
    cert_error_lines = []
    verification_printed = False

    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        logf.write(line)

        if verification_printed:
            continue

        if CERT_ERROR_RE.search(line):
            cert_error_lines.append(line.rstrip())
        if APP_START_RE.search(line):
            _print_cert_verification(cert_error_lines, bin_dir, log_file, logf)
            verification_printed = True

    if not verification_printed:
        _emit("", logf)
        _emit(f"  {R}HOIATUS: app ei joudnud 'Now listening on' faasi -- startup kukkus?{N}", logf)
        _print_cert_verification(cert_error_lines, bin_dir, log_file, logf)


# --- 18. Run app (ngrok + dotnet) -------------------------------------------
def step_run_app(public_url: str):
    step(18, 18, f"Rakenduse kaivitamine ({public_url})")
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
    log_file = TOOLS_DIR / "dotnet-app.log"
    print()
    print(f"{G}════════════════════════════════════════════════════════════════{N}")
    print(f"{G}  Brauser:        {public_url}{N}")
    print(f"{G}  ngrok inspector: http://127.0.0.1:4040{N}")
    print(f"{G}  Profile: {PROFILE} ({profile_explanation}){N}")
    print(f"{G}  ASP.NET env: Production (ALATI remote-modes — ngrok-i jaoks){N}")
    print(f"{G}  Live-logi fail: {log_file}{N}")
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

    cmd = [
        "dotnet", "run", "--project", str(CSPROJ),
        "--configuration", "Debug", "--no-build", "--no-launch-profile",
    ]
    info(f"$ {' '.join(cmd)}")
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=str(EXAMPLE_DIR),
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    bin_dir = EXAMPLE_DIR / "bin" / "Debug" / "net8.0"
    try:
        with open(log_file, "w", encoding="utf-8", buffering=1) as logf:
            _stream_with_cert_check(proc, logf, log_file, bin_dir)
    except KeyboardInterrupt:
        print("\nRakendus peatatud (Ctrl+C).")
        proc.terminate()
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        cleanup_ngrok()

# --- Main -------------------------------------------------------------------
def main():
    profile_label = "Production + dev-source-patchid (test ID-kaardid)" if PROFILE == "dev" \
                    else "Production (live ID-kaardid)"
    print(f"{G}=== Web eID .NET naiterakenduse paigaldus + ngrok (haru-test) ==={N}")
    print(f"  Profile:  {PROFILE}  ({profile_label})")
    if BRANCH_ARG:
        print(f"  Haru:     {BRANCH_ARG}  (--branch argumendist)")
    else:
        print(f"  Haru:     valitakse interaktiivselt sammus 6")
    print(f"  NuGet:    WebEid.Security {NUGET_VERSION} (lokaalne)")
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
        step_clone_repo()             # NEW: + haru valimine
        step_local_nuget_build()      # NEW: WebEid.Security → 1.2.0-beta1.nupkg
        step_patch_csproj()           # NEW: PackageReference 1.2.0-beta1
        step_ensure_ca_certs()
        step_inspect_certificates()       # NEW: source Certificates/ kontroll
        step_source_patches_dev()
        step_instrument_cert_loader()     # NEW: CertificateLoader log + .csproj cer-copy
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
