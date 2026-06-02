# Web eID Safari laienduse versiooni-kontroll (macOS)

Safari laiendused erinevad teistest brauseritest:

- **Distub macOS-i rakenduse osana** — TestFlight pre-release-i jaoks, App Store release-i jaoks
- **EI saa kasutada "Load unpacked" ega "Temporary Add-on"** stiilis arendaja-laadimist (nagu Chrome/Firefox)
- **Laiendus elab macOS-i rakenduse `.appex` bundle-i sees** — bundeldatud osa peamisest rakendusest

Seetõttu pole Safari jaoks ka versiooni-kontrolli skripti — kõik on käsitsi vaadeldav.

## 1. Laienduse versioon (Safari UI-st)

1. Ava **Safari**
2. Menu **Safari → Settings…** (`⌘,`) — vanemates macOS-ides "Preferences"
3. Vahekaart **Extensions**
4. Vasakult nimekirjast leia **Web eID**
5. Versioon on kuvatud laienduse nime kõrval / sees, tihti formaadis `Web eID  2.5.0`

## 2. Bundeldatud `web-eid.js` teegi versioon (terminalist)

Avab paigaldatud Web eID rakenduse paki ja otsib bundeldatud JS-failidest `VERSION` konstandid:

```bash
# Vaikimisi paigalduskoht - kohanda nimi vajadusel
APP="/Applications/Web eID.app"

# Kui rakenduse tapne nimi erineb, leia see esmalt:
ls /Applications/ | grep -i "web.*eid"

# Otsi VERSION konstandid kogu paki seest
find "$APP" -name "*.js" -type f -exec grep -oh 'VERSION:[[:space:]]*"[0-9.]\+"' {} \; 2>/dev/null | sort -u
```

Tulemus näitab kõik unikaalsed `VERSION:"X.Y.Z"` konstandid bundle-st.
Üks neist on laienduse enda versioon (sama mis Safari UI-s), teine
bundeldatud `lib/web-eid.js` teegi versioon — sama loogika nagu
Firefox/Chrome puhul.

Näide:

```
VERSION:"2.1.0"   <- lib/web-eid.js teek
VERSION:"2.5.0"   <- laienduse enda config
```

## 3. Paki päritolu (TestFlight)

Pre-release Safari-versioon distub **Apple TestFlight-i** kaudu:

1. Tester saab Web eID tiimi sisemise TestFlight-i kutse (email-link)
2. Paigalda **TestFlight** macOS-rakendus (Mac App Store-st), kui pole
3. Ava saadetud TestFlight-link → TestFlight installib Web eID rakenduse
   `/Applications/` alla nagu tavarakenduse
4. Pärast paigaldust avab Safari Settings → Extensions — Web eID ilmub
   nimekirja, märgi linnuke aktiveerimiseks

Erinevalt Chrome/Firefox-i testimisest **pole "load unpacked" / "temporary
add-on" võimalust Safaril** — TestFlight on ainus arendaja-testimise tee.

## 4. Lühike raporti-rida (Safari)

Käsitsi koosta vastavalt sellele, mida Safari UI ja terminal näitavad:

```
Safari <versioon> macOS-il | Web eID <ext-versioon> | web-eid.js <lib-versioon> | TestFlight (build #N)
```

Näide:

```
Safari 17.4 macOS 14.5 | Web eID 2.5.0 | web-eid.js 2.1.0 | TestFlight build #427
```

TestFlight build-numbri leiab TestFlight rakenduse Web eID lehel paremas
ülanurgas (või Web eID app-i Get Info aknas Finder-is).

## Märkused

- Safari laiendus suhtleb Web eID native-osaga **Safari-spetsiifilise XPC kaudu**,
  mitte Chrome/Firefox stiilis native messaging-iga — protokoll ja
  paigaldus-ahel on platvormi-spetsiifiline.
- Kui TestFlight build paigaldatakse uue versiooniga, vana Web eID
  asendub automaatselt — pole vaja vana käsitsi eemaldada.
- Safari Settings → Extensions näitab samuti laienduse paigalduse
  asukohta (Web eID app-i nimega) — see kinnitab, et laiendus tuleb
  TestFlight-paigaldatud app-ist, mitte mõnest muust allikast.
