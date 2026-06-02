# Web eID brauserilaienduse versiooni-kontroll - Firefox (Temporary Add-on)
#
# Loeb Firefoxi Temporary Add-on'ina laetud paki sisust valja nii laienduse
# enda versiooni (manifest.json) kui ka bundeldatud lib/web-eid.js teegi
# versiooni (VERSION konstant koodis). Vaikimisi loeb faili Downloads\firefox.zip.
#
# Kasutus:
#   .\web-extension-check-firefox.ps1
#   .\web-extension-check-firefox.ps1 -Path C:\teine\path\firefox.zip
#
# Vaikimisi vastus uhel real, sobib otse raportisse:
#   Web eID 2.5.0 (MV2) | web-eid.js 2.1.0 | C:\Users\<sina>\Downloads\firefox.zip

param(
    [string]$Path = "$env:USERPROFILE\Downloads\firefox.zip"
)

if (-not (Test-Path $Path)) {
    Write-Host "VIGA: Faili ei leitud: $Path" -ForegroundColor Red
    Write-Host ""
    Write-Host "Kontrolli, kas Web eID Firefoxi pakk (zip) on alla laetud."
    Write-Host "Anna teine tee argumendiga: .\web-extension-check-firefox.ps1 -Path C:\... \firefox.zip"
    exit 1
}

$tmp = "$env:TEMP\webext_check_$([guid]::NewGuid().ToString('N').Substring(0,8))"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem

try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $tmp)
} catch {
    Write-Host "VIGA: Zip-i avamine ebaonnestus: $_" -ForegroundColor Red
    exit 1
}

$manifestPath = Join-Path $tmp "manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Host "VIGA: manifest.json puudub paki seest." -ForegroundColor Red
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$m = Get-Content $manifestPath -Raw | ConvertFrom-Json
$lib = (Get-ChildItem $tmp -Recurse -Filter *.js -ErrorAction SilentlyContinue |
        Select-String -Pattern 'VERSION:\s*"([\d.]+)"' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Where-Object { $_ -ne $m.version } |
        Select-Object -First 1)

if (-not $lib) { $lib = "?" }

Write-Host ""
Write-Host "Web eID $($m.version) (MV$($m.manifest_version)) | web-eid.js $lib | $Path"
Write-Host ""

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
