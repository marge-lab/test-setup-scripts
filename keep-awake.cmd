@echo off
REM ===========================================================================
REM keep-awake.cmd
REM
REM Hoiab Windowsi masina arkvel: lulitab valja ekraanisaastja, ekraani-
REM uneoleku, susteemi-sleep-i, kettama-spin-down-i ja auto-hibernate-i.
REM Moeldud Windowsi test-VM-idele ja test-masinadelle, mis muidu lulituvad
REM jouude olles automaatselt valja voi lukustuvad.
REM
REM Vastab Linux-versiooni keep-awake.sh-le.
REM
REM Kasutus:  topeltklikk faili peal, VOI cmd-aknas: .\keep-awake.cmd
REM
REM Ei vaja administraator-iguseid. Toetatud: Windows 10/11.
REM ===========================================================================

setlocal enabledelayedexpansion
chcp 65001 >nul

echo ==^> Seadistan power-timeout-id mitte-lulituvaks (AC = vooluvork, DC = aku)...

REM Ekraan ei lulitu valja (0 = mitte kunagi)
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0

REM Susteem ei lahe sleep-i
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0

REM Ketas ei lahe spin-down-i (HDD magama)
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0

REM Hibernation-timeout = 0 (auto-hibernate ei aktiveeru)
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0

echo.
echo ==^> Lulitan ekraanisaastja valja (HKCU registry)...
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f >nul
reg add "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure /t REG_SZ /d 0 /f >nul
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveTimeOut /t REG_SZ /d 0 /f >nul

echo.
echo ==^> Kontroll (kogu Current AC/DC vaartused peavad olema 0x00000000):
echo.
echo   Ekraan (monitor-timeout):
powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | findstr /i "Current AC Current DC"
echo.
echo   Susteem (standby-timeout):
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | findstr /i "Current AC Current DC"
echo.
echo   Ketas (disk-timeout):
powercfg /query SCHEME_CURRENT SUB_DISK DISKIDLE | findstr /i "Current AC Current DC"

echo.
echo Valmis. Oodatud: koik vaartused = 0x00000000 (mitte kunagi).
echo.
echo MARKMED:
echo  - Hiberneerimise TAIELIKUKS valja-lulitamiseks (kustutab hiberfil.sys-i^)
echo    ava cmd "Run as administrator" ja kaivita:  powercfg /hibernate off
echo  - Vaikeseadete taastamiseks: Windowsi Settings ^> System ^> Power ^& battery
echo  - Praegu konfigureeritud profiili nimi:
powercfg /list | findstr /i "*"

echo.
pause
