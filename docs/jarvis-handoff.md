# Jarvis-tila: siirtomuistio

Tila 20.11.2026: rakennettu ja todennettu curlilla päästä päähän. FluidVoicella testattu: levytila- ja Brave-komennot toimivat, Satu puhuu.

## Tavoite

Sami painaa FluidVoicen Command Mode -näppäintä ja puhuu suomeksi. Transkripti menee taustalla pyörivälle Claude Code -istunnolle (Jarvis, `~/Jarvis`), joka tekee asian Macilla. Satu lukee vastauksen ääneen (`say -v Satu`). Terminal Handlerin saareke näyttää tilan, transkriptin, vastauksen ja lupakysymykset. Terminaali-ikkunaa ei tarvita.

## Rakenne

- **THCore/Jarvis**
  - HTTP-parseri, myös chunked.
  - OpenAI-pyynnön purku: viimeinen user-viesti on transkripti, sekä string- että parts-muodossa.
  - Vastaukset ilman streamia ja streamina (SSE ja `[DONE]`).
  - Pääsysäännöt: API-avain, Origin ja Host.
  - `SpeechText.clean`, sama tulos kuin `puhu.sh`:n perl-siivouksella.
  - 15 minuutin sessiosääntö.
  - stream-json-parseri.
- **Endpoint `127.0.0.1:8765`**
  - `GET /v1/models` palauttaa mallin `jarvis`.
  - `POST /v1/chat/completions` vastaa heti "Selvä, Jarvis hoitaa." ilman tool calleja.
  - Jos viimeinen viesti ei ole käyttäjän (esim. FluidVoicen oma tool-silmukka), vastaus on "Valmis." eikä Jarvis käynnisty.
  - Pyynnöt kirjataan: `~/Library/Application Support/TerminalHandler/jarvis-requests.log`.
- **Runner**
  - `claude -p --permission-mode auto --output-format stream-json --verbose [--resume id]` hakemistossa `~/Jarvis`, prompt stdinistä.
  - Session id ja aika ovat defaultsissa, joten jatkuvuus säilyy appin uudelleenkäynnistyksen yli. Jos resume kaatuu, ajetaan kerran uudella sessiolla.
  - Kiireisenä uusi komento menee jonoon. Saarekkeessa on "Keskeytä".
- **Puhe**
  - App ajaa `say -v Satu -r 195`.
  - `~/Jarvis/.claude/hooks/puhu.sh` ohittaa puheen, kun `JARVIS_FROM_APP` on asetettu, joten tuplapuhetta ei tule. Terminaalista käytettynä hook puhuu.
  - Klikkaus, "Hiljaa" tai Esc (globaali vain puheen ajan) katkaisee puheen. Uusi komento ei katkaise: se menee jonoon ja alkaa, kun Satu on puhunut loppuun.
- **Luvat**
  - App antaa lapselle `TH_JARVIS=1`. `th-hook` merkitsee hookit virtuaali-TTY:llä `jarvis` (`HookEnvelope.origin`).
  - Saarekkeessa näkyy "Saako Jarvis ajaa komennon?" ja Salli/Kiellä.
  - Ghostty-sessioiden logiikka ei muuttunut.
- **UI**
  - Pillerissä waveform ja tila (Kuulin / Miettii / Puhuu).
  - Jarvis-kortti: tila, työkaluaskel, transkripti ja vastaus. Sulkeutuu 5 s puheen jälkeen.
  - Toimii ilman Ghosttya.
- **Bugikorjaus:** tallennettu saarekkeen paikka rajataan näkyvälle alueelle.

## Todennettu

