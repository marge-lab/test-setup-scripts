# test-setup-scripts

Paigaldus- ja seadistus-skriptid Linux VM-i kiireks ülesseadmiseks
testimistöö jaoks.

Skriptid jagunevad kahte rühma:

1. **Web eID näidisrakendused** — PHP, Java, .NET (main-haru ja harude testimine)
2. **Muud testimisskriptid** — VMware shared folder, GNOME ekraanisäästja keelamine

---

# Web eID näidisrakendused

Skriptid kloonivad [web-eid](https://github.com/web-eid)
organisatsioonist vastava `web-eid-authtoken-validation-*` repo,
ehitavad näiterakenduse ja käivitavad. Kõik avavad lõpus eraldi
terminaliakna **live-logiga** (rakenduse päringud, sertide laadimine,
OCSP/TSA tegevused reaalajas).

## Main-haru skriptid

Repo `main`-harust ehitatud rakendused — sobivad reliisi-testimiseks.

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-web-eid-php.sh`](setup-web-eid-php.sh) | Web eID PHP näiterakendus | Ubuntu |
| [`setup-web-eid-java.sh`](setup-web-eid-java.sh) | Web eID Java näiterakendus (ngrok-iga) | Ubuntu, macOS |
| [`setup-web-eid-dotnet.sh`](setup-web-eid-dotnet.sh) | Web eID .NET näiterakendus (lokaalne) | Ubuntu |
| [`setup-web-eid-dotnet-remote.sh`](setup-web-eid-dotnet-remote.sh) | Web eID .NET näiterakendus + ngrok (avalik HTTPS) | Ubuntu |

<details>
<summary><b>PHP — Ubuntu</b></summary>

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-php.sh
chmod +x setup-web-eid-php.sh
bash setup-web-eid-php.sh
```

</details>

<details>
<summary><b>Java — Ubuntu</b></summary>

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-java.sh
chmod +x setup-web-eid-java.sh
bash setup-web-eid-java.sh
```

**Eeldused:** Java-skript vajab ngrok auth tokenit (küsitakse sammus 3/7).
Tee endale tasuta konto ja kopeeri token:
<https://dashboard.ngrok.com/get-started/your-authtoken>

</details>

<details>
<summary><b>Java — macOS</b></summary>

```bash
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-java.sh
chmod +x setup-web-eid-java.sh
bash setup-web-eid-java.sh
```

**Eeldused:** ngrok auth token (vt Java — Ubuntu).

</details>

<details>
<summary><b>.NET — Ubuntu (lokaalne, HTTPS localhost:44391)</b></summary>

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet.sh
chmod +x setup-web-eid-dotnet.sh
bash setup-web-eid-dotnet.sh
```

Skript käivitab `dotnet run`-i vaikimisi **`Development`**-režiimis
(ASPNETCORE_ENVIRONMENT default-väärtus). See režiim toetab **test
ID-kaartidega** testimist (`~/.digidocpp/tsl/EE_T.xml` lubab test-CA-d).

Vajadusel küsib skript sudo parooli (`libdigidocpp-csharp` paigaldamiseks).

</details>

<details>
<summary><b>.NET — Ubuntu (remote, ngrok-tunneliga)</b></summary>

Sama .NET näiterakendus, aga avalikult internetist kättesaadav ngrok-iga
— sobib näiteks veebibrauseri-eksperdi remote-testimiseks mobiilseadmest.

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-remote.sh
chmod +x setup-web-eid-dotnet-remote.sh
bash setup-web-eid-dotnet-remote.sh
```

Erinevus lokaalsest skriptist:

- Paigaldab lisaks **ngrok**-i ja küsib auth tokenit
  (<https://dashboard.ngrok.com/get-started/your-authtoken>)
- Rakendus kuulab **HTTP-na** `0.0.0.0:8080` — ngrok teeb HTTPS-i
- `ASPNETCORE_ENVIRONMENT=Production` (kohustuslik, et `UseForwardedHeaders`
  loeks ngrok-i `X-Forwarded-Proto` header-it)
- Test ID-kaardi tugi tuleb kahest patch-ist:
  - `Startup.cs`: `LoadTrustedCaCertificatesFromDisk(true)` — auth jaoks
  - `~/.digidocpp/digidocpp.conf` (test-TSL URL + cert + TSA) — signimise jaoks
- `appsettings.json` `OriginUrl` uuendatakse iga jooksu ajal ngrok URL-iks

</details>

## Harude testimise skriptid

Repo **arendusharust** ehitatud rakendused — kasutatakse PR-ide testimiseks
enne main-i ühendamist. Skript küsib (või võtab argumendiks) haru-nime,
kloonib selle, ehitab WebEid library lokaalseks NuGet-paketiks (versiooniga
`1.2.0-beta1`, et eristuda peamisest 1.2.0-st) ja kasutab seda example-app-i
ehitamiseks.

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-web-eid-dotnet-branch.sh`](setup-web-eid-dotnet-branch.sh) | Web eID .NET näide suvalisest harust (lokaalne) | Ubuntu |
| [`setup-web-eid-dotnet-branch-remote.sh`](setup-web-eid-dotnet-branch-remote.sh) | Web eID .NET näide suvalisest harust + ngrok | Ubuntu |
| [`setup-web-eid-php-branch.sh`](setup-web-eid-php-branch.sh) | Web eID PHP näide suvalisest harust (lokaalne) | Ubuntu |
| [`setup-web-eid-php-branch-remote.sh`](setup-web-eid-php-branch-remote.sh) | Web eID PHP näide suvalisest harust + ngrok | Ubuntu |

