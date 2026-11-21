# Jarvis puhelimesta

"Hei Siri, Jarvis" → sanelet komennon → Jarvis tekee sen Macilla → puhelin lukee vastauksen ääneen. Kun komento tulee puhelimesta, Mac on hiljaa. Jos Jarvis tarvitsee luvan, kysymys tulee puhelimeen: valitse **Salli** tai **Kiellä**. Sama kysymys näkyy myös Macin saarekkeessa, ja kumpi tahansa vastaus kelpaa.

Puhelin pääsee Macille Tailscalen kautta. Yhtään porttia ei avata internetiin, ja Jarvis kuuntelee edelleen vain osoitetta `127.0.0.1`.

## 1. Tailscale

1. Asenna Tailscale Macille ja iPhonelle. Kirjaudu molemmilla samalla tilillä.
2. Avaa Tailscalen hallintapaneeli (DNS-sivu) ja laita päälle **MagicDNS** ja **HTTPS Certificates**.
3. Aja Macilla:

   ```sh
   tailscale serve --bg 8765
   ```

   App Storen Tailscalessa komento on `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
4. `tailscale serve status` näyttää osoitteen, esim. `https://oma-mac.tail1234.ts.net`. Tätä osoitetta käytetään alla nimellä `OSOITE`.

**Älä käytä komentoa `tailscale funnel`.** Se avaisi Jarvisin koko internetiin.

## 2. Testaa Macilla

```sh
KEY=$(defaults read fi.slemppa.TerminalHandler jarvisAPIKey)
curl -s OSOITE/jarvis/command \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"text":"Paljonko levytilaa on jäljellä?"}'
```

Vastaus on JSON, ja Mac pysyy hiljaa. Jos `status` on `working`, kysy tilaa uudelleen samalla `id`:llä:

```sh
curl -s OSOITE/jarvis/status -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -d '{"id":"job-…"}'
```

## 3. Pikakomento "Jarvis" iPhonessa

Kopioi avain Macilta: saareke → oikea klikkaus → Jarvis → **Kopioi API-avain**. Siirrä se puhelimeen esim. Applen jaetulla leikepöydällä.

Kaikissa kolmessa *Hae URL:n sisältö* -toiminnossa on samat asetukset:
- Menetelmä **POST**
- Otsake `Authorization` = `Bearer <avain>`
- Pyynnön runko **JSON**

Toiminnot järjestyksessä:

1. **Sanele teksti**. Kieli: suomi. Lopeta kuuntelu: tauon jälkeen.
2. **Hae URL:n sisältö**: `OSOITE/jarvis/command`. JSON-runko: `text` = *Saneltu teksti*.
3. **Aseta muuttuja** `Vastaus` = *URL:n sisältö*.
4. **Toista** 40 kertaa:
   1. **Hae sanakirjan arvo** `status` muuttujasta `Vastaus`.
   2. **Jos** *Sanakirjan arvo* on `working`:
      - **Hae URL:n sisältö**: `OSOITE/jarvis/status`. JSON-runko: `id` = `Vastaus`:n `id`.
      - **Aseta muuttuja** `Vastaus` = *URL:n sisältö*.
   3. **Muuten**:
      - **Jos** *Sanakirjan arvo* on `prompt`:
        - **Puhu teksti**: `Vastaus`:n `say`.
        - **Valitse luettelosta**: `Vastaus`:n `options`. Kehote: `Vastaus`:n `question`.
        - **Hae URL:n sisältö**: `OSOITE/jarvis/answer`. JSON-runko: `id` = `Vastaus`:n `id`, `prompt_id` = `Vastaus`:n `prompt_id`, `choice` = *Valittu kohde*.
        - **Aseta muuttuja** `Vastaus` = *URL:n sisältö*.
      - **Muuten** (`done` tai `failed`):
        - **Puhu teksti**: `Vastaus`:n `say`.
        - **Lopeta pikakomento**.

Jokainen pyyntö odottaa korkeintaan 25 s. 40 kierrosta riittää siis noin 16 minuutin työhön.

Nimeä pikakomento "Jarvis". Sen jälkeen "Hei Siri, Jarvis" käynnistää sen. Kun pikakomento ajetaan Sirin kautta, Siri lukee myös Salli/Kiellä-vaihtoehdot ja voit vastata äänellä.

## Rajapinta

Kaikki kutsut ovat POST-pyyntöjä, JSON-runkoisia ja vaativat `Authorization: Bearer <avain>` -otsakkeen. Avain vaaditaan aina, vaikka `jarvisRequireKey` olisi pois päältä.

| Polku | Runko |
|---|---|
| `/jarvis/command` | `{"text": "…"}` |
| `/jarvis/status` | `{"id": "job-…"}` |
| `/jarvis/answer` | `{"id": "job-…", "prompt_id": "…", "choice": "Salli"}` |

Vastauksen kentät:
- `id`
- `status`: `working`, `prompt`, `done` tai `failed`
- `say`: puhuttava teksti
- `reply`: koko vastaus
- `step`: mitä Jarvis tekee juuri nyt
- `question`, `options` ja `prompt_id`: vain kun `status` on `prompt`

Luvan antaa vain selvä kyllä: `Salli`, `kyllä`, `joo`, `allow` tai `yes`. Kaikki muu tulkitaan kielloksi.

## Asetukset

- `defaults write fi.slemppa.TerminalHandler jarvisRemoteEnabled -bool false` sulkee puhelinreitit.
- `defaults write fi.slemppa.TerminalHandler jarvisRemoteHosts -array oma.nimi`: muut Host-nimet, jotka sallitaan `*.ts.net`-nimien lisäksi.
- Pyynnöt kirjataan tiedostoon `~/Library/Application Support/TerminalHandler/jarvis-requests.log`.
