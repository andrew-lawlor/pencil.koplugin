# Desktop tests

`run.sh` runs the plugin in KOReader's Linux desktop build, headless, with `forktest.koplugin` driving it: it draws with the plugin's own stroke functions, changes the font, renames books through KOReader's own code, and writes what it checked to a JSON file per test. The positions it draws at suit `odyssey.epub` at 1053×1400.

`odyssey.epub` is [Standard Ebooks](https://standardebooks.org/ebooks/homer/the-odyssey/william-cullen-bryant)' edition of Homer's *Odyssey*, translated by William Cullen Bryant (its metadata as edited in calibre): public domain in the United States, with Standard Ebooks' work dedicated to the public domain (CC0 1.0).
