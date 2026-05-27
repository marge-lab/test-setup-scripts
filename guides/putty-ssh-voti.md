# PuTTY: SSH-võtmega ühenduse seadistamine (Windows)

Kuidas panna SSH privaatvõti PuTTY-sse, salvestada sessioon ja ühenduda
serverisse ilma parooli iga kord sisestamata.

## Eeldused

- PuTTY ja PuTTYgen on installitud (tulevad samas paketis)
- Sul on **OpenSSH-vormingus privaatvõti** (fail algab reaga
  `-----BEGIN OPENSSH PRIVATE KEY-----`)
- Avalik võti (`.pub`) on serveris failis `~/.ssh/authorized_keys`

> **Tähtis:** PuTTY ei kasuta OpenSSH-võtit otse — vaja on `.ppk`-vormingut.
> Seetõttu tuleb võti esmalt teisendada.

## Kuidas võtme vormingut ära tunda

Ava võtmefail Notepadis ja vaata esimest rida:

| Faili algus | Mida tähendab |
|---|---|
| `PuTTY-User-Key-File-2` / `-3` | Juba `.ppk` — sobib PuTTY-sse otse |
| `-----BEGIN OPENSSH PRIVATE KEY-----` | OpenSSH privaatvõti — **vaja teisendada** |
| `-----BEGIN RSA PRIVATE KEY-----` | Vana PEM privaatvõti — vaja teisendada |
| `ssh-ed25519 AAAA...` (üks rida) | **Avalik** võti — see ei lähe PuTTY-sse, vaid serverisse |

## 1. samm — Teisenda võti `.ppk`-ks (PuTTYgen)

1. Ava **PuTTYgen** (Windowsi otsing → "PuTTYgen")
2. Menüü: **`Conversions → Import key`**
3. Vali oma privaatvõtme fail
4. Kui võtmel on parool (passphrase), sisesta see
5. Vajuta **`Save private key`** → salvesta nt `minu-voti.ppk`

Tulemus: sul on nüüd `.ppk` fail.

## 2. samm — Pane võti PuTTY sessiooni

PuTTY peaaknas, vasakus **Category** puus:

1. Mine: **`Connection → SSH → Auth → Credentials`**
2. Väli **"Private key file for authentication"** → **`Browse...`** → vali `.ppk` fail
3. Välja **"Certificate to use..."** jäta tühjaks

## 3. samm — Sea kasutajanimi

1. Mine: **`Connection → Data`**
2. Väli **"Auto-login username"** → sisesta SSH kasutajanimi
   (nt `ubuntu`, `root`, `marge` — sõltub serverist)

## 4. samm — Salvesta sessioon

1. Mine puus tippu lehele **`Session`**
2. **Host Name** → serveri aadress (IP või domeen)
3. **Port** → `22`
4. **Saved Sessions** all olevasse **tekstilahtrisse** kirjuta sessiooni nimi
   (nt `minu-server`) — **mitte** "Default Settings" peale
5. Vajuta **`Save`**

Nimekirja tekib:

```
Default Settings    ← PuTTY vaikeprofiil (jääb alati alles, ära kustuta)
minu-server         ← sinu salvestatud sessioon
```

## Kasutamine edaspidi

1. Ava PuTTY
2. Vali nimekirjast **`minu-server`** → **`Load`** (või topeltklikk)
3. **`Open`** → ühendub võtmega automaatselt

## Turvalisus

- Privaatvõti (`BEGIN OPENSSH PRIVATE KEY` ja `.ppk`) on **salajane** — ära
  seda kellelegi saada ega kuhugi üles lae.
- Serverisse käib **ainult** avalik võti (`.pub`).

## Pageant — ühendu ilma parooli iga kord sisestamata

Kui võtmel on parool (passphrase), küsib PuTTY seda iga ühenduse korral.
**Pageant** (PuTTY võtmeagent) hoiab võtit mälus: sisestad parooli üks kord,
seejärel kõik PuTTY sessioonid logivad ilma küsimata. Võti jääb parooliga
kaitstuks — turvaline lahendus.

### 1. Lisa võti Pageanti

1. Windowsi otsing → **"Pageant"** → ava (läheb süsteemisalve, kella kõrvale)
2. Topeltklikk Pageant-i ikoonil süsteemisalves → avaneb **Pageant Key List**
3. Vajuta **`Add Key`** (mitte "Add Key (encrypted)")
4. Vali oma **`.ppk`** fail
5. Sisesta võtme parool **üks kord** → võti ilmub nimekirja
6. Sulge aken nupuga **`Close`** (Pageant jääb taustale tööle)

Nüüd ava PuTTY ja ühendu — parooli enam ei küsi.

> Nuppude vahe:
> - **`Add Key`** — küsib parooli kohe, võti kasutusvalmis kogu sessiooni. **See on õige.**
> - **`Add Key (encrypted)`** — hoiab võtit krüpteerituna, küsib parooli alles esimesel kasutamisel.

### 2. Pane Pageant käivituma Windowsi alglaadimisel

Et ei peaks iga arvuti käivitamise järel võtit käsitsi lisama:

1. Vajuta **`Win + R`**, kirjuta `shell:startup`, **Enter** → avaneb Startup-kaust
2. Paremklikk kaustas → **Uus → Otsetee**
3. Asukoha väljale pane Pageant + võtmefaili tee (kohanda enda teedele):
   ```
   "C:\Program Files\PuTTY\pageant.exe" "C:\tee\sinu-votmeni\minu-voti.ppk"
   ```
   - Jutumärgid mõlemale teele, kui sees on tühikuid
4. **Edasi → Lõpeta**

Edaspidi: Windowsi käivitamisel avaneb Pageant ja küsib korra võtme parooli —
seejärel kõik PuTTY ühendused töötavad ilma küsimata.
