#!/usr/bin/env python3
"""
Web eID .NET naiterakenduse paigaldus — main haru (Windows / macOS).

Kasutus:
   Windows:  setup-web-eid-dotnet.cmd          (eelistatud — kontrollib Pythoni)
             python setup-web-eid-dotnet.py    (otse, kui Python juba paigaldatud)
   macOS:    python3 setup-web-eid-dotnet.py

Skript:
  1. Kontrollib + paigaldab .NET 8 SDK (kui pole)
  2. Kontrollib + paigaldab Git (kui pole)
  3. Kontrollib DigiDoc4 Client paigalduse (libdigidocpp DLL-ide jaoks)
  4. Kloonib `web-eid-authtoken-validation-dotnet` repo
  5. Patchib example .csproj: PackageReference WebEid.Security → ProjectReference
  6. Kopeerib DigiDoc4 natiivteegi DLL-id projektisse
  7. Seadistab HTTPS dev-sertifikaadi (dotnet dev-certs https --trust)
  8. Loob test-TSL flag-faili (~/.digidocpp/tsl/EE_T.xml)
  9. Ehitab + kaivitab rakenduse (https://localhost:44391)

Toetab Windows 10/11 ja macOS-i (Apple Silicon + Intel). Linux on parem
katta .sh-skriptiga (setup-web-eid-dotnet.sh).

Soltuvused: ainult Python stdlib (urllib, subprocess, pathlib, shutil).
EI vaja `pip install` kasku.
"""

