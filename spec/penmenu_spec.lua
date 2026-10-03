--[[--
Unit tests for the pen menu's rows (lib/penmenu): what's shown, in what
order, what's marked as chosen, and which item a tap lands on.
Run with: busted spec/penmenu_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"
local PenMenu = require("lib/penmenu")

local colors = { { name = "Black", color = 0 }, { name = "Red", color = 1 } }
local widths = { { name = "w3", width = 3 }, { name = "w5", width = 5 } }

describe("pen menu rows", function()
    it("shows tools, then colours, then widths", function()
        local rows = PenMenu.rows(colors, widths, {})
        assert.equal(3, #rows)
        assert.same({ "tool", "tool", "tool" }, { rows[1][1].kind, rows[1][2].kind, rows[1][3].kind })
        assert.same({ "pen", "highlight", "eraser" }, { rows[1][1].tool, rows[1][2].tool, rows[1][3].tool })
        assert.equal("color", rows[2][1].kind)
        assert.equal("width", rows[3][1].kind)
        assert.equal(5, rows[3][2].width_value)
    end)

    it("marks the current tool, colour and width", function()
        local rows = PenMenu.rows(colors, widths, { tool = "highlight", color_name = "Red", width = 5 })
        local function selected(row)
            local out = {}
            for _, item in ipairs(row) do if item.selected then table.insert(out, item.name or item.tool) end end
            return out
        end
        assert.same({ "highlight" }, selected(rows[1]))
        assert.same({ "Red" }, selected(rows[2]))
        assert.same({ "w5" }, selected(rows[3]))
    end)

    it("leaves out rows with nothing in them", function()
        local rows = PenMenu.rows(nil, widths, {})
        assert.equal(2, #rows)
        assert.equal("width", rows[2][1].kind)
    end)
end)

describe("pen menu hit test", function()
    it("finds the item under a point, and nothing between items", function()
        local rows = PenMenu.rows(colors, widths, {})
        rows[1][2].box = { x = 100, y = 10, w = 80, h = 30 }
        rows[3][1].box = { x = 20, y = 90, w = 30, h = 30 }
        assert.equal("highlight", PenMenu.hit(rows, 120, 20).tool)
        assert.equal(3, PenMenu.hit(rows, 25, 100).width_value)
        assert.is_nil(PenMenu.hit(rows, 60, 100))
        assert.is_nil(PenMenu.hit(rows, 180, 20))
    end)
end)
