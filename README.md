# test-setup-scripts

Paigaldus- ja seadistus-skriptid Linux VM-i kiireks ülesseadmiseks
testimistöö jaoks.

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-web-eid-php.sh`](setup-web-eid-php.sh) | Web eID PHP näiterakendus | Ubuntu |
| [`setup-web-eid-java.sh`](setup-web-eid-java.sh) | Web eID Java näiterakendus (ngrok-iga) | Ubuntu, macOS |
| [`setup-web-eid-dotnet.sh`](setup-web-eid-dotnet.sh) | Web eID .NET näiterakendus (lokaalne) | Ubuntu |
| [`setup-web-eid-dotnet-remote.sh`](setup-web-eid-dotnet-remote.sh) | Web eID .NET näiterakendus + ngrok-tunnel (avalik HTTPS) | Ubuntu |
| [`setup-vmware-shared-folder.sh`](setup-vmware-shared-folder.sh) | VMware Shared Folder Ubuntu pool | Ubuntu (VMware VM) |
| [`disable-screensaver.sh`](disable-screensaver.sh) | Keelab GNOME ekraanisäästja + idle-suspend | Ubuntu/GNOME |

---

## PHP — Ubuntu

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-php.sh
chmod +x setup-web-eid-php.sh
bash setup-web-eid-php.sh
```

## Java — Ubuntu

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-java.sh
chmod +x setup-web-eid-java.sh
bash setup-web-eid-java.sh
```

## Java — macOS

```bash
curl -O https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-java.sh
chmod +x setup-web-eid-java.sh
bash setup-web-eid-java.sh
```

### Eeldused (Java)

Java-skript vajab ngrok auth tokenit (küsitakse sammus 3/7). Tee
endale tasuta konto ja kopeeri token:
<https://dashboard.ngrok.com/get-started/your-authtoken>

## .NET — Ubuntu (lokaalne, HTTPS localhost:44391)

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-web-eid-dotnet.sh
chmod +x setup-web-eid-dotnet.sh
bash setup-web-eid-dotnet.sh
```

Skript käivitab `dotnet run`-i vaikimisi **`Development`**-režiimis
(ASPNETCORE_ENVIRONMENT default-väärtus). See režiim toetab **test
ID-kaartidega** testimist (`~/.digidocpp/tsl/EE_T.xml` lubab test-CA-d).

Vajadusel küsib skript sudo parooli (`libdigidocpp-csharp` paigaldamiseks).

## .NET — Ubuntu (remote, ngrok-tunneliga)

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

## Live-logi aken — sulgemine ja kopeerimine

Kõik `setup-web-eid-*.sh` skriptid avavad lõpus eraldi terminaliakna live-logiga
(`tail -f` rakenduse logi peal). Käitumine sellele:

| Tegevus | Mis juhtub |
|---|---|
| **Akna X-nupp** (üks klikk) | Sulgeb logi-akna **JA** tapab rakenduse + ngrok-tunneli ühe klikiga. Java, .NET-lokaalne ja .NET-remote skriptidel. PHP erand: Apache jääb jooksma (system-teenus). |
| **Ctrl+C logi-aknas** | **Ignoreeritakse** — Ctrl+C ei tapa midagi, et saaksid teksti (nt ngrok URL-i) kopeerida. Paljud terminal-id (Windows Terminal, VS Code, GNOME Terminal valitud teksti puhul) mappivad Ctrl+C kopeerimiseks. |

PHP-skripti juures sulgeb X-nupp ainult tail-i. Apache peatamiseks eraldi:

```bash
sudo systemctl stop apache2
```

Kui sulgesid logi-akna vananenud skripti versiooniga (kus X-nupp tapab ainult
tail-i) ja taustal on rakendus + ngrok endiselt jooksmas, saad need ühe
käsuga puhtaks teha (PID-i pole vaja teada):

```bash
pkill -f "dotnet run"; pkill -f ngrok    # .NET-rakendus + ngrok
pkill -f "spring-boot:run"; pkill -f ngrok    # Java-rakendus + ngrok
```

## VMware Ubuntu VM-il PHP + Java koos

Kui paigaldad mõlemad näited samasse Ubuntu VM-i, kukub Java
Maven-ehitus samm 5/7-s OCSP unit-testi peal (VMware NAT-i DNS-hijack
+ kõrval töötav Apache). Enne Java skripti käivitamist:

```bash
sudo systemctl stop apache2
echo "127.0.0.2  invalid.invalid" | sudo tee -a /etc/hosts
```

Pärast Java näite valmis saamist saad Apache tagasi käima panna:
`sudo systemctl start apache2`.

---

## VMware Shared Folder

Paigaldab open-vm-tools'i, seadistab `/etc/fstab` rea, monteerib
jagatud kausta ja loob sümbollingi kodukausta.

### 1. Hosti pool (Windows, käsitsi VMware UI-s)

VM peab olema **välja lülitatud** (mitte suspendis):

1. VMware Workstation → vali VM → **VM → Settings** (Ctrl+D)
2. Vahekaart **Options** → vasakult **Shared Folders**
3. Parem paneel: **Always enabled**
4. **Add...** → Next → **Browse** Windowsi kaustale → **Name** anna
   ingliskeelne nimi (nt `shared` või `SharedVM`, ilma tühikute ja
   täpitähtedeta) → märgi **Enable this share** → **Finish**
5. **OK** Settings akna sulgemiseks
6. Power On VM

### 2. VM-i pool (Ubuntu, skriptiga)

```bash
wget https://raw.githubusercontent.com/marge-lab/test-setup-scripts/main/setup-vmware-shared-folder.sh
chmod +x setup-vmware-shared-folder.sh
bash setup-vmware-shared-folder.sh                 # tuvastab nime automaatselt
# või:
bash setup-vmware-shared-folder.sh SharedVM        # määra nimi käsitsi
```

---

## Ekraanisäästja keelamine — Ubuntu/GNOME

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