import argparse
import json
import os
import platform
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
    description="Web eID .NET naiterakenduse paigaldus (Windows / macOS)",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=(
        "Profiilid:\n"
        "  dev   = ASPNETCORE_ENVIRONMENT=Development (test ID-kaardid, vaikimisi)\n"
        "  prod  = ASPNETCORE_ENVIRONMENT=Production  (live ID-kaardid;\n"
        "          loob bin/Debug/net8.0/digidocpp.conf ts.url-iga\n"
        "          https://eid-dd.ria.ee/ts (RIA test-TSA — paid kontaktita))"
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

# --- UTF-8 konsool (Windows cp1252 valtimine) -------------------------------
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass
    # Lulita ANSI varvid sisse Windows Terminal-is (cmd.exe vanas tagasiuhilduvuse režiimis)
    os.system("")

# --- Konfiguratsioon --------------------------------------------------------
HOME = Path.home()
TOOLS_DIR = HOME / "tools"
PROJECTS_DIR = HOME / "projects"
REPO_DIR = PROJECTS_DIR / "web-eid-dotnet"
EXAMPLE_DIR = REPO_DIR / "example" / "src" / "WebEid.AspNetCore.Example"
CSPROJ = EXAMPLE_DIR / "WebEid.AspNetCore.Example.csproj"
SLN = REPO_DIR / "example" / "src" / "WebEid.AspNetCore.Example.sln"
DIGIDOC_DIR = EXAMPLE_DIR / "DigiDoc"

IS_WINDOWS = sys.platform == "win32"
IS_MACOS = sys.platform == "darwin"

# libdigidocpp dev-teegi paigaldus-asukohad
# NB: libdigidocpp on DEVELOPER-teek, EI OLE sama mis DigiDoc4 Client
# (kasutaja-tarkvara allkirjastamiseks). .NET naidisrakendus vajab
# libdigidocpp-d (sealhulgas C# bindings include/digidocpp_csharp).
# Allikas: https://github.com/open-eid/libdigidocpp/releases (x64.msi)
if IS_WINDOWS:
    LIBDIGIDOCPP_BASE = Path(os.environ.get("ProgramFiles", "C:\\Program Files")) / "libdigidocpp"
    NATIVE_LIB_NAME = "digidoc_csharp.dll"  # Windows natiivteek
    APP_URL = "https://localhost:44391"
elif IS_MACOS:
    # TODO: macOS-il libdigidocpp tavaliselt brew-ga voi DigiDoc4 paigaldusega.
    # Vajab testimist enne kasutamist.
    LIBDIGIDOCPP_BASE = Path("/Library/libdigidocpp")
    NATIVE_LIB_NAME = "libdigidoc_csharp.dylib"
    APP_URL = "https://localhost:44391"
else:
    print("VIGA: see skript on moeldud ainult Windowsile ja macOS-ile.")
    print("Linuxi kasutajatel — kasuta setup-web-eid-dotnet.sh skripti.")
    sys.exit(1)

# --- Varvid (ANSI) ---------------------------------------------------------
G = "\033[1;32m"  # roheline-paks
Y = "\033[1;33m"  # kollane-paks
R = "\033[1;31m"  # punane-paks
B = "\033[1;34m"  # sinine-paks
N = "\033[0m"     # reset


# --- Abi-funktsioonid -------------------------------------------------------
def step(num: int, total: int, title: str) -> None:
    print(f"\n{G}--- [{num}/{total}] {title} ---{N}")


def info(msg: str) -> None:
    print(f"  {msg}")


def warn(msg: str) -> None:
    print(f"  {Y}HOIATUS:{N} {msg}")


def fail(msg: str, exit_code: int = 1) -> None:
    print(f"\n{R}VIGA:{N} {msg}", file=sys.stderr)
    sys.exit(exit_code)


def run(cmd, *, check: bool = True, capture: bool = False, cwd=None, env=None):
    """Kaivita kask. Tagastab subprocess.CompletedProcess.

    Kui capture=False — valjund laheb otse konsooli.
    Kui capture=True — valjund tagastatakse stdout/stderr atribuutides.
    """
    cmd_display = " ".join(str(c) for c in cmd)
    info(f"$ {cmd_display}")
    kwargs = {"check": check, "cwd": cwd, "env": env}
    if capture:
        kwargs["capture_output"] = True
        kwargs["text"] = True
        kwargs["encoding"] = "utf-8"
    try:
        return subprocess.run(cmd, **kwargs)
    except subprocess.CalledProcessError as e:
        if capture and e.stdout:
            print(e.stdout)
        if capture and e.stderr:
            print(e.stderr, file=sys.stderr)
        raise


def has_command(name: str) -> bool:
    """Kas kask on PATH-is leitav."""
    return shutil.which(name) is not None


def ask_yn(prompt: str, default_yes: bool = True) -> bool:
    """Y/N kusimus. Tuhi sisend (Enter) = default."""
    default_label = "Y/n" if default_yes else "y/N"
    while True:
        answer = input(f"  {Y}? {prompt} [{default_label}]:{N} ").strip().lower()
        if not answer:
            return default_yes
        if answer in ("y", "yes", "j", "jah"):
            return True
        if answer in ("n", "no", "ei"):
            return False
        print("  Vasta 'y' voi 'n' (Enter = vaikimisi)")


def refresh_path_from_registry() -> None:
    """Varskenda os.environ['PATH']-i Windows registry-st.

    Vajalik parast winget install-i, kuna jooksvas Python-protsessis on
    PATH cache-itud Pythoni kaivitumise ajast. Ilma selleta uus rakendus
    (nt dotnet, git) ei oleks `shutil.which`-le nahtav, isegi kui winget
    on selle juba paigaldanud.
    """
    if not IS_WINDOWS:
        return
    try:
        ps_cmd = (
            "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + "
            "[Environment]::GetEnvironmentVariable('Path','User')"
        )
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_cmd],
            capture_output=True, text=True, encoding="utf-8", check=True,
        )
        new_path = result.stdout.strip()
        if new_path:
            os.environ["PATH"] = new_path
            info("PATH varskendatud registry-st (winget-i installid nyyd nahtaval)")
    except (subprocess.CalledProcessError, FileNotFoundError):
        warn("PATH-i varskendamine ebaonnestus — vaja voib olla skripti restart.")


def winget_install(package_id: str, friendly_name: str) -> None:
    """Paigalda pakett winget-iga. Eeldab Windowsit."""
    if not IS_WINDOWS:
        fail(f"winget on ainult Windows. Paigalda {friendly_name} kasitsi.")
    if not has_command("winget"):
        fail("winget pole leitav. Uuenda Windows-i App Installer-i Microsoft Store-ist.")

    info(f"Paigaldan {friendly_name} winget-iga...")
    result = run([
        "winget", "install",
        "--id", package_id,
        "--source", "winget",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--silent",
    ], check=False)
    # winget exit code-id:
    #   0     = success
    #   3010  = success, reboot vajalik
    #   1641  = success
    #   2316632107 (0x8A15002B) = APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
    #                              (juba paigaldatud, mitte error)
    OK_EXIT_CODES = {0, 3010, 1641, 2316632107}
    if result.returncode not in OK_EXIT_CODES:
        warn(f"winget exit code {result.returncode} — proovin edasi (PATH refresh + re-check)")
    elif result.returncode == 2316632107:
        info(f"{friendly_name} oli juba paigaldatud")
    # Parast install-i varskenda PATH-i, et jargmised sammud naeksid uut kasku.
    refresh_path_from_registry()


