# Web eID Safari laienduse versiooni-kontroll (macOS)

Safari laiendused erinevad teistest brauseritest:

- **Distub macOS-i rakenduse osana** — TestFlight pre-release-i jaoks, App Store release-i jaoks
- **EI saa kasutada "Load unpacked" ega "Temporary Add-on"** stiilis arendaja-laadimist (nagu Chrome/Firefox)
- **Laiendus elab macOS-i rakenduse `.appex` bundle-i sees** — bundeldatud osa peamisest rakendusest

Seetõttu pole Safari jaoks ka versiooni-kontrolli skripti — kõik on käsitsi vaadeldav.

## NB! Safaril on **kolm erinevat versiooninumbrit**

Erinevalt Chrome/Firefox-ist, kus on kaks numbrit (laiendus + bundeldatud `web-eid.js`), on Safaril **kolm**:

| Versioon | Mis see on | Kust vaatad |
|---|---|---|
| **macOS Safari app** (nt `2.10.0`) | `web-eid-safari` projekti enda versioon — see, mille TestFlight installib | Finder → `web-eid-safari.app` → Get Info → Version |
| **Laienduse versioon** (nt `2.5.0`) | Bundeldatud `web-eid-webextension` versioon `.appex` sees | Safari → Settings → Extensions → Web eID, või terminalist (vt allpool) |
| **`web-eid.js` teek** (nt `2.1.0`) | Bundeldatud teegi versioon sama mis Chrome/Firefox puhul | Terminalist (vt allpool) |

Need on **kolm eraldi versiooni-rida** ja kõik tuleb raportis välja tuua.

## 1. macOS Safari app-i versioon (Finder Get Info)

1. Ava **Finder → Applications** (`⌘⇧A`)
2. Leia **`web-eid-safari.app`**
3. Paremklikk → **Get Info** (või vali ja `⌘I`)
4. **Version** rea kõrval kuvatakse macOS Safari app-i versioon (nt `2.10.0`)
5. **Kind** rea kõrval märgitakse `Beta Application (Universal)`, kui paigaldus tuli TestFlight-ist

## 2. Laienduse versioon (Safari UI-st)

1. Ava **Safari**
2. Menu **Safari → Settings…** (`⌘,`) — vanemates macOS-ides "Preferences"
3. Vahekaart **Extensions**
4. Vasakult nimekirjast leia **Web eID**
5. Versioon on kuvatud laienduse nime kõrval / sees, tihti formaadis `Web eID  2.5.0`

## 3. Bundeldatud `web-eid.js` teegi versioon (terminalist)

```bash
APP="/Applications/web-eid-safari.app"

# Leia Safari laienduse bundle (.appex)
find "$APP" -name "*.appex" -type d
# Tagastab: /Applications/web-eid-safari.app/Contents/PlugIns/web-eid-safari-extension.appex

# Otsi VERSION konstandid kogu paki seest
find "$APP" -name "*.js" -type f -exec grep -oh 'VERSION:[[:space:]]*"[0-9.]\+"' {} \; 2>/dev/null | sort -u
```

Oodatav tulemus:

```
VERSION: "2.1.0"   <- lib/web-eid.js teek
VERSION: "2.5.0"   <- laienduse enda config (sama mis Safari UI-s)
```

## 4. App-i nime kontroll, kui ei leia üles

Kui `/Applications/web-eid-safari.app` ei eksisteeri, on TestFlight ilmselt paigaldanud teise nimega või mujale:

```bash
# Otsi /Applications/ kataloogist
ls /Applications/ | grep -i eid

# Või Spotlightiga kõikjalt
mdfind -name "web-eid"
```

## 5. Paki päritolu (TestFlight)

Pre-release Safari-versioon distub **Apple TestFlight-i** kaudu:

1. Tester saab Web eID tiimi sisemise TestFlight-i kutse (email-link)
2. Paigalda **TestFlight** macOS-rakendus (Mac App Store-st), kui pole
3. Ava saadetud TestFlight-link → TestFlight installib `web-eid-safari.app`
   `/Applications/` alla nagu tavarakenduse
4. Pärast paigaldust avab Safari Settings → Extensions — Web eID ilmub
   nimekirja, märgi linnuke aktiveerimiseks

Erinevalt Chrome/Firefox-i testimisest **pole "load unpacked" / "temporary
add-on" võimalust Safaril** — TestFlight on ainus arendaja-testimise tee.

## 6. Raporti-rida (Safari)

Käsitsi koosta vastavalt sellele, mida Finder Get Info, Safari UI ja terminal näitavad:

```
Safari <versioon> macOS <versioon> | web-eid-safari app <macOS-app-versioon> | Web eID <ext-versioon> | web-eid.js <lib-versioon> | TestFlight build #N
```

Näide tegelikust testimisest:

```
Safari 17.4 macOS Monterey | web-eid-safari 2.10.0 | Web eID 2.5.0 | web-eid.js 2.1.0 | TestFlight Beta
```

TestFlight build-numbri leiab TestFlight rakenduse Web eID lehel paremas
ülanurgas (või `web-eid-safari.app` Get Info aknas Finder-is — Version-rea järel sulgudes).

## Märkused

- **Kolm versiooni** on tahtlik: macOS Safari rakendus on **eraldi projekt**
  (`web-eid-safari`), millel on oma versiooni-rida. Selle sees on
  bundeldatud `web-eid-webextension` (laiendus) ja selle sees omakorda
  bundeldatud `web-eid.js` teek. Iga komponent uueneb oma rütmis.
- Safari laiendus suhtleb Web eID native-osaga **Safari-spetsiifilise XPC kaudu**,
  mitte Chrome/Firefox stiilis native messaging-iga — protokoll ja
  paigaldus-ahel on platvormi-spetsiifiline.
- Kui TestFlight build paigaldatakse uue versiooniga, vana `web-eid-safari.app`
  asendub automaatselt — pole vaja vana käsitsi eemaldada.
- Safari Settings → Extensions näitab samuti laienduse paigalduse
  asukohta (`web-eid-safari` app-i nimega) — see kinnitab, et laiendus
  tuleb TestFlight-paigaldatud app-ist, mitte mõnest muust allikast.
