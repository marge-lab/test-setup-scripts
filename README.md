# test-setup-scripts

Paigaldus- ja seadistus-skriptid Linux VM-i kiireks ülesseadmiseks
testimistöö jaoks.

| Skript | Otstarve | Platvorm |
|---|---|---|
| [`setup-web-eid-php.sh`](setup-web-eid-php.sh) | Web eID PHP näiterakendus | Ubuntu |
| [`setup-web-eid-java.sh`](setup-web-eid-java.sh) | Web eID Java näiterakendus | Ubuntu, macOS |
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

## VMware Shared Folder — Ubuntu pool

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
chmod +x setup-vmware-shared-folder.sh
./setup-vmware-shared-folder.sh                 # tuvastab nime automaatselt
./setup-vmware-shared-folder.sh SharedVM        # määra nimi käsitsi
```

Ilma argumendita tuvastab skript `/mnt/hgfs` sisust jagamise nime
automaatselt (kui ainult üks olemas). Mitme jagamise puhul kuvab
listi ja palub uuesti nimega käivitada.

Skript on idempotentne ja iseparandav — võid uuesti käivitada kui
midagi muutus:
- Lisab fstab-rea ainult kui veel pole
- Eemaldab eelmistest käivitustest kuhjunud `/mnt/hgfs` monteerimised
- Värskendab sümbollinki, kui jagamise nimi muutus (eemaldab vana
  `~/Shared` ja loob uue `~/<jagamise-nimi>`)

Pärast valmimist on jagatud kaust kättesaadav:
- `/mnt/hgfs/<jagamise-nimi>` (täielik tee)
- `~/<jagamise-nimi>` (sümbollink kodukaustas, näha ka Files-rakenduses)

### Probleemilahendus

- **`Error -107 cannot open connection`** — host ei paku jagamist.
  Kontrolli VMware Settings: kas kaust on listis, kas "Always enabled"
  on peal, kas VM oli enne seadistust **päriselt powered off**, mitte
  suspendis.
- **`/mnt/hgfs` on tühi** — sama põhjus. Reinstall ka aitab:
  `sudo apt install --reinstall open-vm-tools open-vm-tools-desktop`
- **`mount | grep hgfs` näitab mitut rida** — käivita skripti uuesti,
  see puhastab kuhjunud kihid. Või lihtsalt reboot.

---

## Ekraanisäästja keelamine — Ubuntu/GNOME

Linux VM-id (eriti VMware-s) kipuvad ekraanisäästja tõttu hanguma.
Skript keelab kõik seotud GNOME seaded korraga ja kontrollib tulemused.

```bash
chmod +x disable-screensaver.sh
./disable-screensaver.sh
```

Seadistab:
- `org.gnome.desktop.screensaver lock-enabled` → false
- `org.gnome.desktop.screensaver idle-activation-enabled` → false
- `org.gnome.desktop.session idle-delay` → 0
- `org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type` → nothing
- `org.gnome.settings-daemon.plugins.power idle-dim` → false
- `org.gnome.desktop.screensaver ubuntu-lock-on-suspend` → false (Ubuntu-spetsiifiline)

Skript ei vaja sudo-d — seadistab ainult kasutaja dconf-i.