# --- 1. .NET 8 SDK ----------------------------------------------------------
def step_dotnet_sdk() -> None:
    step(1, 10, ".NET 8 SDK")
    if has_command("dotnet"):
        try:
            result = run(["dotnet", "--list-sdks"], capture=True, check=False)
            if result.returncode == 0 and any(
                line.startswith("8.") for line in result.stdout.splitlines()
            ):
                info(".NET 8 SDK juba paigaldatud")
                run(["dotnet", "--version"])
                return
        except FileNotFoundError:
            pass

    info(".NET 8 SDK pole paigaldatud.")
    if not ask_yn("Paigaldada .NET 8 SDK?"):
        fail("Skript vajab .NET 8 SDK-d. Loobun.")

    if IS_WINDOWS:
        winget_install("Microsoft.DotNet.SDK.8", ".NET 8 SDK")
        info("NB! Parast paigaldust voib olla vajalik uus konsool, et PATH varskeneks.")
    elif IS_MACOS:
        if has_command("brew"):
            run(["brew", "install", "--cask", "dotnet-sdk"])
        else:
            fail("macOS-il vajab Homebrew (brew). Paigalda esmalt: https://brew.sh")


# --- 2. Git -----------------------------------------------------------------
def step_git() -> None:
    step(2, 10, "Git")
    if has_command("git"):
        result = run(["git", "--version"], capture=True)
        info(result.stdout.strip())
        return

    info("Git pole paigaldatud.")
    if not ask_yn("Paigaldada Git?"):
        fail("Skript vajab Git-i. Loobun.")

    if IS_WINDOWS:
        winget_install("Git.Git", "Git for Windows")
    elif IS_MACOS:
        run(["xcode-select", "--install"], check=False)
        info("Kui XCode Command Line Tools dialoog avanes — kinnita ja oota loppu.")


# --- 3. libdigidocpp (dev-teek) --------------------------------------------
def is_libdigidocpp_installed() -> bool:
    """Kas libdigidocpp on paigaldatud ootuspärasele asukohale?"""
    cs_dir = LIBDIGIDOCPP_BASE / "include" / "digidocpp_csharp"
    return cs_dir.is_dir()


