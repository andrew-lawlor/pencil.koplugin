# Changelog

## 0.6.4 (unreleased)

### Changed

- **Turning the screen is like changing the font.** Your notes are drawn beside their words and your underlines and circles under and around theirs, in landscape as in portrait, instead of a camera badge you had to tap to see a picture of them. Turn back and the ink is exactly as you wrote it. The badge is still shown for ink that can't follow its words: on a PDF, or older ink not yet anchored.

### Fixed

- **Renaming or copying a book no longer loses its ink.** KOReader moves a book's settings to a new folder when you rename it, but leaves the plugin's files behind. The plugin now remembers where a book's ink is and brings it along the next time the book opens: on a rename or move, the strokes, their pictures and the markup export move to the new folder; on a copy, they're copied and the original keeps its own. From the original repository's pull request #86 by bateast, extended to the fork's export and to copies. It works for ink saved with this version or later: ink from older versions has no location recorded until its book is opened once.

### Development

- The plugin is now tested in KOReader's own desktop build, headless (`tests/desktop/run.sh`): the markup export, the pen menu and Highlight tool, ink after a font change, and renaming and copying a book. These and the unit tests run on every push.

## 0.6.3 (2026-10-03)

### New

- **Ink follows the text after a font change.** Change the font, its size, the spacing or the margins, and your notes are drawn beside the words they were written beside, on whatever page those words are on now, instead of at their old position on a page that now shows other text. Each note moves as a whole, so handwriting keeps its shape; notes in a margin stay in it, as far from the text. Change back and the ink is exactly as you wrote it. You can erase moved ink where you see it. Underlines and circles are drawn again under and around the words they mark: a passage that wraps differently gets an underline on each of its lines, and a circled word keeps its circle wherever it lands. They're redrawn from your own stroke, stretched to fit, so they still look hand-drawn.

### Notes

- Each stroke now records the layout it was written in. Ink from before this version is taken to be in the layout the book opens in, which is right unless you changed the font after writing.

## 0.6.2 (2026-10-03)

### New

- **The pen menu:** the tool (pen, highlight, eraser), the pen's colour and its width in one place. Open it with a gesture of your choice (map **Pencil: pen menu** in the Gesture manager) or from the Pencil menu. It replaces the experimental colour and width pickers. Holding the pen still can still open it, but that's off by default: a pause while writing opened it too.
- **Highlight text with the pen:** choose Highlight in the pen menu (or map **Pencil: select highlight**), then drag across text to make a KOReader highlight. The selection shows inverted while you drag. If the pen skips off the glass mid-drag, the same highlight carries on, and dragging over a highlight that already exists doesn't add another.

### Changed

- Highlighting text with the stylus side button held (the experimental "Text highlight (side button)") is gone: it made several highlights from one drag, lagged behind the pen, and switched the pen to the eraser when the button was let go. The Highlight tool replaces it.
- Choosing in the pen menu shows no message: the message kept the pen from writing for a second.

### Fixed

- Drawing a highlighter stroke with the side button held could switch the pen to the eraser when the button was let go: KOReader reports the button after the stroke has begun.

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
