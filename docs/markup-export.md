# Markup export, format 1

The plugin writes what you write on each page to the book's settings folder, so other apps can use your handwriting without reading KOReader's internal files. [Kollate](https://github.com/andrew-lawlor/kollate) is the first reader. This page describes the format, which changes only with a new `format` number.

## Markups

A **markup** is the ink of one visit to a page: everything you draw on a page between arriving and leaving. If you come back later and write more, that's a new markup. Erasing strokes rewrites the markup they belong to, and erasing all of them removes its folder.

Each markup is a folder:

```
<book>.sdr/pencil/markups/<id>/
  markup.json   written last: if it's there, the folder is complete
  ink.json      the strokes
  page.png      the page as it looked, without the plugin's ink
  words.json    every word on the page, with its boxes and positions
```

`<book>.sdr` is wherever KOReader keeps the book's settings (beside the book by default). Ids look like `m_20261002144143_512_880`: the UTC time of the markup's first stroke and its first point. They never change once made.

Each file is written under a temporary name and renamed into place, `markup.json` last. **Ignore folders without `markup.json`**: they're being written.

## markup.json

| Field | Meaning |
|---|---|
| `format` | `1` |
| `id` | The folder's name |
| `created`, `modified` | Times of the first and last stroke, in Unix seconds |
| `document` | `doc_path` (the book's path on the device) and `partial_md5` (KOReader's checksum of the file) |
| `page` | The page number at the time. Advisory only: it changes with the font, margins or screen. Use `start` and `end` to place the markup. |
| `start`, `end` | XPointers of the first and last positions on screen |
| `chapter` | The chapter title, if the book has one for that page |
| `screen` | `width`, `height` in pixels, and `rotation` (KOReader's rotation mode, 0–3) |
| `layout` | What decides where words fall: `font_face`, `font_size`, `line_spacing`, `h_page_margins`, `t_page_margin`, `b_page_margin` |
| `has_page_image` | Whether `page.png` was written |
| `plugin_version` | The plugin version that wrote the folder |

Fields can be missing when the plugin couldn't capture the page (for example, ink drawn before this fork, on a page not shown again since). `start`, `end`, `layout` and `words.json` are written only for reflowable books (EPUB and the like). PDFs and other fixed-layout documents get `ink.json`, `page.png` and `markup.json` without them, for now.

## ink.json

```json
{ "format": 1, "strokes": [
  { "points": [[512, 880], [515, 881]], "width": 3, "color": "Black", "tool": "pen",
    "datetime": 1790966503,
    "anchor": { "xpointer": "/body/DocFragment[9]/body/div/div/p[18]/span[3]/text().4", "dx": -1.5, "dy": 0.2 } }
] }
```

- Strokes are in the order they were written.
- `points` are the stroke's centre line, in screen pixels of the page as captured (`markup.json`'s `screen`), so they line up with `page.png` and with `words.json`'s boxes. Draw them as lines `width` pixels wide.
- `color` is the pen colour's name, `tool` is `pen` or `highlighter`, and `datetime` is in Unix seconds.
- `anchor` ties the stroke to the text: the XPointer of the nearest word, and the offset of the stroke's centre from that word's box, measured in line heights (`dx` from its left edge, `dy` from its top). Use it to place the stroke on a different layout. It's missing if the stroke couldn't be anchored. A stroke wholly in a page margin also has `margin` (`left` or `right`) and `gap`, the distance in pixels from the text's edge to the stroke's centre: on another layout, it belongs in that margin, as far from the text, level with its word. Both are optional and new in 0.6.3; format 1 readers can ignore them.

## page.png

The whole screen, as KOReader drew it, in 8-bit grey, without the plugin's ink. KOReader's own highlights stay in. Same size as `screen`.

## words.json

```json
{ "format": 1, "words": [
  { "text": "fatal", "boxes": [[402, 873, 466, 905]],
    "pos0": "/body/DocFragment[9]/body/div/div/p[18]/text().31",
    "pos1": "/body/DocFragment[9]/body/div/div/p[18]/text().36" }
] }
```

Every word on screen, in reading order. `boxes` holds one `[x0, y0, x1, y1]` box per line the word is on: a word hyphenated across two lines has two. `pos0` and `pos1` are the word's start and end in the book.

With the boxes, you can tell which words a stroke underlines or circles from the geometry alone, without reading `page.png`.

## When files are written

The page is captured shortly after you arrive on it (or after you rest the pen, if you start writing straight away), and once KOReader has finished laying out the book. Files are written after about 8 seconds without writing, and all at once when you close the book or the Kobo goes to sleep. Nothing is written while the pen is on the screen.