def download_latest_libdigidocpp_msi() -> Path:
    """Lae alla uusim libdigidocpp x64 MSI GitHub releases-ist.

    Tagastab kohaliku faili Path-i.
    """
    api_url = "https://api.github.com/repos/open-eid/libdigidocpp/releases/latest"
    info(f"Otsin uusima release-i: {api_url}")
    req = urllib.request.Request(api_url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        release = json.load(response)

    info(f"Uusim release: {release.get('tag_name', '?')}")
    msi_asset = None
    for asset in release.get("assets", []):
        name = asset["name"].lower()
        if "x64.msi" in name or ("x64" in name and name.endswith(".msi")):
            msi_asset = asset
            break

    if not msi_asset:
        names = [a["name"] for a in release.get("assets", [])]
        fail(f"Ei leidnud x64.msi faili release-ist. Saadaval: {names}")

    msi_path = TOOLS_DIR / msi_asset["name"]
    size_mb = msi_asset.get("size", 0) // (1024 * 1024)
    info(f"Laen alla: {msi_asset['name']} ({size_mb} MB)")
    urllib.request.urlretrieve(msi_asset["browser_download_url"], msi_path)
    info(f"Allalaaditud: {msi_path}")
    return msi_path


def step_libdigidocpp() -> None:
    step(3, 10, "libdigidocpp (dev-teek, MITTE DigiDoc4 Client)")

    if is_libdigidocpp_installed():
        info(f"libdigidocpp on juba paigaldatud: {LIBDIGIDOCPP_BASE}")
        return

    info("libdigidocpp pole paigaldatud.")
    info("")
    info("NB! See EI OLE sama mis DigiDoc4 Client (kasutaja-tarkvara).")
    info("    DigiDoc4 Client = GUI signeerija lopptarbijale")
    info("    libdigidocpp    = developer-teek, mida vajab .NET naiterakendus")
    info("    Need ON KAKS ERINEVAT paigaldust, hoolimata sarnasest nimest.")
    info("")
    info("Allikas: https://github.com/open-eid/libdigidocpp/releases (uusim x64.msi)")

    if not IS_WINDOWS:
        info("macOS-il: vajab kontrollimist (tavaliselt brew voi DigiDoc4 paigaldus).")
        fail("macOS libdigidocpp paigaldus pole veel implementeeritud.")

    if not ask_yn("Paigaldada libdigidocpp uusim x64 MSI?"):
        fail("Skript vajab libdigidocpp-d. Loobun.")

    msi_path = download_latest_libdigidocpp_msi()

    info("Paigaldan MSI-d (Windows kysib UAC-loa — kinnita 'Yes')...")
    # /passive = progress-bar UI, ei vaja kasutaja-klikke (peale UAC-loa).
    # /norestart = ei taaskaivita arvutit installi lopus.
    # 0 = success, 3010 = success+reboot vajalik.
    result = subprocess.run(
        ["msiexec", "/i", str(msi_path), "/passive", "/norestart"],
        check=False,
    )
    if result.returncode not in (0, 3010):
        fail(
            f"MSI paigaldus ebaonnestus (exit code {result.returncode}). "
            f"Proovi kasitsi: msiexec /i {msi_path}"
        )
    if result.returncode == 3010:
        warn("Paigaldus korras, kuid soovitatav on Windows taaskaivitada.")

    if not is_libdigidocpp_installed():
        fail(
            f"libdigidocpp paigaldus ei leitud asukohas {LIBDIGIDOCPP_BASE}. "
            "Kontrolli kasitsi."
        )
    info(f"libdigidocpp paigaldatud: {LIBDIGIDOCPP_BASE}")


# --- 4. Repo kloonimine -----------------------------------------------------
def step_clone_repo() -> None:
    step(4, 10, "Repo kloonimine")
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)

    if (REPO_DIR / ".git").is_dir():
        info(f"Repo juba olemas: {REPO_DIR}")
        info("Uuendan main-haru...")
        run(["git", "-C", str(REPO_DIR), "checkout", "main"], check=False)
        run(["git", "-C", str(REPO_DIR), "pull", "--ff-only"], check=False)
    else:
        run([
            "git", "clone",
            "https://github.com/web-eid/web-eid-authtoken-validation-dotnet.git",
            str(REPO_DIR),
        ])


# --- 5. .csproj patch -------------------------------------------------------
def step_patch_csproj() -> None:
    step(5, 10, "WebEid.Security viide (PackageReference -> ProjectReference)")
    if not CSPROJ.is_file():
        fail(f"{CSPROJ} puudub (repo struktuur muutunud?)")

    content = CSPROJ.read_text(encoding="utf-8")
    if "ProjectReference" in content and "WebEid.Security.csproj" in content:
        info(f"OK: {CSPROJ.name} juba kasutab ProjectReference-i (lokaalne lahtekood)")
        return

    import re
    pattern = r'<PackageReference Include="WebEid\.Security" Version="[^"]*" />'
    replacement = (
        '<ProjectReference Include="../../../src/WebEid.Security/WebEid.Security.csproj" />'
    )
    new_content, count = re.subn(pattern, replacement, content)
    if count == 0:
        fail(
            f"Ei suutnud {CSPROJ.name}-is PackageReference-i asendada. "
            "Toenaoliselt upstream-i vorming muutunud (nt multi-line). Vaata kasitsi."
        )
    CSPROJ.write_text(new_content, encoding="utf-8")
    info(f"OK: {CSPROJ.name} uuendatud — ProjectReference WebEid.Security")


# --- 6. C# bindings projektisse (.cs failid) -------------------------------
def step_copy_cs_bindings() -> None:
    """Kopeeri libdigidocpp C# bindings projekt-i DigiDoc/ kausta.

    Ametlik juhend (Windows):
      copy "C:\\Program Files\\libdigidocpp\\include\\digidocpp_csharp" DigiDoc

    .cs failid lahevad PROJEKTI SOURCE-kausta (DigiDoc/), sest neid
    kompileeritakse rakendusse. Natiivteegid (DLL-id, schema/) laevad
    eraldi sammus parast build-i (vt step_copy_native_libs).
    """
    step(6, 10, "libdigidocpp C# bindings (.cs failid) projektisse")
    DIGIDOC_DIR.mkdir(parents=True, exist_ok=True)

    cs_source = LIBDIGIDOCPP_BASE / "include" / "digidocpp_csharp"
    if not cs_source.is_dir():
        fail(
            f"libdigidocpp C# bindings ei leitud: {cs_source}. "
            "Kas paigaldus on korralik?"
        )
    cs_files = list(cs_source.glob("*.cs"))
    if not cs_files:
        fail(f"Ei leidnud .cs faile asukohas {cs_source}")
    for cs_file in cs_files:
        dst = DIGIDOC_DIR / cs_file.name
        shutil.copy2(cs_file, dst)
    info(f"C# bindings kopeeritud DigiDoc/-i: {len(cs_files)} faili")


