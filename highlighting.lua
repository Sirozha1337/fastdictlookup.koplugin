--[[--
Highlighting and text selection controller.

Manages highlight range state, screen-box computation for the
highlighted region, and context menu interactions.
]]

local Geom = require("ui/geometry")
local logger = require("logger")
local time = require("ui/time")

local HighlightController = {}
HighlightController.__index = HighlightController

function HighlightController:new(ui)
    local o = setmetatable({}, self)
    o.ui = ui
    o.highlighting_active = false
    o.highlight_start_xp = nil
    return o
end

--- Reset all highlight state.
function HighlightController:reset()
    self.highlighting_active = false
    self.highlight_start_xp = nil
end

--- Start highlighting from the given xpointer.
function HighlightController:startAt(xp)
    self.highlighting_active = true
    self.highlight_start_xp = xp
end

--- Returns (start_xp, end_xp) normalized so start comes before end
-- in document order.
-- @param current_word_xp string  Current cursor word xpointer.
-- @param current_word_end_xp string  Current cursor word end xpointer.
-- @return start_xp, end_xp
function HighlightController:getHighlightRange(current_word_xp, current_word_end_xp)
    local doc = self.ui.document
    local xp_start = self.highlight_start_xp
    local xp_end = current_word_end_xp

    -- compareXPointers(xp1, xp2) returns -1 if xp2 < xp1
    if doc:compareXPointers(self.highlight_start_xp, current_word_xp) == -1 then
        xp_start = current_word_xp
        xp_end = doc:getNextVisibleWordEnd(self.highlight_start_xp)
    end

    return xp_start, xp_end
end

--- Compute screen boxes for the highlighted range (or single word).
-- @param word_info table  From getWordFromPosition.
-- @param current_word_xp string  Current cursor word xpointer.
-- @param current_word_end_xp string  Current cursor word end xpointer.
-- @return table Array of screen box rects.
function HighlightController:getWordScreenBoxes(word_info, current_word_xp, current_word_end_xp)
    local doc = self.ui.document
    local xp_start = word_info.pos0
    local xp_end = word_info.pos1

    if self.highlighting_active and self.highlight_start_xp then
        xp_start, xp_end = self:getHighlightRange(current_word_xp, current_word_end_xp)
    end

    local sboxes
    if xp_start and xp_end then
        sboxes = doc:getScreenBoxesFromPositions(xp_start, xp_end, true)
    end

    if not sboxes or #sboxes == 0 then
        sboxes = { word_info.sbox }
    end

    return sboxes
end

--- Open the KOReader highlight/selection context menu for the current range.
-- @param cursor CursorNavigator  The cursor module (for current_word_xp/end).
-- @return boolean true if the menu was opened
function HighlightController:openSelectionContextMenu(cursor)
    if not cursor.cursor_active or not cursor.current_word_xp then
        return false
    end
    if not self.highlighting_active or not self.highlight_start_xp then
        return false
    end
    if cursor.current_word_xp == self.highlight_start_xp then
        return false
    end

    local doc = self.ui.document
    local xp_start, xp_end = self:getHighlightRange(
        cursor.current_word_xp,
        doc:getNextVisibleWordEnd(cursor.current_word_xp)
    )
    logger.dbg("HighlightController: openSelectionContextMenu", xp_start, xp_end)

    local selected_text_string = doc:getTextFromXPointers(xp_start, xp_end, true)
    if not selected_text_string then return false end

    local line_boxes = doc:getScreenBoxesFromPositions(xp_start, xp_end, true)
    self.ui.highlight.selected_text = {
        text = selected_text_string,
        pos0 = xp_start,
        pos1 = xp_end,
        sboxes = line_boxes,
    }
    self.ui.highlight.is_word_selection = false
    self.ui.highlight.hold_pos = { x = 0, y = 0, page = doc:getCurrentPage() }
    self.ui.highlight.holdpan_pos = { x = 0, y = 0, page = doc:getCurrentPage() }
    self.ui.highlight:onShowHighlightMenu()

    return true
end

--- Open the default word context menu (hold gesture simulation).
-- @param cursor CursorNavigator  The cursor module.
function HighlightController:openWordContextMenu(cursor)
    if not cursor.cursor_active or not cursor.current_word_xp then return end
    logger.dbg("HighlightController: openWordContextMenu")

    local doc = self.ui.document
    local screen_y, screen_x = doc:getScreenPositionFromXPointer(cursor.current_word_xp)
    if not screen_y or not screen_x then return end

    local word_info = doc:getWordFromPosition({x = screen_x, y = screen_y}, true)
    if not word_info or not word_info.sbox then return end
    logger.dbg("HighlightController: context menu for word:", word_info.word)

    local pos = Geom:new{x = screen_x, y = screen_y, w = 0, h = 0}

    -- Simulate hold + release to trigger the default word context menu
    self.ui.highlight:onHold(nil, {
        ges = "hold", pos = pos, time = time.realtime(),
    })
    self.ui.highlight:onHoldRelease(nil, {
        ges = "hold_release", pos = pos, time = time.realtime(),
    })
end

return HighlightController
