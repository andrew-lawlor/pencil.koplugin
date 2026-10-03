--[[--
Unit tests for marks that follow their words (lib/refit): telling
underlines and circles from other ink, what they mark, and drawing them
again under or around those words on another layout.
Run with: busted spec/refit_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"
local Refit = require("lib/refit")

-- Two lines of four words.
local function words()
    local function w(text, x0, y0, x1) return { text = text, boxes = { { x0, y0, x1, y0 + 40 } }, pos0 = text .. "0", pos1 = text .. "1" } end
    return {
        w("Laertes,", 20, 100, 180), w("when", 200, 100, 300), w("his", 320, 100, 380), w("fatal", 400, 100, 500),
        w("With", 20, 160, 110), w("death’s", 130, 160, 280), w("long", 300, 160, 380), w("sleep.", 400, 160, 520),
    }
end

describe("Refit.markOf", function()
    it("knows an underline and the words above it", function()
        local m = Refit.markOf({ x0 = 205, y0 = 144, x1 = 375, y1 = 150 }, words())
        assert.equals("underline", m.kind)
        assert.equals("when0", m.pos0)
        assert.equals("his1", m.pos1)
        assert.is_true(m.below > 0 and m.below < 0.3)
    end)

    it("knows a circle and the word inside it, not its neighbours", function()
        local m = Refit.markOf({ x0 = 100, y0 = 150, x1 = 310, y1 = 210 }, words())
        assert.equals("circle", m.kind)
        assert.equals("death’s0", m.pos0)
        assert.equals("death’s1", m.pos1)
    end)

    it("leaves handwriting alone", function()
        -- A letter in the margin, and a short scribble.
        assert.is_nil(Refit.markOf({ x0 = 600, y0 = 100, x1 = 630, y1 = 140 }, words()))
        assert.is_nil(Refit.markOf({ x0 = 600, y0 = 300, x1 = 700, y1 = 312 }, words()))
    end)
end)

describe("Refit.fit", function()
    local underline = { { x = 205, y = 146 }, { x = 290, y = 148 }, { x = 375, y = 146 } }
    local bbox = { x0 = 205, y0 = 146, x1 = 375, y1 = 148 }

    it("draws an underline under each line the words are on now", function()
        local m = { kind = "underline", below = 0.15 }
        -- At a bigger size the words wrap: one piece at the end of a line,
        -- one at the start of the next.
        local out = Refit.fit(m, underline, bbox, { { 700, 300, 900, 360 }, { 20, 380, 120, 440 } })
        assert.equals(2, #out)
        assert.equals(700, out[1][1].x)
        assert.equals(900, out[1][3].x)
        assert.is_true(out[1][1].y > 360 and out[1][1].y < 380)
        assert.equals(20, out[2][1].x)
        assert.equals(120, out[2][3].x)
        assert.is_true(out[2][2].y > 440)
    end)

    it("draws a circle around the words with the same room", function()
        local m = { kind = "circle", pad = { 0.5, 0.25, 0.5, 0.25 } }
        local ring = { { x = 100, y = 150 }, { x = 310, y = 180 }, { x = 100, y = 210 } }
        local out = Refit.fit(m, ring, { x0 = 100, y0 = 150, x1 = 310, y1 = 210 }, { { 400, 500, 600, 560 } })
        -- Line height 60: 30 px either side, 15 above and below.
        assert.equals(370, out[1][1].x)
        assert.equals(485, out[1][1].y)
        assert.equals(630, out[1][2].x)
        assert.equals(575, out[1][3].y)
    end)
end)
