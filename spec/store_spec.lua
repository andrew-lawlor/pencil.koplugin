--[[--
Unit tests for the stroke store (lib/store) and anchors (lib/anchor):
stable group ids, the upgrade from version 3, and anchor round trips.
Run with: busted spec/store_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local Anchor = require("lib/anchor")
local Store = require("lib/store")

local function stroke(datetime, x, y)
    return { datetime = datetime, points = { { x = x, y = y }, { x = x + 10, y = y + 5 } } }
end

describe("Store", function()

    describe("groupId", function()

        it("depends only on the stroke", function()
            local s = stroke(1790966841, 224, 1018)
            assert.equals("pencil_20261002184721_224_1018", Store.groupId(s))
            assert.equals(Store.groupId(s), Store.groupId(stroke(1790966841, 224, 1018)))
        end)

        it("differs for strokes at the same time in different places", function()
            assert.are_not.equal(Store.groupId(stroke(1, 10, 10)), Store.groupId(stroke(1, 11, 10)))
        end)

        it("reads the first point of a packed stroke", function()
            local packed = { datetime = 1790966841, p = "224 1018 230 1020" }
            assert.equals("pencil_20261002184721_224_1018", Store.groupId(packed))
        end)

        it("copes with a stroke without points", function()
            assert.equals("pencil_19700101000005", Store.groupId({ datetime = 5, points = {} }))
        end)

    end)

    describe("firstStroke", function()

        it("is the earliest by time, then by index", function()
            local strokes = { stroke(30, 0, 0), stroke(10, 1, 1), stroke(10, 2, 2) }
            local group = { stroke_indices = { 1, 3, 2 } }
            assert.equals(strokes[2], Store.firstStroke(group, strokes))
        end)

        it("skips strokes that are gone", function()
            local strokes = { stroke(30, 0, 0) }
            assert.equals(strokes[1], Store.firstStroke({ stroke_indices = { 7, 1 } }, strokes))
        end)

    end)

    describe("groupXPointer", function()

        it("is the earliest anchored stroke's", function()
            local a, b, c = stroke(5, 0, 0), stroke(1, 0, 0), stroke(9, 0, 0)
            a.anchor = { xpointer = "/a" }
            c.anchor = { xpointer = "/c" }
            assert.equals("/a", Store.groupXPointer({ stroke_indices = { 1, 2, 3 } }, { a, b, c }))
            assert.is_nil(Store.groupXPointer({ stroke_indices = { 2 } }, { a, b, c }))
        end)

    end)

    describe("upgrade", function()

        it("gives a real version 3 file stable ids and keeps the old ones", function()
            local data = dofile("spec/fixtures/v3_pencil_strokes.lua")
            assert.equals(3, data.version)
            local old_ids = {}
            for i, g in ipairs(data.annotation_groups) do old_ids[i] = g.id end
            Store.upgrade(data)
            assert.equals(Store.VERSION, data.version)
            assert.equals(3, data.upgraded_from)
            for i, g in ipairs(data.annotation_groups) do
                assert.equals(Store.groupId(Store.firstStroke(g, data.strokes)), g.id)
                if g.id ~= old_ids[i] then
                    assert.equals(old_ids[i], g.legacy_id)
                end
                -- Images and positions are untouched.
                assert.is_true(g.image_path == nil or g.image_path:match("%.jpg$") ~= nil)
            end
            -- Upgrading again changes nothing.
            local ids = {}
            for i, g in ipairs(data.annotation_groups) do ids[i] = g.id end
            Store.upgrade(data)
            for i, g in ipairs(data.annotation_groups) do assert.equals(ids[i], g.id) end
        end)

        it("gives ids that survive a regroup", function()
            -- The same strokes, grouped again in a different order of groups.
            local data = dofile("spec/fixtures/v3_pencil_strokes.lua")
            Store.upgrade(data)
            local again = dofile("spec/fixtures/v3_pencil_strokes.lua")
            local reversed = {}
            for i = #again.annotation_groups, 1, -1 do
                table.insert(reversed, again.annotation_groups[i])
            end
            again.annotation_groups = reversed
            Store.upgrade(again)
            local ids = {}
            for _, g in ipairs(data.annotation_groups) do ids[g.id] = true end
            for _, g in ipairs(again.annotation_groups) do assert.is_true(ids[g.id]) end
        end)

    end)

    describe("sameGroup", function()

        local function group(id, n, bbox)
            local idx = {}
            for i = 1, n do idx[i] = i end
            return { id = id, stroke_indices = idx, bbox = bbox }
        end
        local box = { x0 = 1, y0 = 2, x1 = 3, y1 = 4 }

        it("needs the same id, stroke count and box", function()
            assert.is_true(Store.sameGroup(group("a", 2, box), group("a", 2, { x0 = 1, y0 = 2, x1 = 3, y1 = 4 })))
            assert.is_false(Store.sameGroup(group("a", 2, box), group("b", 2, box)))
            assert.is_false(Store.sameGroup(group("a", 2, box), group("a", 3, box)))
            assert.is_false(Store.sameGroup(group("a", 2, box), group("a", 2, { x0 = 1, y0 = 2, x1 = 3, y1 = 9 })))
            assert.is_false(Store.sameGroup(nil, group("a", 2, box)))
        end)

    end)

end)

describe("Anchor", function()

    local word = { x = 100, y = 200, w = 60, h = 40 }

    it("measures the offset in line heights", function()
        local a = Anchor.fromWord({ x0 = 140, y0 = 260, x1 = 180, y1 = 300 }, "/body/p[2]/text().4", word)
        assert.equals("/body/p[2]/text().4", a.xpointer)
        assert.equals(1.5, a.dx)
        assert.equals(2, a.dy)
    end)

    it("places the stroke again on a new layout, scaled with the font", function()
        local a = Anchor.fromWord({ x0 = 140, y0 = 260, x1 = 180, y1 = 300 }, "/x", word)
        -- The word moved and the font grew by half.
        local x, y = Anchor.place(a, { x = 300, y = 50, w = 90, h = 60 })
        assert.equals(390, x)
        assert.equals(170, y)
    end)

    it("needs a word with a height", function()
        assert.is_nil(Anchor.fromWord({ x0 = 0, y0 = 0, x1 = 1, y1 = 1 }, "/x", { x = 0, y = 0, w = 1, h = 0 }))
        assert.is_nil(Anchor.fromWord({ x0 = 0, y0 = 0, x1 = 1, y1 = 1 }, nil, word))
    end)

end)