<details>
<summary><b>.NET haru-testimine — Ubuntu (lokaalne)</b></summary>

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch.sh
chmod +x setup-web-eid-dotnet-branch.sh

# Interaktiivne: kuvab harude nimekirja ja küsib valikut
bash setup-web-eid-dotnet-branch.sh

# Konkreetne haru nimetus (asenda WE2-123 oma haru-nimega)
bash setup-web-eid-dotnet-branch.sh --branch WE2-123
```

Skript:

1. Tõmbab `web-eid-authtoken-validation-dotnet` repo
2. Laseb valida haru (interaktiivne nimekiri või `--branch` argument)
3. Ehitab `WebEid.Security` projekti **lokaalseks NuGet-paketiks**
   versiooniga **`1.2.0-beta1`** (eristub upstream-i 1.2.0-st)
4. Uuendab example-app-i `.csproj`-i: viite vahetatakse PackageReference
   `WebEid.Security 1.2.0-beta1` peale
5. Ehitab + käivitab example-app-i lokaalselt (`https://localhost:44391`)
6. Pärast valmimist näitab:
   - **DLL sisemine versioon** (`strings WebEid.Security.dll | grep beta`)
     — kinnitab et lokaalne pakett on tegelikult kasutusel
   - **Git haru + commit hash** — auditeeritav

Kasulik, kui pead testima konkreetse arendaja PR-i enne main-i ühendamist.

</details>

<details>
<summary><b>.NET haru-testimine — Ubuntu (remote, ngrok-tunneliga)</b></summary>

Sama haru-testimine, aga ngrok-tunneliga — sobib näiteks PR-i jagamiseks
arendajaga kaugteel või mobiilseadmest testimiseks.

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch-remote.sh
chmod +x setup-web-eid-dotnet-branch-remote.sh

bash setup-web-eid-dotnet-branch-remote.sh
# Konkreetne haru nimetus (asenda WE2-123 oma haru-nimega):
bash setup-web-eid-dotnet-branch-remote.sh --branch WE2-123
```

Erinevus lokaalsest haru-skriptist (sama loogika nagu
`setup-web-eid-dotnet-remote.sh`-s):

- Paigaldab lisaks **ngrok**-i ja küsib auth tokenit
- Rakendus kuulab **HTTP-na** `0.0.0.0:8080` — ngrok teeb HTTPS-i
- `ASPNETCORE_ENVIRONMENT=Production` + `WEBEID_USE_TEST_TSL=true`
- Test ID-kaardi tugi tuleb kahest source-patch-ist:
  - `Startup.cs`: `LoadTrustedCaCertificatesFromDisk(true)` — auth jaoks
  - `DigiDocConfiguration.cs`: laiendab `if`-tingimust `WEBEID_USE_TEST_TSL`
    env-muutujaga — signimise jaoks
- `appsettings.json` `OriginUrl` uuendatakse iga jooksu ajal ngrok URL-iks

</details>

<details>
<summary><b>PHP haru-testimine — Ubuntu (lokaalne)</b></summary>

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-php-branch.sh
chmod +x setup-web-eid-php-branch.sh

# Kuvab harude nimekirja ja küsib valikut
bash setup-web-eid-php-branch.sh

# Konkreetne haru nimetus + teegi ühiktestid (asenda WE2-123 oma haru-nimega)
bash setup-web-eid-php-branch.sh --branch WE2-123 --with-tests
```

