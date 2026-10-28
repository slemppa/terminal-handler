# Terminal Handler

Pieni macOS-saari, joka näyttää kaikki Ghostty-terminaalit (repo, branch, mitä tapahtuu) ja Claude Coden tilan. Kun Claude kysyy lupaa tai esittää monivalintakysymyksen, saari aukeaa ja voit vastata siinä tai hypätä oikeaan terminaaliin.

## Asennus

```sh
scripts/bundle.sh          # rakentaa, allekirjoittaa ja asentaa ~/Applications/TerminalHandler.app
open ~/Applications/TerminalHandler.app
```

Ensimmäisellä käynnistyksellä:
1. macOS kysyy lupaa ohjata Ghosttya: valitse **Salli**.
2. Sovellus tarjoaa Claude-hookien asennusta `~/.claude/settings.json`:iin (varmuuskopio otetaan ensin, muut hookit säilyvät). Hookit voi asentaa tai poistaa myöhemmin saaren oikean klikin valikosta.

## Käyttö

- **Pisteet:** oranssi = odottaa sinua, sininen = valmis, vihreä = Claude töissä, himmeä vihreä = muu komento ajossa, harmaa = vapaa.
- **Hiiri saaren päälle** avaa listan. Klikkaus hyppää terminaaliin.
- **Raahaa** saari mihin tahansa kohtaan näyttöä; paikka muistetaan.
- **⌃⌥Space** avaa listan näppäimistöllä; sen jälkeen ⌘1…⌘9 hyppää, Esc sulkee.
  Pikanäppäimen voi vaihtaa: `defaults write fi.slemppa.TerminalHandler hotkeyKeyCode -int <keycode>` ja `hotkeyModifiers -int <carbon-modifiers>`.
- Jos menet itse kysyvään terminaaliin, kysymys siirtyy takaisin Clauden omaan promptiin.
- Jos sovellus ei ole käynnissä tai jumittuu, Claude toimii täsmälleen kuten ilman sitä.

## Kehitys

```sh
swift test     # THCore: tilamalli, hook-protokolla, git, asentaja
swift build
```