- `swift test`: 67 testiä / 12 suitea läpi. `scripts/bundle.sh` rakentaa, allekirjoittaa ja asentaa `~/Applications/TerminalHandler.app`, joka on käynnissä.
- Ilman avainta 401, Origin-header 403, `/v1/models` 200.
- Ei-stream-pyyntö (39 kt system prompt + tools): validi vastaus 14 ms:ssa, claude ajettiin `~/Jarvis`issa, Satu puhui kerran.
- Stream: 4 SSE-tapahtumaa ja `[DONE]`. Toinen pyyntö jatkoi samaa sessiota (`--resume`). Satu puhui kerran.

## Seuraavaksi (hyväksymislista)

1. Sami syöttää FluidVoicen Command Mode -asetukset:
   - Provider: **OpenAI-compatible**
   - Base URL: `http://127.0.0.1:8765/v1`
   - Model: `jarvis`
   - API key: saareke, oikea klikkaus, Jarvis, "Kopioi API-avain". Vaihtoehtoisesti `defaults read fi.slemppa.TerminalHandler jarvisAPIKey`.
2. Ensimmäinen oikea komento. Tarkista `jarvis-requests.log`: polku, lähettääkö FluidVoice avaimen, kutsuuko se `/models`. Jos avainta ei tule: `defaults write fi.slemppa.TerminalHandler jarvisRequireKey -bool false`.
3. Selvitä, lukeeko FluidVoice itse vastauksia ääneen. Jos lukee, tulee tuplapuhe.
4. Testaa: "Avaa Safari ja mene rascalai.fi", "Paljonko levytilaa on jäljellä?", lupaa vaativa komento (Salli/Kiellä saarekkeessa) ja jonoon menevä toinen komento.

## FluidVoicella todettu (20.11.)

- FluidVoice 1.6.13 lähettää avaimen (Bearer), kutsuu `/models` ja tallentaessaan yhteystestin: yksi user-viesti "test" ilman työkaluja. Testiin vastataan nyt "OK" käynnistämättä Jarvista (`ChatRequest.isConnectionProbe`).
- Command Mode lähettää koko chat-historian (esim. messages=6, tools=1) ja streamin.
- FluidVoicen punainen "Command"-ikkuna on sen expanded command output -notch (`CommandModeService.showExpandedNotchIfNeeded`). Sitä ei saa pois asetuksilla koneella, jossa ei ole notchia: piiloasetus `NotchPresentationMode=minimal` toimii vain notch-näytöllä. Sami hyväksyi ikkunan; suljetaan Escillä. Jos häiritsee: PR FluidVoicelle (asetus ehdoksi tuohon funktioon).
- `scripts/bundle.sh` ei käynnistänyt appia uudelleen asennuksen jälkeen; käynnistä `open ~/Applications/TerminalHandler.app`.

## Avoimet riskit

1. **Viive ja hinta.** Jokainen vuoro lataa koko globaalin Claude-kontekstin (hookit, skillit, MCP:t). Ensimmäinen vuoro kesti 12–19 s ja maksoi noin 0,64 $ (77 k cache-creation-tokenia). Keventäminen onnistuisi esim. `--setting-sources project` ja eksplisiittinen th-hook-asetus, mutta silloin globaalit luvat jäävät pois.
2. **FluidVoicen pyyntömuoto on todentamatta.**
3. **FluidVoicen kuittaus** "Selvä, Jarvis hoitaa." jää sen historiaan.
4. **Lupakortin aikakatkaisu on 30 min,** ja jono odottaa sen ajan.
5. **Mergekonflikti** päächeckoutin committaamattomien `IslandView.swift`/`IslandController.swift`-muutosten kanssa. Molemmissa on sama paikanrajaus: päächeckoutissa `resolved()`.

## Tiedostot koneella haaran ulkopuolella

- `~/Jarvis/CLAUDE.md`, `~/Jarvis/.claude/settings.json`, `~/Jarvis/.claude/hooks/{puhu,hiljaa}.sh`
- Alias `jarvis` tiedostossa `~/.zshrc`
- FluidVoice: `/Applications/FluidVoice.app`, defaults `com.FluidApp.app` (painallustila `PressAndHoldMode=false`)
