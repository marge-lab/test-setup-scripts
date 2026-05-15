# test-setup-scripts

Paigaldus-skriptid Web eID näiterakenduste kiireks ülesseadmiseks.

| Skript | Platvorm |
|---|---|
| [`setup-web-eid-php.sh`](setup-web-eid-php.sh) | Ubuntu |
| [`setup-web-eid-java.sh`](setup-web-eid-java.sh) | Ubuntu, macOS |

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

## Eeldused

**Java-skript** vajab ngrok auth tokenit (küsitakse sammus 3/7). Tee
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
