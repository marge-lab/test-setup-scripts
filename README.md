## test-setup-scripts

Paigaldus- ja seadistus-skriptid testimismasina (Linux / macOS / Windows)
kiireks ülesseadmiseks testimistöö jaoks.

Skriptid jagunevad kahte rühma:

1. **Web eID näidisrakendused** — PHP, Java, .NET (main-haru ja harude testimine)
2. **Muud testimisskriptid** — VMware shared folder, masina ärkvel hoidmine (keep-awake)

---

## Web eID näidisrakendused

Skriptid kloonivad [web-eid](https://github.com/web-eid)
GitHub-projektist vastava `web-eid-authtoken-validation-*` repo,
ehitavad näiterakenduse ja käivitavad. Kõik avavad lõpus eraldi
terminaliakna **live-logiga** (rakenduse päringud, sertide laadimine,
OCSP/TSA tegevused reaalajas).

### Main-haru skriptid

Repo `main`-harust ehitatud rakendused — sobivad reliisi-testimiseks.

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-web-eid-php.sh`](setup-web-eid-php.sh) | Web eID PHP näiterakendus (lokaalne) | Ubuntu |
| [`setup-web-eid-php-remote.sh`](setup-web-eid-php-remote.sh) | Web eID PHP näiterakendus + ngrok (avalik HTTPS) | Ubuntu |
| [`setup-web-eid-java.sh`](setup-web-eid-java.sh) | Web eID Java näiterakendus (ngrok-iga) | Ubuntu, macOS |
| [`setup-web-eid-dotnet.sh`](setup-web-eid-dotnet.sh) | Web eID .NET näiterakendus (lokaalne) | Ubuntu |
| [`setup-web-eid-dotnet-remote.sh`](setup-web-eid-dotnet-remote.sh) | Web eID .NET näiterakendus + ngrok (avalik HTTPS) | Ubuntu |
| [`setup-web-eid-dotnet.py`](setup-web-eid-dotnet.py) (+ [`.cmd`](setup-web-eid-dotnet.cmd)) | Web eID .NET näiterakendus (Python-skript; lokaalne) | Windows, macOS |
| [`setup-web-eid-dotnet-remote.py`](setup-web-eid-dotnet-remote.py) (+ [`.cmd`](setup-web-eid-dotnet-remote.cmd)) | Web eID .NET näiterakendus + ngrok (Python; avalik HTTPS) | Windows, macOS |

<details>
<summary><b>PHP — Ubuntu (lokaalne, HTTPS localhost)</b></summary>

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-php.sh
chmod +x setup-web-eid-php.sh
bash setup-web-eid-php.sh
```

</details>

<details>
<summary><b>PHP — Ubuntu (remote, ngrok-tunneliga)</b></summary>

Sama PHP näiterakendus, aga avalikult internetist kättesaadav ngrok-iga
— sobib näiteks PR-i jagamiseks arendajaga kaugteel või mobiilseadmest
testimiseks.

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-php-remote.sh
chmod +x setup-web-eid-php-remote.sh
bash setup-web-eid-php-remote.sh
```

Erinevus lokaalsest skriptist:

- Paigaldab lisaks **ngrok**-i ja küsib auth tokenit
  (<https://dashboard.ngrok.com/get-started/your-authtoken>)
- ngrok tunneldab Apache HTTPS-i (port 443) avalikku URL-i
- `example/src/app.conf.php` `origin_url` uuendatakse iga jooksu ajal
  ngrok URL-iks (Web eID library nõuab vastavust)

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
<summary><b>Java — repo struktuur ja ehituse väljund</b></summary>

Skript kloonib repo `~/projects/web-eid/` alla ja teeb selle sees kaks
eraldi ehitust (sammud 5/7 ja 6/7):

```
web-eid/                              ← repo juur
├── pom.xml                ┐
├── src/                   │  TEEK (eu.webeid.security:authtoken-validation)
│   ├── main/java/         │
│   └── test/java/         ┘
├── target/                              ← teegi build-väljund (mvn install paneb siia .jar-id)
│   └── authtoken-validation-1.2.3.jar
├── example/                             ← NÄIDISRAKENDUS
│   ├── pom.xml            ┐
│   ├── src/               │  eu.webeid.example:web-eid-springboot-example
│   └── target/            ┘
│       └── web-eid-springboot-example-1.2.3.jar
├── LICENSE
└── README.md
```

> **NB!** Versioon `1.2.3` näites on **näitlik** — sinu repo tegelikus
> väljundis on praeguse haru versioon (vaata `pom.xml` `<version>` välja
> või `target/` kausta failide nime).

**Kuidas seda kontrollida:**

```bash
# Mis on teegi target-i sees?
ls ~/projects/web-eid/target/
# Peaks olema: authtoken-validation-X.Y.Z.jar (+ sources, javadoc, classes/, test-classes/, surefire-reports/...)

# Mis on näidisrakenduse target-i sees?
ls ~/projects/web-eid/example/target/
# Peaks olema: web-eid-springboot-example-X.Y.Z.jar (Spring Boot fat JAR)
```

Ehituse logi (live-vaade eraldi terminaliaknas kuvatakse ehituse ajal
automaatselt) on samuti vaadeldav käsitsi:
```bash
less -R ~/tools/build.log
```

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
<summary><b>.NET — Windows / macOS (Python-skriptiga, lokaalne)</b></summary>

Cross-platform Python-skript, mis paigaldab .NET 8 SDK, Git-i ja
DigiDoc4 Client-i (kui pole), kloonib repo, patchib `.csproj`-i ja
käivitab näiterakenduse `https://localhost:44391`. Sõltuvused: ainult
Python 3.8+ standard-teek (EI vaja `pip install`-i).

**Töövoog:**

```
Windows-i kasutaja:  topeltklikk setup-web-eid-dotnet.cmd
                     → kontrollib Python (paigaldab winget-iga kui pole)
                     → käivitab setup-web-eid-dotnet.py
macOS-i kasutaja:    python3 setup-web-eid-dotnet.py    (otse terminalis)
```

**Windows:**

```cmd
:: Lae alla mõlemad failid (curl töötab nii cmd-aknas kui PowerShell-is,
:: Windows 10/11-l on curl.exe sisseehitatud)
curl -o setup-web-eid-dotnet.cmd https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet.cmd
curl -o setup-web-eid-dotnet.py https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet.py

:: Vaikimisi: dev-profile (test ID-kaardid, ASPNETCORE_ENVIRONMENT=Development)
.\setup-web-eid-dotnet.cmd

:: VOI: prod-profile (live ID-kaardid, ASPNETCORE_ENVIRONMENT=Production)
.\setup-web-eid-dotnet.cmd --profile prod
```

Kui Python pole paigaldatud, `.cmd` küsib `Paigaldada Python nuud [Y/N]` ja
paigaldab automaatselt winget-iga. Pärast Pythoni installi kuvab
"sulge see aken, ava uus" sõnumi (PATH-i värskendus). Topeltkliki .cmd-l
uuesti.

**macOS:**

```bash
# Lae alla ainult .py (cmd pole vaja)
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet.py

# Vaikimisi: dev-profile (test ID-kaardid)
python3 setup-web-eid-dotnet.py

# VOI: prod-profile (live ID-kaardid)
python3 setup-web-eid-dotnet.py --profile prod
```

**Skript:**

1. Kontrollib + paigaldab .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8` Windowsil, `brew install --cask dotnet-sdk` Mac-il)
2. Kontrollib + paigaldab Git
3. Kontrollib **libdigidocpp** dev-teeki ja paigaldab uusima `libdigidocpp*x64.msi` GitHub releases-ist (<https://github.com/open-eid/libdigidocpp/releases>). **NB!** See EI OLE sama mis DigiDoc4 Client (kasutaja-tarkvara) — `libdigidocpp` on developer-teek, mida vajab .NET näiterakendus
4. Kloonib `web-eid-authtoken-validation-dotnet` main-haru
5. Patchib `.csproj`: `PackageReference WebEid.Security` → `ProjectReference` (lokaalne lähtekood)
6. Kopeerib `C:\Program Files\libdigidocpp\include\digidocpp_csharp\*.cs` → projekti `DigiDoc/` (enne build-i, kuna .cs failid kompileeritakse projekti)
7. Seadistab HTTPS dev-sertifikaadi (`dotnet dev-certs https --trust`).
   **⚠️ Windowsil avaneb turvadialoog "Security Warning — Install certificate?":**
   - **Vajuta "Yes"** — sertifikaat lisatakse Windows-i Trusted Root-i,
     `https://localhost:44391` töötab ilma brauseri-hoiatusteta, Web eID
     extension saab korrektselt töötada.
   - **Kui klõpsad "No"** — paigaldus on **katki**: brauser näitab
     "Your connection is not private" hoiatust ja Web eID extension võib
     keelduda HTTPS-päringust. Sertifikaat on self-signed AINULT `localhost`-i
     jaoks (sinu enda masin), pole turvaohtu — vajuta julgelt **Yes**.
8. **Dev-profile:** loob test-TSL flag-faili (`%APPDATA%\digidocpp\tsl\EE_T.xml` Windowsil, `~/.digidocpp/tsl/EE_T.xml` macOS-il). **Prod-profile:** EE_T.xml-i ei loo (live-kaardid kasutavad live TSL-i).
9. Ehitab — `dotnet restore` + `dotnet build`
10. Kopeerib **pärast build-i** ülejäänud libdigidocpp failid (DLL-id + `schema/` kaust) → `bin\Debug\net8.0\` (vastab ametliku juhendi sammule `xcopy /s` ja "Also copy folder schema"). **Prod-profile:** lisaks loob `bin\Debug\net8.0\digidocpp.conf` `ts.url`-iga (Variant 2 ametlikust juhendist — Eesti eID test-TSA URL, mis ei vaja SK-tasulist kontot). Käivitab `dotnet run --no-build` koos `ASPNETCORE_ENVIRONMENT=Development` (dev) või `Production` (prod) ja avab brauseri.

**Profiilide erinevus:**

| Aspekt | `--profile dev` (vaikimisi) | `--profile prod` |
|---|---|---|
| ASP.NET keskkond | `Development` | `Production` |
| ID-kaardid | Test-kaardid (JÕEORG jms) | Live-kaardid |
| Trusted CA-d | `Certificates/Dev/*.cer` (test) | `Certificates/Prod/*.cer` (live) |
| TSL | Test-TSL (`EE_T.xml` flag) | Live-TSL |
| TSA URL | `http://demo.sk.ee/tsa` (test) | Eesti eID test-TSA URL (tasuta, ilma SK-lepinguta) |
| Source-patch DigiDocConfiguration.cs | ei | ei (kasutab Variant 2 — `digidocpp.conf`) |

**Hoiatus prod-profile-i kohta:** vaikimisi kasutatav TSA URL on **test-TSA** — sobib testimiseks, aga päris-produktsiooni jaoks vaja SK-tasulist TSA-kontot ja URL tuleb vahetada lepingu-kohasele (nt `https://eid.sk.ee/tsa`). Konkreetne URL ja seadistus on dokumenteeritud [libdigidocpp wiki-s](https://github.com/open-eid/libdigidocpp/wiki).

</details>

<details>
<summary><b>.NET — Windows / macOS (Python-skriptiga + ngrok, remote)</b></summary>

Sarnaselt lokaalsele Python-skriptile, aga ngrok-tunneliga — sobib näiteks
testimiseks teisest masinast, mobiilseadmest või PR-i jagamiseks arendajaga
kaugteel.

> **⚠️ TÄHELEPANU TEST-KAARDI KASUTAJALE:**
>
> Remote-skripti logist näed alati `Hosting environment: Production` — **see on õige**, mitte bug. **ÄRA võta selle pärast live-kaarti, kui sul on test-kaart.**
>
> Remote-skriptis `--profile` tähendab **KAARDITÜÜPI**, mitte ASP.NET-i environment-it:
> - **`--profile dev`** = **test-kaart** (JÕEORG jms) — VAIKIMISI
> - **`--profile prod`** = **live-kaart** (päris isiklik ID)
>
> ASP.NET Hosting environment on remote-modes **alati Production** — ngrok-i `UseForwardedHeaders()` middleware vajab seda. Skript teeb source-patchid, mis sunnivad test-CA-d ja test-TSL-i tööle Production-mode-s.
>
> Niisiis: **test-kaart → `--profile dev`** (vaikimisi). Logist näed Production, aga autentimine töötab test-kaardiga.

**Windows:**

```cmd
:: Lae alla mõlemad failid
curl -o setup-web-eid-dotnet-remote.cmd https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-remote.cmd
curl -o setup-web-eid-dotnet-remote.py https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-remote.py

:: Vaikimisi: dev-profile (test-kaardid + source-patchid)
.\setup-web-eid-dotnet-remote.cmd

:: VOI: prod-profile (live-kaardid + digidocpp.conf ts.url-iga)
.\setup-web-eid-dotnet-remote.cmd --profile prod
```

**macOS:**

```bash
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-remote.py
python3 setup-web-eid-dotnet-remote.py            # dev
python3 setup-web-eid-dotnet-remote.py --profile prod   # prod
```

**Eeldused:** ngrok auth token (tasuta konto): <https://dashboard.ngrok.com/get-started/your-authtoken>. Skript pakub **kolme viisi tokeni sisestamiseks** (skript proovib järjekorras):

1. **`NGROK_AUTH_TOKEN` env-muutuja:**
   ```cmd
   :: cmd
   set NGROK_AUTH_TOKEN=2xxxxxxxxxxxxxxxxxxxx
   .\setup-web-eid-dotnet-remote.cmd
   ```
   ```powershell
   # PowerShell
   $env:NGROK_AUTH_TOKEN='2xxxxxxxxxxxxxxxxxxxx'
   .\setup-web-eid-dotnet-remote.cmd
   ```
   Token nähtav cmd-seansis, aga ei salvestu scrollback-i.

2. **Tokeni-fail** (ohutuim, paste-i probleeme pole):
   - Salvesta token (ainult token, mitte tervet `ngrok config add-authtoken ...` käsku) faili:
     `C:\Users\<sina>\ngrok-auth-token.txt`
   - Skript loeb selle automaatselt
   - **Pärast esimest jooksu kustuta fail käsitsi** (token elab edaspidi ngrok.yml-is)

3. **Käsitsi siia konsooli** (lihtsaim, kuid token jääb scrollback-i):
   - Skript küsib `input()`-iga
   - Paremklikk paste cmd-aknas, Ctrl+V Windows Terminal-is

**Kus token tegelikult salvestub:** `C:\Users\<sina>\AppData\Local\ngrok\ngrok.yml`. Skript ise tokenit kuhugi mujale ei salvesta. Eemaldamiseks: kustuta see fail.

**Erinevus lokaalsest Python-skriptist:**

- Paigaldab lisaks **ngrok**-i (otse-download GitHub-i releases-ist, mitte winget)
- Küsib ngrok auth-tokenit (skripti sees, mitte eraldi aknas)
- Rakendus kuulab **HTTP-na** `0.0.0.0:8080` — ngrok teeb HTTPS-i
- `ASPNETCORE_ENVIRONMENT=Production` **alati** (ngrok-i `UseForwardedHeaders()` jaoks)
- `appsettings.json` `OriginUrl` uuendatakse iga jooksu ajal ngrok URL-iks
- **`--profile dev`** korral kaks source-patchi (vajalik, kuna Production-mode pole loomulik test-kaartide jaoks):
  - `Startup.cs`: `LoadTrustedCaCertificatesFromDisk(true)` — sunnib test-CA-d ka Production-modes
  - `DigiDocConfiguration.cs`: laiendab `if`-tingimust `WEBEID_USE_TEST_TSL` env-muutujaga — sunnib test-TSL-i
- **`--profile prod`** korral source-patche EI tehta + `bin\Debug\net8.0\digidocpp.conf` `ts.url`-iga (Variant 2)

**⚠️ Profile vs ASP.NET environment — oluline arusaam:**

Remote-skriptis `--profile` tähendab **kaarditüüpi**, mitte ASP.NET-i `Hosting environment`-it. ASP.NET-i `Hosting environment` on remote-modes **ALATI `Production`** (ngrok-i `UseForwardedHeaders()` middleware vajab seda — Dev-modes oleks `UseHttpsRedirection()` aktiivne ja lõhuks ngrok-tunneli HTTP→HTTPS redirect-loop-iga).

| `--profile` | Kaardid | ASP.NET Hosting env | Kuidas test-kaardid prod-modes tööle saavad |
|---|---|---|---|
| `dev` | **Test**-kaardid (JÕEORG jms) | Production (alati remote-modes) | Source-patchid `Startup.cs` (`LoadTrustedCaCertificatesFromDisk(true)`) + `DigiDocConfiguration.cs` env-flag `WEBEID_USE_TEST_TSL=true` |
| `prod` | **Live**-kaardid (päris ID) | Production (alati remote-modes) | Loomulik (Cert/Prod/*.cer + live TSL); `digidocpp.conf` `ts.url`-iga |

Niisiis: kui logist näed `Hosting environment: Production` ka `--profile dev`-iga — see on **õige käitumine**, mitte bug.

**Akna käitumine:**
- Sama cmd-aken hoiab nii `dotnet run`-i kui ngrok-tunneli (PID Python-protsessis salvestatud)
- **Ctrl+C** peatab MÕLEMAD (app + ngrok) — puhas väljumine
- Brauser avaneb 8 sek pärast app-i käivitust ngrok URL-ile

</details>

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

### Harude testimise skriptid

Repo **arendusharust** ehitatud rakendused — kasutatakse PR-ide testimiseks
enne main-i ühendamist. Skript küsib (või võtab argumendiks) haru-nime,
kloonib selle, ehitab valitud haru WebEid library lokaalselt ja kasutab
seda example-app-i ehitamiseks. Iga keele jaoks veidi erinev pakkimine:

- **.NET:** ehitatakse lokaalseks NuGet-paketiks versiooniga `1.2.0-beta1`
  (eristub upstream-i 1.2.0-st)
- **Java:** installitakse lokaalsesse Maven cache'i, example-app kasutab
  automaatselt installitud versiooni
- **PHP:** `composer.json` `repositories` blokis lisatakse git tüüpi
  upstream-link, version constraint muudetakse `dev-<HARU>`-ks

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-web-eid-java-branch.sh`](setup-web-eid-java-branch.sh) | Web eID Java näide suvalisest harust + ngrok | Ubuntu, macOS |
| [`setup-web-eid-dotnet-branch.sh`](setup-web-eid-dotnet-branch.sh) | Web eID .NET näide suvalisest harust (lokaalne) | Ubuntu |
| [`setup-web-eid-dotnet-branch-remote.sh`](setup-web-eid-dotnet-branch-remote.sh) | Web eID .NET näide suvalisest harust + ngrok | Ubuntu |
| [`setup-web-eid-dotnet-branch.py`](setup-web-eid-dotnet-branch.py) (+ [`.cmd`](setup-web-eid-dotnet-branch.cmd)) | Web eID .NET näide suvalisest harust (Python-skript; lokaalne) | Windows, macOS |
| [`setup-web-eid-dotnet-branch-remote.py`](setup-web-eid-dotnet-branch-remote.py) (+ [`.cmd`](setup-web-eid-dotnet-branch-remote.cmd)) | Web eID .NET näide suvalisest harust (Python-skript; + ngrok) | Windows, macOS |
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
<summary><b>.NET haru-testimine — Windows / macOS (Python-skript, lokaalne)</b></summary>

Sama loogika mis Ubuntu-versioonis, aga Pythonis. Toetab `--branch` argumenti
JA interaktiivset menüüd, `--profile {dev,prod}`.

**Windows (cmd-aknas):**

```cmd
curl -o setup-web-eid-dotnet-branch.cmd https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch.cmd
curl -o setup-web-eid-dotnet-branch.py  https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch.py

:: Interaktiivne: kuvab harude nimekirja
.\setup-web-eid-dotnet-branch.cmd

:: Konkreetne haru, test-kaartidega (vaikimisi)
.\setup-web-eid-dotnet-branch.cmd --branch WE2-123

:: Live-kaardiga (digidocpp.conf ts.url-iga)
.\setup-web-eid-dotnet-branch.cmd --branch WE2-123 --profile prod
```

**macOS (terminalis):**

```bash
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch.py
python3 setup-web-eid-dotnet-branch.py --branch WE2-123
```

`.cmd` kontrollib alguses, et Python on paigaldatud ja kui pole, pakub
`winget install Python.Python.3.12`-i.

</details>

<details>
<summary><b>.NET haru-testimine — Windows / macOS (Python-skript, remote ngrok)</b></summary>

Sama loogika mis Ubuntu remote-versioonis (ngrok-tunnel + auth-token),
aga Pythonis.

**Windows:**

```cmd
curl -o setup-web-eid-dotnet-branch-remote.cmd https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch-remote.cmd
curl -o setup-web-eid-dotnet-branch-remote.py  https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch-remote.py

:: Interaktiivne haru-valik + test-kaardid
.\setup-web-eid-dotnet-branch-remote.cmd

:: Konkreetne haru, live-kaardiga
.\setup-web-eid-dotnet-branch-remote.cmd --branch WE2-123 --profile prod
```

**macOS:**

```bash
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet-branch-remote.py
python3 setup-web-eid-dotnet-branch-remote.py --branch WE2-123
```

Profile-i vahetus (`dev` ↔ `prod`) on ohutu — skript taastab `Startup.cs` ja
`DigiDocConfiguration.cs` igal käivitusel `git HEAD`-ist ja siis rakendab
ainult valitud profile-i patche.

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

**Ühiktestide logi-aken (ainult `--with-tests`-iga):**

- Iga skripti-jooks salvestab logi **timestamp-iga failinime alla**, näiteks
  `~/composer-test-WE2-123-20260522-143015.log` — vanad logid ei kao kui
  jooksutad uuesti.
- **Ebaõnnestumise korral** avab skript automaatselt eraldi terminaliakna
  logi-vaatega (`less -R` ANSI värvidega). Aknas: `Q` väljub, `/FAILURES`
  viib ebaõnnestumiste plokini, `/^[0-9]+) ` leiab ebaõnnestunud testide
  loendi, `g`/`G` viib algusesse/lõppu.
- **Edukal läbimisel** küsib skript: `Avada test-logi eraldi terminaliaknas? [y/N]`
  — vajuta `y` + Enter kui tahad logi näha (nt tõestuseks kontrollida), muidu
  lihtsalt Enter ja minnakse edasi.
- **Taasavamiseks hiljem** (mis tahes hetkel pärast skripti lõppu):
  ```bash
  bash ~/.web-eid-php-test-viewer.sh    # avaneb viimase jooksu logi
  # või otse konkreetse logi-fail:
  less -R ~/composer-test-WE2-123-20260522-143015.log
  ```
- **Tõestuseks salvestamine** (puhas tekst ilma ANSI värvi-koodideta):
  ```bash
  sed -r 's/\x1b\[[0-9;]*[mGKH]//g' \
    ~/composer-test-WE2-123-20260522-143015.log \
    > ~/php-tests-WE2-123-passed.txt
  ```

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
<summary><b>Java haru-testimine — Ubuntu/macOS (ngrok-tunneliga)</b></summary>

Sarnaselt .NET- ja PHP-harude testimisele, aga Java/Maven-i jaoks. Toetab
nii Linuxit (Ubuntu) kui macOS-i (x86_64 + arm64). Sudo ei ole vajalik —
JDK ja ngrok paigaldatakse `~/tools/` alla.

```bash
# Ubuntu
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-java-branch.sh
chmod +x setup-web-eid-java-branch.sh

# macOS
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-java-branch.sh
chmod +x setup-web-eid-java-branch.sh

# Kuvab harude nimekirja ja küsib valikut
bash setup-web-eid-java-branch.sh

# Konkreetne haru nimetus (asenda release-1.2.3 oma haru-nimega)
bash setup-web-eid-java-branch.sh --branch release-1.2.3
```

Skript:

1. Paigaldab portatiivse JDK 17 (Adoptium GA) ja ngrok-i `~/tools/` alla
2. Küsib ngrok auth tokenit (eraldi terminaliaknas — vt
   <https://dashboard.ngrok.com/get-started/your-authtoken>)
3. Tõmbab `web-eid-authtoken-validation-java` repo
4. Laseb valida haru (interaktiivne nimekiri või `--branch` argument)
5. **Verifitseerib haru ja commit-i:** soovitud vs aktiivne haru kontroll,
   kohalik vs `origin/<HARU>` commit-võrdlus, pealkiri + kuupäev — auditeeritav
6. Ehitab root library `mvn install`-iga lokaalsesse Maven cache'i
   (`mvn install` jooksutab automaatselt ka **ühiktestid** enne installimist)
7. Ehitab example-app-i Spring Boot fat JAR-iks (`mvn package`)
8. Käivitab ngrok-tunneli + Spring Boot rakenduse, uuendab
   `application-dev.yaml` `local-origin`-i ngrok URL-iks
9. Avab live-logi eraldi terminaliaknas (rakenduse päringud reaalajas)

**Eraldi terminaliaknad mis avanevad:**

- Sammus 2 — ngrok auth tokeni dialoog
- Sammus 5/6 vahel — ehituse live-logi (Maven väljund reaalajas; sulged X-iga
  kui valmis)
- Pärast sammu 8 — rakenduse live-logi (Spring Boot päringud, OCSP/TSA tegevus)

**Versiooni-detektsioon:** skript nopib build-logist installitud library
versiooni (`authtoken-validation-X.Y.Z.jar`) ja kuvab selle kokkuvõttes —
nii saad kinnitada, et lokaalsesse Maven cache'i installiti just see versioon
mida haru `pom.xml`-is on. Kui logist ei õnnestu, fallback loeb otse
`pom.xml`-i `<version>` välja.

Kasulik release-haru või konkreetse PR-i testimiseks enne main-i ühendamist.

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

## Muud testimisskriptid

Üldised Linux VM seadistus-skriptid (ei ole Web eID-spetsiifilised).

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-vmware-shared-folder.sh`](setup-vmware-shared-folder.sh) | VMware Shared Folder Ubuntu pool | Ubuntu (VMware VM) |
| [`keep-awake.sh`](keep-awake.sh) | Keelab GNOME ekraanisäästja + idle-suspend | Ubuntu/GNOME |
| [`keep-awake.cmd`](keep-awake.cmd) | Keelab Windowsi ekraanisäästja + sleep + ketta spin-down | Windows 10/11 |

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
<summary><b>Keep awake — Ubuntu/GNOME (ekraanisäästja + idle-suspend välja)</b></summary>

Linux VM-id (eriti VMware-s) kipuvad ekraanisäästja tõttu hanguma.
Skript keelab kõik seotud GNOME seaded korraga ja kontrollib tulemused.

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/keep-awake.sh
chmod +x keep-awake.sh
bash keep-awake.sh
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

<details>
<summary><b>Keep awake — Windows 10/11 (ekraan + sleep + ketta spin-down välja)</b></summary>

Windowsi test-masinad/VM-id, mis peavad olema pikka aega aktiivsed
ilma kasutaja sekkumiseta. Skript sätib `powercfg`-iga **0 = mitte kunagi**
nii ekraanile, süsteemile, kettale kui auto-hibernate'ile.

```cmd
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/keep-awake.cmd
.\keep-awake.cmd
```

Topeltkliki .cmd-l võib otse — pärast jooksmist kuvatakse kontroll-tabel
ja `pause` ootab Enter-it.

Seadistab (`powercfg /change`):
- `monitor-timeout-ac` / `-dc` → 0 (ekraan ei lülitu välja)
- `standby-timeout-ac` / `-dc` → 0 (süsteem ei lähe sleep-i)
- `disk-timeout-ac` / `-dc` → 0 (ketas ei lähe spin-down-i)
- `hibernate-timeout-ac` / `-dc` → 0 (auto-hibernate ei aktiveeru)

JA registry (HKCU, ei vaja admin-õigusi):
- `Control Panel\Desktop\ScreenSaveActive` → 0
- `Control Panel\Desktop\ScreenSaverIsSecure` → 0
- `Control Panel\Desktop\ScreenSaveTimeOut` → 0

**Märkused:**
- Hiberneerimise **täielikuks** välja-lülitamiseks (kustutab `hiberfil.sys`,
  vabastab ketast) ava `cmd "Run as administrator"` ja käivita käsitsi:
  `powercfg /hibernate off`
- Vaikeseadete taastamiseks: `Settings → System → Power & battery → Screen and sleep`

</details>
