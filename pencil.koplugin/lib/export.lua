--[[--
The markup export (format 1): the contract with readers such as Kollate.

One markup is the ink of one visit to a page. Each is a folder in the
book's settings folder, `pencil/markups/<id>/`, holding:
- markup.json, written last (its presence means the folder is complete);
- ink.json, the strokes in page pixels, in writing order;
- page.png, the page as rendered, without the plugin's ink, in grey;
- words.json, every word on the page with its boxes and positions.

Pure functions that build the JSON tables; main.lua does the writing.

@module pencil.lib.export
--]]--

local Store = require("lib/store")

local Export = {}

Export.FORMAT = 1
Export.DIR = "pencil/markups"

--- A markup id, from the stroke that starts it.
function Export.markupId(stroke)
    return (Store.groupId(stroke):gsub("^pencil_", "m_"))
end

--- The strokes of a markup, in writing order (by time, then position in
-- the list).
function Export.strokesOf(strokes, id)
    local found = {}
    for i, s in ipairs(strokes) do
        if s.markup == id then table.insert(found, { i = i, s = s }) end
    end
    table.sort(found, function(a, b)
        local ta, tb = a.s.datetime or 0, b.s.datetime or 0
        if ta ~= tb then return ta < tb end
        return a.i < b.i
    end)
    local out = {}
    for k, f in ipairs(found) do out[k] = f.s end
    return out
end

--- Every markup id in `strokes`, each once.
function Export.ids(strokes)
    local seen, ids = {}, {}
    for _, s in ipairs(strokes) do
        if s.markup and not seen[s.markup] then
            seen[s.markup] = true
            table.insert(ids, s.markup)
        end
    end
    return ids
end

--- A short string that changes whenever a markup's ink does: compared to
-- decide whether its files need writing again.
function Export.signature(strokes)
    local parts = {}
    for _, s in ipairs(strokes) do
        local p = s.points or {}
        local last = p[#p] or {}
        parts[#parts + 1] = string.format("%d:%d:%d,%d:%s", s.datetime or 0, #p,
            last.x or 0, last.y or 0, s.color_name or "")
    end
    return table.concat(parts, ";")
end

--- ink.json's table.
function Export.ink(strokes)
    local out = {}
    for _, s in ipairs(strokes) do
        local points = {}
        for k, p in ipairs(s.points or {}) do points[k] = { p.x, p.y } end
        out[#out + 1] = {
            points = points,
            width = s.width,
            color = s.color_name,
            tool = s.tool,
            datetime = s.datetime,
            anchor = s.anchor,
        }
    end
    return { format = Export.FORMAT, strokes = out }
end

--- markup.json's table. `capture` holds what was taken from the screen
-- (page, start, finish, chapter, screen, layout); `document` the book.
function Export.markup(id, strokes, capture, document, plugin_version)
    local created, modified
    for _, s in ipairs(strokes) do
        local t = s.datetime or 0
        created = math.min(created or t, t)
        modified = math.max(modified or t, t)
    end
    capture = capture or {}
    return {
        format = Export.FORMAT,
        id = id,
        created = created,
        modified = modified,
        document = document,
        page = capture.page,
        start = capture.start,
        ["end"] = capture.finish,
        chapter = capture.chapter,
        screen = capture.screen,
        layout = capture.layout,
        has_page_image = capture.has_image or false,
        plugin_version = plugin_version,
    }
end

return Export