# --- 7. HTTPS dev-sertifikaat -----------------------------------------------
def step_dev_cert() -> None:
    step(7, 10, "HTTPS dev-sertifikaat (dotnet dev-certs)")
    # `dotnet dev-certs https --trust` lisab Windowsi cert-store-i voi macOS Keychain-i
    run(["dotnet", "dev-certs", "https", "--trust"], check=False)
    info("Dev-sertifikaat usaldatud (vajab voib-olla kasutaja-kinnitust dialoogis).")


# --- 8. Test-TSL flag (ainult dev-profile) ----------------------------------
def step_tsl_flag() -> None:
    if PROFILE == "prod":
        step(8, 10, "TSL config (prod-profile — EE_T.xml ei vaja)")
        info("Live-kaardid kasutavad live TSL-i. EE_T.xml-i ei loo.")
        info("ts.url ulekirjutamine prod-TSA-le toimub sammus 10 (digidocpp.conf).")
        return

    step(8, 10, "Test-TSL flag (EE_T.xml)")
    # libdigidocpp loeb TSL cache'i:
    #   Windows: %APPDATA%\digidocpp\tsl\   (Roaming AppData, NB! mitte %LOCALAPPDATA%)
    #   macOS:   ~/Library/Containers/.../digidocpp/tsl/  VOI ~/.digidocpp/tsl/
    # Ametlik juhend (Windows): mkdir %appdata%\digidocpp\tsl
    if IS_WINDOWS:
        appdata = Path(os.environ.get("APPDATA", HOME / "AppData" / "Roaming"))
        tsl_dir = appdata / "digidocpp" / "tsl"
    else:
        tsl_dir = HOME / ".digidocpp" / "tsl"

    tsl_dir.mkdir(parents=True, exist_ok=True)
    ee_t = tsl_dir / "EE_T.xml"
    ee_t.touch(exist_ok=True)
    info(f"OK: {ee_t}")
    info("EE_T.xml tuhi fail = libdigidocpp lubab test ID-kaartide sertifikaate.")


# --- 9. Build (dotnet restore + build) -------------------------------------
def step_build() -> None:
    step(9, 10, "Ehitamine (dotnet restore + build)")
    build_target = str(SLN) if SLN.is_file() else str(CSPROJ)
    info(f"Build target: {Path(build_target).name}")
    run(["dotnet", "restore", build_target])
    run(["dotnet", "build", build_target, "--configuration", "Debug"])


