# Changelog

## 0.6.1 (2026-10-03)

- Fixed: writing on a page after pausing on it (once its picture had been taken) exported that markup without `page.png`, `words.json` or its page details. Markups missing them are completed the next time their page is shown.
- Tried on the Kobo Elipsa 2E: the pen, markup export and page pictures (1404×1872) work as on the Libra Colour.

## 0.6.0 (2026-10-02)

The first release of the maintained fork, continuing from the original plugin's 0.5.0.

### Faster

- Black ink is drawn with the display's fast waveform while you write and sharpened when you pause. On MediaTek Kobos such as the Libra Colour, the normal waveform made KOReader wait for the display controller, so the ink could stall for a quarter of a second mid-stroke. On a Libra Colour, the slowest point per stroke has a median of 3 ms (the original: 12 ms), and no stroke stalled for over 150 ms (the original: 2 of 63).
- Strokes are saved after you stop writing, not after nearly every stroke: 8 full saves in the busiest minute of writing, against 59. From the original repository's pull request #77.
- Strokes are stored as packed points: a real 204-stroke file went from 1,256 KB to 199 KB, every point identical. Also from #77.
- Saves, page pictures and exports never run while the pen is on the screen.

### New

- Each stroke is anchored to the word it was written beside, and a group of strokes keeps a stable id through erasing and undoing.
- Markup export: each page you write on gets a folder with your ink, a picture of the page and every word on it with its position. See [docs/markup-export.md](docs/markup-export.md).
- No replacement `input.lua`: KOReader 2026.07's own stylus support is enough, pen, eraser end and stylus button included.
- A profiler for measuring on a device (`lib/profile.lua`, off by default).
- Tests for the stroke store and the export (`busted spec/`).

### Upgrading

Your strokes are upgraded to the new format (version 5) the first time the fork saves them. The original plugin can't read version 5, so back up your books' `.sdr` folders if you might go back.