Skript:

1. Tõmbab `web-eid-authtoken-validation-php` repo
2. Laseb valida haru (interaktiivne nimekiri või `--branch` argument)
3. Muudab example-rakenduse `composer.json`-i:
   - `"web-eid/web-eid-authtoken-validation-php": "1.3.*"` → `"dev-<HARU>"`
   - Lisab `repositories` bloki `"type": "git"` upstream-i URL-iga
     (NB: mitte `"vcs"` — see kasutaks GitHub API-d ja kukuks autentimisega)
4. Käivitab `composer update` example-kataloogis
5. Seadistab Apache (DocumentRoot → example/public, SSL)
6. Pärast valmimist näitab haru + commit hash-i — auditeeritav
7. **`--with-tests` lipuga:** jooksutab lisaks teegi ühiktestid
   (`composer install` + `composer test` repo juurkataloogis)
   ja näitab kokkuvõtte (Tests/Failures/Time)

**Ühiktestide logi-aken (ainult `--with-tests`-iga):** kui mõni test
**ebaõnnestub**, avab skript automaatselt eraldi terminaliakna
`composer-test.log`-i peal (`less -R` ANSI värvidega). Aknas: `Q` väljub,
`/FAILURES` viib ebaõnnestumiste plokini, `/^[0-9]+) ` leiab ebaõnnestunud
testide loendi, `g`/`G` viib algusesse/lõppu. **Edukal läbimisel uut akent ei
avane** — kui kõik testid läbisid, pole detaili vaja vaadata.

Kasulik, kui pead testima konkreetse arendaja PR-i enne main-i ühendamist.

</details>

<details>
<summary><b>PHP haru-testimine — Ubuntu (remote, ngrok-tunneliga)</b></summary>

Sama haru-testimine, aga ngrok-tunneliga — sobib näiteks PR-i jagamiseks
arendajaga kaugteel või mobiilseadmest testimiseks.

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-php-branch-remote.sh
chmod +x setup-web-eid-php-branch-remote.sh

# Kuvab harude nimekirja ja küsib valikut
bash setup-web-eid-php-branch-remote.sh