# --- 10. Kopeeri libdigidocpp natiivteegid + schema → bin/, käivita ---------
def step_copy_native_libs_and_run() -> None:
    """Kopeeri libdigidocpp DLL-id + schema/ kausta bin/Debug/net8.0/ ja
    kaivita rakendus.

    Ametlik juhend (Windows):
      xcopy /s "C:\\Program Files\\libdigidocpp\\" bin\\Debug\\net8.0
      (Lisaks: schema-kaust)

    NB: see toimub PARAST build-i, et build ei kustutaks neid faile.
    Build loob bin/Debug/net8.0/ kataloogi ja paneb .exe + .dll sinna —
    libdigidocpp natiivteegid lisame siia pPRAST seda.
    """
    step(10, 10, "libdigidocpp natiivteegid build output-i + kaivitamine")

    bin_dir = EXAMPLE_DIR / "bin" / "Debug" / "net8.0"
    if not bin_dir.is_dir():
        fail(f"Build output ei eksisteeri: {bin_dir} (build vist ebaonnestus)")

    info(f"Kopeerin libdigidocpp failid: {LIBDIGIDOCPP_BASE} → {bin_dir}")
    # rglob koik failid (sh schema/ alamkataloog), kopeeri suhteline strukt.
    copied = 0
    for item in LIBDIGIDOCPP_BASE.rglob("*"):
        if item.is_file():
            rel = item.relative_to(LIBDIGIDOCPP_BASE)
            # Vahele jata include/-kaust (need on .cs failid, juba kopeeritud sammus 6)
            if rel.parts and rel.parts[0] == "include":
                continue
            dst = bin_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, dst)
            copied += 1
    info(f"Natiivteegid + schema/ kopeeritud: {copied} faili")

    # Prod-profile: loo digidocpp.conf ts.url ulekirjutamisega
    # Variant 2 ametlikust libdigidocpp juhendist — vahistab source-patche.
    # ts.url = https://eid-dd.ria.ee/ts on RIA test-TSA (sobib testimiseks
    # ilma paid SK-kontaktita). Pidev prod-keskkonna jaoks vaheta SK live TSA-le.
    if PROFILE == "prod":
        conf_path = bin_dir / "digidocpp.conf"
        conf_content = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<configuration>\n'
            '  <param name="ts.url" lock="false">https://eid-dd.ria.ee/ts</param>\n'
            '</configuration>\n'
        )
        conf_path.write_text(conf_content, encoding="utf-8")
        info(f"Prod-profile: loodud {conf_path}")
        info("  ts.url = https://eid-dd.ria.ee/ts (RIA test-TSA)")

    # Maara ASPNETCORE_ENVIRONMENT vastavalt profiilile
    env = os.environ.copy()
    if PROFILE == "prod":
        env["ASPNETCORE_ENVIRONMENT"] = "Production"
        env_label = "Production"
    else:
        env["ASPNETCORE_ENVIRONMENT"] = "Development"
        env_label = "Development"

    # Kaivitamine
    print()
    print(f"{G}════════════════════════════════════════════════════════════════{N}")
    print(f"{G}  Kaivitan rakenduse: {APP_URL}{N}")
    print(f"{G}  Profile: {PROFILE} (ASPNETCORE_ENVIRONMENT={env_label}){N}")
    print(f"{G}════════════════════════════════════════════════════════════════{N}")
    print()
    print(f"  {Y}Brauser avaneb automaatselt 8 sek parast app-i kaivitust.{N}")
    print(f"  {Y}Peatamiseks: Ctrl+C selles aknas.{N}")
    print()

    import threading
    def open_browser_delayed():
        time.sleep(8)
        webbrowser.open(APP_URL)
    threading.Thread(target=open_browser_delayed, daemon=True).start()

    try:
        run([
            "dotnet", "run",
            "--project", str(CSPROJ),
            "--configuration", "Debug",
            "--no-build",  # ei taasehitata — siis ei kustutata kopeeritud natiivteege
        ], check=False, env=env)
    except KeyboardInterrupt:
        print("\nRakendus peatatud (Ctrl+C).")


# --- Main -------------------------------------------------------------------
def main() -> None:
    profile_label = "Production (live ID-kaardid)" if PROFILE == "prod" else "Development (test ID-kaardid)"
    print(f"{G}=== Web eID .NET naiterakenduse paigaldus ==={N}")
    print(f"  Profile:  {PROFILE}  ({profile_label})")
    print(f"  Platvorm: {platform.system()} {platform.machine()}")
    print(f"  Python:   {sys.version.split()[0]}")
    print(f"  Kodukaust: {HOME}")
    print(f"  Tools:    {TOOLS_DIR}")
    print(f"  Repo:     {REPO_DIR}")
    print()

    TOOLS_DIR.mkdir(parents=True, exist_ok=True)

    # Varskenda PATH-i registry-st kohe skripti alguses. Windows Terminal
    # emaprotsess voib hoida vana PATH-i (enne winget install-e). Refresh
    # tagab, et `has_command(...)` naeb koiki juba-paigaldatud rakendusi.
    refresh_path_from_registry()

    try:
        step_dotnet_sdk()
        step_git()
        step_libdigidocpp()
        step_clone_repo()
        step_patch_csproj()
        step_copy_cs_bindings()      # .cs failid → DigiDoc/ (enne build-i)
        step_dev_cert()
        step_tsl_flag()
        step_build()                 # dotnet restore + build
        step_copy_native_libs_and_run()  # DLL-id + schema → bin/, dotnet run
    except KeyboardInterrupt:
        print("\nKatkestatud kasutaja poolt (Ctrl+C).")
        sys.exit(130)
    except subprocess.CalledProcessError as e:
        fail(f"Kask ebaonnestus (exit code {e.returncode}): {' '.join(str(c) for c in e.cmd)}")


if __name__ == "__main__":
    main()
