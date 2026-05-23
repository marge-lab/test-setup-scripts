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

# DigiDoc4 / libdigidocpp natiivteegi vaikimisi paigaldus-asukohad
if IS_WINDOWS:
    DIGIDOC4_CANDIDATES = [
        Path(os.environ.get("ProgramFiles", "C:\\Program Files")) / "DigiDoc4 Client",
        Path("C:\\Program Files\\DigiDoc4 Client"),
        Path("C:\\Program Files\\Open-EID\\DigiDoc4 Client"),
    ]
    NATIVE_LIB_NAME = "digidoc_csharp.dll"  # Windows natiivteek
    APP_URL = "https://localhost:44391"
elif IS_MACOS:
    DIGIDOC4_CANDIDATES = [
        Path("/Library/Frameworks/digidocpp.framework"),
        Path("/opt/homebrew/lib"),         # Homebrew Apple Silicon
        Path("/usr/local/lib"),             # Homebrew Intel
    ]
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


def winget_install(package_id: str, friendly_name: str) -> None:
    """Paigalda pakett winget-iga. Eeldab Windowsit."""
    if not IS_WINDOWS:
        fail(f"winget on ainult Windows. Paigalda {friendly_name} kasitsi.")
    if not has_command("winget"):
        fail("winget pole leitav. Uuenda Windows-i App Installer-i Microsoft Store-ist.")

    info(f"Paigaldan {friendly_name} winget-iga...")
    run([
        "winget", "install",
        "--id", package_id,
        "--source", "winget",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--silent",
    ])


# --- 1. .NET 8 SDK ----------------------------------------------------------
def step_dotnet_sdk() -> None:
    step(1, 9, ".NET 8 SDK")
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
    step(2, 9, "Git")
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


# --- 3. DigiDoc4 Client (libdigidocpp) -------------------------------------
def find_digidoc_native_lib() -> Path:
    """Otsi digidoc_csharp.dll (Windows) voi libdigidoc_csharp.dylib (macOS).

    Tagastab leitud DLL/dylib Path-i, voi tostab erindi kui ei leitud.
    """
    candidates: list[Path] = []
    for base in DIGIDOC4_CANDIDATES:
        if base.is_dir():
            # Otse base-i sees
            direct = base / NATIVE_LIB_NAME
            if direct.is_file():
                candidates.append(direct)
            # Subdir-ides (nt csharp/, lib/)
            for sub in base.rglob(NATIVE_LIB_NAME):
                candidates.append(sub)

    if not candidates:
        raise FileNotFoundError(
            f"Ei leidnud {NATIVE_LIB_NAME}-i. "
            f"Otsitud asukohad: {[str(p) for p in DIGIDOC4_CANDIDATES]}"
        )
    return candidates[0]


def find_digidoc_cs_files() -> Path:
    """Otsi digidoc.cs ja muud C# bindings-failid.

    Tagastab kataloogi, kus need on (mitte fail).
    """
    for base in DIGIDOC4_CANDIDATES:
        if not base.is_dir():
            continue
        for cs_file in base.rglob("digidoc.cs"):
            return cs_file.parent
    raise FileNotFoundError(
        f"Ei leidnud digidoc.cs-faili. "
        f"Otsitud asukohad: {[str(p) for p in DIGIDOC4_CANDIDATES]}"
    )


def step_digidoc4() -> None:
    step(3, 9, "DigiDoc4 Client / libdigidocpp")
    try:
        lib = find_digidoc_native_lib()
        info(f"libdigidocpp natiivteek leitud: {lib}")
        return
    except FileNotFoundError as e:
        info(str(e))

    if IS_WINDOWS:
        info("DigiDoc4 Client pole paigaldatud (voi digidoc_csharp.dll pole bundle-is).")
        info("DigiDoc4 Client on RIA ametlik signeerija — paigaldame winget-iga.")
        if not ask_yn("Paigaldada DigiDoc4 Client?"):
            fail("Skript vajab libdigidocpp-d. Loobun.")
        # RIA ametlik winget-pakett
        winget_install("RIA.DigiDoc4Client", "DigiDoc4 Client")
        info("Kontrolli parast installi kasitsi, et digidoc_csharp.dll leiti.")
        info("Kui mitte — voib-olla pead C# bindings paigaldama eraldi.")
    elif IS_MACOS:
        info("macOS-il vajab libdigidocpp-csharp-i. Eeldab Homebrew-d:")
        info("    brew install --cask digidoc4")
        if not ask_yn("Paigaldada DigiDoc4 brew-ga?"):
            fail("Skript vajab libdigidocpp-d. Loobun.")
        run(["brew", "install", "--cask", "digidoc4"])

    # Veelkord proovi leida
    try:
        lib = find_digidoc_native_lib()
        info(f"libdigidocpp natiivteek leitud: {lib}")
    except FileNotFoundError as e:
        fail(
            f"{e}\n"
            "Kontrolli, kas DigiDoc4 Client sisaldab C# bindings (digidoc_csharp.dll).\n"
            "Monel paigaldusel on need eraldi paketis."
        )


# --- 4. Repo kloonimine -----------------------------------------------------
def step_clone_repo() -> None:
    step(4, 9, "Repo kloonimine")
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
    step(5, 9, "WebEid.Security viide (PackageReference -> ProjectReference)")
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


