# Web eID brauserilaienduse versiooni-kontroll - Chrome / Edge (Load unpacked)
#
# Loeb Chrome'i/Edge'i "Load unpacked" abil laetud lahti-pakitud kataloogi
# sisust valja nii laienduse enda versiooni (manifest.json) kui ka bundeldatud
# lib/web-eid.js teegi versiooni (VERSION konstant koodis). Edge kasutab sama
# Chromium-paki - eraldi skripti pole vaja.
#
# Vaikimisi loeb kausta Downloads\chrome\.
#
# Kasutus:
#   .\web-extension-check-chrome.ps1
#   .\web-extension-check-chrome.ps1 -Path C:\teine\path\chrome
#
# Vaikimisi vastus uhel real, sobib otse raportisse:
#   Web eID 2.5.0 (MV3) | web-eid.js 2.1.0 | C:\Users\<sina>\Downloads\chrome

param(
    [string]$Path = "$env:USERPROFILE\Downloads\chrome"
)

if (-not (Test-Path $Path)) {
    Write-Host "VIGA: Kataloogi ei leitud: $Path" -ForegroundColor Red
    Write-Host ""
    Write-Host "Kontrolli, kas Web eID Chrome'i pakk on lahti pakitud sinna."
    Write-Host "Anna teine tee argumendiga: .\web-extension-check-chrome.ps1 -Path C:\... \chrome"
    exit 1
}

$manifestPath = Join-Path $Path "manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Host "VIGA: manifest.json puudub kataloogis $Path" -ForegroundColor Red
    Write-Host "Veendu, et kataloog sisaldab lahtipakitud laienduse faile."
    exit 1
}

$m = Get-Content $manifestPath -Raw | ConvertFrom-Json
$lib = (Get-ChildItem $Path -Recurse -Filter *.js -ErrorAction SilentlyContinue |
        Select-String -Pattern 'VERSION:\s*"([\d.]+)"' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Where-Object { $_ -ne $m.version } |
        Select-Object -First 1)

if (-not $lib) { $lib = "?" }

Write-Host ""
Write-Host "Web eID $($m.version) (MV$($m.manifest_version)) | web-eid.js $lib | $Path"
Write-Host ""