# Konkreetne haru nimetus + teegi ühiktestid (asenda WE2-123 oma haru-nimega)
bash setup-web-eid-php-branch-remote.sh --branch WE2-123 --with-tests
```

Erinevus lokaalsest haru-skriptist:

- Paigaldab lisaks **ngrok**-i ja küsib auth tokenit
  (<https://dashboard.ngrok.com/get-started/your-authtoken>)
- ngrok tunneldab Apache HTTPS-i (port 443) avalikku URL-i
- `example/src/app.conf.php` `origin_url` uuendatakse iga jooksu ajal
  ngrok URL-iks (Web eID library nõuab vastavust)
- `--with-tests` lipp töötab sama nagu lokaalses skriptis — sh
  **ebaõnnestumise korral avab automaatselt eraldi terminaliakna** test-logi
  vaatega (`less -R`), edukal läbimisel uut akent ei avane (vt lokaalse
  skripti kirjeldust eespool)

</details>

<details>
<summary><b>Live-logi aken — sulgemine, taas-avamine, peatamine</b></summary>

Kõik `setup-web-eid-*.sh` skriptid (nii main-haru kui harude testimise)
avavad lõpus eraldi terminaliakna live-logiga (`tail -f` rakenduse logi peal).
Käitumine järgib Unix-i tava — **logi-aken on viewer, mitte controller**:
selle sulgemine ei mõjuta rakendust.

| Tegevus | Mis juhtub |
|---|---|
| **Akna X-nupp** | Sulgeb **AINULT logi-akna**. Rakendus (ja ngrok kui see on) jäävad **taustaks** jooksma. |
| **Ctrl+C logi-aknas** | **Ignoreeritakse** — Ctrl+C ei tapa midagi, et saaksid teksti (nt ngrok URL-i) kopeerida. Paljud terminal-id (Windows Terminal, VS Code, GNOME Terminal valitud teksti puhul) mappivad Ctrl+C kopeerimiseks. |

Skripti **lõpu-banneril** ja **logi-akna sees** on selgelt välja kirjutatud:

1. **Logi uuesti avada** (kui sulgesid akna):
   ```bash
   bash ~/tools/log-tail-helper.sh
   ```
   Helper-skript jääb kõvakettale, saad iga kord taasavada — kasutab sama
   logi-faili samade filtritega (TSL-spam .NET-i puhul välja).

2. **Rakenduse + ngrok-i peatamine** — täpsed kill-käsud iga skripti
   lõpu-banneril näha. Näiteks .NET-remote-il:
   ```bash
   kill $(cat ~/tools/dotnet-app.pid)
   kill $(cat ~/tools/ngrok.pid)
   ```

PHP-skripti puhul on Apache **system-teenus** (mitte foreground-protsess) —
seda peatatakse: `sudo systemctl stop apache2`.

</details>

<details>
<summary><b>⚠️ VMware Ubuntu VM-il PHP + Java koos (teadaolev konflikt)</b></summary>

Kui paigaldad mõlemad näited samasse Ubuntu VM-i, kukub Java
Maven-ehitus samm 5/7-s OCSP unit-testi peal (VMware NAT-i DNS-hijack
+ kõrval töötav Apache). Enne Java skripti käivitamist:

```bash
sudo systemctl stop apache2
echo "127.0.0.2  invalid.invalid" | sudo tee -a /etc/hosts
```

Pärast Java näite valmis saamist saad Apache tagasi käima panna:
`sudo systemctl start apache2`.

</details>

---

# Muud testimisskriptid

Üldised Linux VM seadistus-skriptid (ei ole Web eID-spetsiifilised).

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-vmware-shared-folder.sh`](setup-vmware-shared-folder.sh) | VMware Shared Folder Ubuntu pool | Ubuntu (VMware VM) |
| [`disable-screensaver.sh`](disable-screensaver.sh) | Keelab GNOME ekraanisäästja + idle-suspend | Ubuntu/GNOME |

<details>
<summary><b>VMware Shared Folder</b></summary>

Paigaldab open-vm-tools'i, seadistab `/etc/fstab` rea, monteerib
jagatud kausta ja loob sümbollingi kodukausta.

**1. Hosti pool** (Windows, käsitsi VMware UI-s) — VM peab olema
**välja lülitatud** (mitte suspendis):

1. VMware Workstation → vali VM → **VM → Settings** (Ctrl+D)
2. Vahekaart **Options** → vasakult **Shared Folders**
3. Parem paneel: **Always enabled**
4. **Add...** → Next → **Browse** Windowsi kaustale → **Name** anna
   ingliskeelne nimi (nt `shared` või `SharedVM`, ilma tühikute ja
   täpitähtedeta) → märgi **Enable this share** → **Finish**
5. **OK** Settings akna sulgemiseks
6. Power On VM

**2. VM-i pool** (Ubuntu, skriptiga):

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-vmware-shared-folder.sh
chmod +x setup-vmware-shared-folder.sh
bash setup-vmware-shared-folder.sh                 # tuvastab nime automaatselt
# või:
bash setup-vmware-shared-folder.sh SharedVM        # määra nimi käsitsi
```

</details>

<details>
<summary><b>Ekraanisäästja keelamine — Ubuntu/GNOME</b></summary>

Linux VM-id (eriti VMware-s) kipuvad ekraanisäästja tõttu hanguma.
Skript keelab kõik seotud GNOME seaded korraga ja kontrollib tulemused.

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/disable-screensaver.sh
chmod +x disable-screensaver.sh
bash disable-screensaver.sh
```

Seadistab:
- `org.gnome.desktop.screensaver lock-enabled` → false
- `org.gnome.desktop.screensaver idle-activation-enabled` → false
- `org.gnome.desktop.session idle-delay` → 0
- `org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type` → nothing
- `org.gnome.settings-daemon.plugins.power idle-dim` → false
- `org.gnome.desktop.screensaver ubuntu-lock-on-suspend` → false (Ubuntu-spetsiifiline)

Skript ei vaja sudo-d — seadistab ainult kasutaja dconf-i.

</details>