# --- 6. DigiDoc DLL-id projektisse -----------------------------------------
def step_copy_digidoc_files() -> None:
    step(6, 9, "DigiDoc4 natiivteegid + C# bindings kopeerimine projektisse")
    DIGIDOC_DIR.mkdir(parents=True, exist_ok=True)

    # Natiivteek (DLL / dylib)
    src_lib = find_digidoc_native_lib()
    dst_lib = DIGIDOC_DIR / NATIVE_LIB_NAME
    if dst_lib.is_file():
        info(f"Olemasolev: {dst_lib.name}")
    else:
        shutil.copy2(src_lib, dst_lib)
        info(f"Kopeeritud: {src_lib} → {dst_lib.name}")

    # C# bindings (digidoc.cs jms)
    try:
        cs_dir = find_digidoc_cs_files()
        cs_files = list(cs_dir.glob("*.cs"))
        for cs_file in cs_files:
            dst = DIGIDOC_DIR / cs_file.name
            if not dst.is_file():
                shutil.copy2(cs_file, dst)
        info(f"C# bindings kopeeritud: {len(cs_files)} faili kaustast {cs_dir}")
    except FileNotFoundError as e:
        warn(f"{e}\nKui build kukub `digidoc` namespace puudusega, vajab kasitsi paigaldust.")

    # Directory.Build.props — et .dll/.dylib kopeerituks build-output'i
    build_props = EXAMPLE_DIR / "Directory.Build.props"
    if not build_props.is_file():
        props_content = f"""<Project>
  <ItemGroup>
    <None Update="DigiDoc/{NATIVE_LIB_NAME}">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </None>
  </ItemGroup>
</Project>
"""
        build_props.write_text(props_content, encoding="utf-8")
        info(f"Loodud: {build_props.name} ({NATIVE_LIB_NAME} kopeeritakse build output'i)")
    else:
        info(f"Olemasolev: {build_props.name}")


# --- 7. HTTPS dev-sertifikaat -----------------------------------------------
def step_dev_cert() -> None:
    step(7, 9, "HTTPS dev-sertifikaat (dotnet dev-certs)")
    # `dotnet dev-certs https --trust` lisab Windowsi cert-store-i voi macOS Keychain-i
    run(["dotnet", "dev-certs", "https", "--trust"], check=False)
    info("Dev-sertifikaat usaldatud (vajab voib-olla kasutaja-kinnitust dialoogis).")


# --- 8. Test-TSL flag -------------------------------------------------------
def step_tsl_flag() -> None:
    step(8, 9, "Test-TSL flag (~/.digidocpp/tsl/EE_T.xml)")
    # libdigidocpp loeb TSL cache'i jargmistest kohtadest:
    #   Windows: %LOCALAPPDATA%\digidocpp\tsl\
    #   macOS:   ~/Library/Containers/.../digidocpp/tsl/  VOI ~/.digidocpp/tsl/
    # Konservatiivselt loome MOLEMAD asukohad — libdigidocpp ignoreerib mittekasutatud.
    tsl_dirs = []
    if IS_WINDOWS:
        local_appdata = Path(os.environ.get("LOCALAPPDATA", HOME / "AppData" / "Local"))
        tsl_dirs.append(local_appdata / "digidocpp" / "tsl")
    tsl_dirs.append(HOME / ".digidocpp" / "tsl")

    for tsl_dir in tsl_dirs:
        tsl_dir.mkdir(parents=True, exist_ok=True)
        ee_t = tsl_dir / "EE_T.xml"
        ee_t.touch(exist_ok=True)
        info(f"OK: {ee_t}")

    info("EE_T.xml tuhi fail = libdigidocpp lubab test ID-kaartide sertifikaate.")


# --- 9. Ehitamine + kaivitamine ---------------------------------------------
def step_build_and_run() -> None:
    step(9, 9, "Ehitamine + rakenduse kaivitamine")

    build_target = str(SLN) if SLN.is_file() else str(CSPROJ)
    info(f"Build target: {Path(build_target).name}")

    # Restore
    run(["dotnet", "restore", build_target])
    # Build
    run(["dotnet", "build", build_target, "--configuration", "Debug"])

    # Kaivitamine
    print()
    print(f"{G}════════════════════════════════════════════════════════════════{N}")
    print(f"{G}  Kaivitan rakenduse: {APP_URL}{N}")
    print(f"{G}════════════════════════════════════════════════════════════════{N}")
    print()
    print(f"  {Y}Brauser avaneb automaatselt 5 sek parast app-i kaivitust.{N}")
    print(f"  {Y}Peatamiseks: Ctrl+C selles aknas.{N}")
    print()

    # Kaivita app foreground-is, et logi oleks SAMAS aknas reaalajas naha.
    # Brauseri avamiseks spawn-ime taustal luhikese viite jarel.
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
        ], check=False)
    except KeyboardInterrupt:
        print("\nRakendus peatatud (Ctrl+C).")


# --- Main -------------------------------------------------------------------
def main() -> None:
    print(f"{G}=== Web eID .NET naiterakenduse paigaldus ==={N}")
    print(f"  Platvorm: {platform.system()} {platform.machine()}")
    print(f"  Python:   {sys.version.split()[0]}")
    print(f"  Kodukaust: {HOME}")
    print(f"  Tools:    {TOOLS_DIR}")
    print(f"  Repo:     {REPO_DIR}")
    print()

    TOOLS_DIR.mkdir(parents=True, exist_ok=True)

    try:
        step_dotnet_sdk()
        step_git()
        step_digidoc4()
        step_clone_repo()
        step_patch_csproj()
        step_copy_digidoc_files()
        step_dev_cert()
        step_tsl_flag()
        step_build_and_run()
    except KeyboardInterrupt:
        print("\nKatkestatud kasutaja poolt (Ctrl+C).")
        sys.exit(130)
    except subprocess.CalledProcessError as e:
        fail(f"Kask ebaonnestus (exit code {e.returncode}): {' '.join(str(c) for c in e.cmd)}")


if __name__ == "__main__":
    main()
