--[[--
Unit tests for the markup export (lib/export) and the word walk (lib/words).
Run with: busted spec/export_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local Export = require("lib/export")
local Words = require("lib/words")

local function stroke(datetime, x, y, markup)
    return { datetime = datetime, markup = markup, width = 3, color_name = "Black", tool = "pen",
             points = { { x = x, y = y }, { x = x + 10, y = y + 5 } } }
end

describe("Export", function()

    it("names a markup after its first stroke", function()
        assert.equals("m_20261002184721_224_1018", Export.markupId(stroke(1790966841, 224, 1018)))
    end)

    it("gathers a markup's strokes in writing order", function()
        local strokes = { stroke(5, 0, 0, "a"), stroke(1, 0, 0, "b"), stroke(3, 0, 0, "a"), stroke(3, 9, 9, "a") }
        local a = Export.strokesOf(strokes, "a")
        assert.equals(3, #a)
        assert.equals(strokes[3], a[1])
        assert.equals(strokes[4], a[2])
        assert.equals(strokes[1], a[3])
        assert.same({ "a", "b" }, Export.ids(strokes))
    end)

    it("changes the signature when the ink does", function()
        local strokes = { stroke(1, 0, 0, "a"), stroke(2, 5, 5, "a") }
        local before = Export.signature(strokes)
        assert.equals(before, Export.signature({ stroke(1, 0, 0, "a"), stroke(2, 5, 5, "a") }))
        table.remove(strokes, 1)
        assert.are_not.equal(before, Export.signature(strokes))
    end)

    it("writes ink as point pairs with the stroke's anchor", function()
        local s = stroke(1, 10, 20, "a")
        s.anchor = { xpointer = "/p", dx = 1, dy = 2 }
        local ink = Export.ink({ s })
        assert.equals(1, ink.format)
        assert.same({ { 10, 20 }, { 20, 25 } }, ink.strokes[1].points)
        assert.equals("/p", ink.strokes[1].anchor.xpointer)
        assert.equals("Black", ink.strokes[1].color)
    end)

    it("dates a markup by its strokes and records the capture", function()
        local m = Export.markup("m_x", { stroke(5, 0, 0), stroke(2, 0, 0), stroke(9, 0, 0) },
            { page = 40, start = "/a", finish = "/b", has_image = true }, { doc_path = "/b.epub" }, "fork-1")
        assert.equals(2, m.created)
        assert.equals(9, m.modified)
        assert.equals("/a", m.start)
        assert.equals("/b", m["end"])
        assert.is_true(m.has_page_image)
        assert.equals("/b.epub", m.document.doc_path)
    end)

end)

-- A document of words laid out three to a line, 100 px wide and 40 tall.
local function fakeDoc(texts, on_screen_from, on_screen_to)
    local doc = { _document = {} }
    local function xp(i) return "w" .. i end
    local function idx(p) return tonumber(p:match("%d+")) end
    function doc:getTextFromPositions() return { pos0 = xp(on_screen_from), pos1 = xp(on_screen_to) } end
    function doc:getPrevVisibleChar(p) return p end
    function doc:getNextVisibleWordStart(p)
        local i = idx(p)
        if p:sub(1, 1) == "e" then i = i + 1 end
        return i <= #texts and xp(i) or nil
    end
    function doc:getNextVisibleWordEnd(p) return "e" .. idx(p) end
    function doc:compareXPointers(a, b)
        local ia, ib = idx(a), idx(b)
        if ia == ib then return 0 end
        return ib > ia and 1 or -1
    end
    function doc:getTextFromXPointers(a) return texts[idx(a)] end
    function doc._document:getWordBoxesFromPositions(a)
        local i = idx(a) - 1
        local x, y = (i % 3) * 110, math.floor(i / 3) * 50
        return { { x0 = x, y0 = y, x1 = x + 100, y1 = y + 40 } }
    end
    return doc
end

describe("Words", function()

    it("walks the words on screen, with boxes, and stops at the last", function()
        local doc = fakeDoc({ "Sing", "O", "Muse", "of", "the", "man", "beyond" }, 2, 6)
        local words, first, last = Words.onScreen(doc, 1000, 1000)
        local texts = {}
        for k, w in ipairs(words) do texts[k] = w.text end
        assert.same({ "O", "Muse", "of", "the", "man" }, texts)
        assert.same({ 110, 0, 210, 40 }, words[1].boxes[1])
        assert.equals("w2", first)
        assert.equals("w6", last)
    end)

    it("is empty without text on screen", function()
        local doc = fakeDoc({}, 1, 1)
        function doc:getTextFromPositions() return nil end
        assert.same({}, (Words.onScreen(doc, 10, 10)))
    end)

end)
