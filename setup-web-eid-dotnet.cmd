@echo off
REM ============================================================
REM Web eID .NET naiterakenduse paigaldus -- Windows entry point
REM
REM See .cmd-fail on lihtsalt kaivitaja: kontrollib, kas Python
REM on paigaldatud, ja kui pole, pakub winget-iga installimist.
REM Tegelik too toimub `setup-web-eid-dotnet.py`-failis.
REM
REM Kasutus:
REM   1. Topeltklikk failil, VOI
REM   2. cmd-aknas:  setup-web-eid-dotnet.cmd
REM
REM Toetatud: Windows 10/11 (UTF-8 console codepage 65001).
REM ============================================================

setlocal enabledelayedexpansion
chcp 65001 >nul

REM Otsi Python 3.x -- eelista `py` launcher-it, siis `python`.
set PYTHON_CMD=
where py >nul 2>&1
if !errorlevel! equ 0 (
    py -3 --version >nul 2>&1
    if !errorlevel! equ 0 set PYTHON_CMD=py -3
)
if "!PYTHON_CMD!"=="" (
    where python >nul 2>&1
    if !errorlevel! equ 0 (
        python --version >nul 2>&1
        if !errorlevel! equ 0 set PYTHON_CMD=python
    )
)

if "!PYTHON_CMD!"=="" (
    echo.
    echo ================================================================
    echo  Python pole paigaldatud
    echo ================================================================
    echo.
    echo  Skript vajab Python 3.8+ versiooni.
    echo  Paigaldame selle winget-iga ^(Microsoft ametlik tarkvarahaldur^):
    echo.
    echo    winget install --id Python.Python.3.12
    echo.
    choice /C YN /M "Paigaldada Python nuud"
    if errorlevel 2 (
        echo.
        echo Loobutud. Paigalda Python kasitsi ja proovi uuesti:
        echo   https://www.python.org/downloads/
        pause
        exit /b 1
    )

    echo.
    echo Paigaldan Python 3.12-t winget-iga ^(voib kesta umbes 1 min^)...
    winget install --id Python.Python.3.12 --source winget --accept-source-agreements --accept-package-agreements
    if !errorlevel! neq 0 (
        echo VIGA: winget-paigaldus ebaonnestus. Paigalda Python kasitsi:
        echo   https://www.python.org/downloads/
        pause
        exit /b 1
    )

    echo.
    echo Python paigaldatud. Varskenda PATH-i jooksvas seansis...

    REM Loe PATH registry-st (winget on selle just varskenanud), kirjuta
    REM jooksva cmd-i muutujasse. Ilma selleta peaks kasutaja restart-ima
    REM cmd-akna (vana PATH oli mallu salvestatud cmd-i kaivitumise ajal).
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"`) do set "PATH=%%i"

    REM Re-check Python — kas nyyd PATH-is olemas?
    set PYTHON_CMD=
    where py >nul 2>&1
    if !errorlevel! equ 0 (
        py -3 --version >nul 2>&1
        if !errorlevel! equ 0 set PYTHON_CMD=py -3
    )
    if "!PYTHON_CMD!"=="" (
        where python >nul 2>&1
        if !errorlevel! equ 0 (
            python --version >nul 2>&1
            if !errorlevel! equ 0 set PYTHON_CMD=python
        )
    )

    if "!PYTHON_CMD!"=="" (
        echo.
        echo HOIATUS: PATH-i varskendamine ei onnestunud. Tee jargmist:
        echo   1. Sulge see aken ^(X paremalt yleval^)
        echo   2. Ava UUS cmd-aken Start-menyyst
        echo   3. Kaivita skript uuesti: .\setup-web-eid-dotnet.cmd
        echo.
        pause
        exit /b 0
    )

    echo PATH varskendatud. Python leitud: !PYTHON_CMD!
    echo.
)

REM Python leitud -- kaivita peamine .py-skript.
echo Python leitud: !PYTHON_CMD!
echo Kaivitan setup-web-eid-dotnet.py...
echo.
!PYTHON_CMD! "%~dp0setup-web-eid-dotnet.py" %*

set RC=!errorlevel!
echo.
if !RC! neq 0 (
    echo Skript loppes veaga ^(exit code !RC!^).
) else (
    echo Skript lopetatud edukalt.
)
pause
exit /b !RC!
