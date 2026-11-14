# Credits

## Samples

**String Ensemble** and **Concert Flute** — *VSCO 2 Community Edition* by Versilian
Studios (recorded by Sam Gossner & Simon Dalzell): cello section, violin section and
solo flute. Released under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)
(public domain). Source: <https://github.com/sgossner/VSCO-2-CE>.

They are installed by `Scripts/fetch_free_samples.py`, which documents exactly which
files are used and how they are converted (mono, 44.1 kHz / 16-bit, trimmed, the
level of the held part evened out so the notes loop without pumping).

**Harmonium, Musette Accordion, Choir Ahs, Vox Humana** and **Hurdy-Gurdy** — built
from recordings in *GeneralUser GS 2.0.3* by S. Christian Collins
(<https://github.com/mrbumpy409/GeneralUser-GS>, <https://www.schristiancollins.com>).
Its licence allows free use, also commercially and in software projects. The author
also states plainly that, because the bank grew from samples collected from free
SoundFonts over many years, he cannot be completely certain of the origin of every
sample, and that this "may concern you if you intend to use GeneralUser GS in a
commercial software product" — while noting he has had no complaint since 2000.
**Read `documentation/LICENSE.txt` in that repository before publishing the app
commercially.** The instruments are built by `Scripts/build_soundfont_instruments.py`
(accordion reeds → harmonium and musette, concert choir, voice "oohs", solo violin →
hurdy-gurdy), which documents the conversion.

**Pipe Organ** (optional, not in this repository) — imported locally with
`Scripts/import_samples.py --source sfz`; check the licence of the library you import.

## Backdrop art

The instrument scenes in `OmnisphereSynth/Resources/Backgrounds/` were generated
with ChatGPT for this app.
