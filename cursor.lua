--[[--
Cursor overlay and word-by-word navigation for CRE documents.

Manages the visual cursor, word finding on pages, and directional
movement (left/right within a line, up/down across lines).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Screen = Device.screen
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local logger = require("logger")

--- Maximum number of words to scan when searching for the last word on a page.
local MAX_WORD_SCAN_ITERATIONS = 2000

--- Multipliers of line height used to probe for the next/previous line.
local VERTICAL_PROBE_MULTIPLIERS = { 1, 1.5, 2, 2.5, 3 }

local CursorNavigator = {}
CursorNavigator.__index = CursorNavigator

function CursorNavigator:new(ui)
    local o = setmetatable({}, self)
    o.ui = ui
    o.cursor_active = false
    o.current_word_xp = nil
    o.current_word_end_xp = nil
    o._turning_page_direction = nil

    -- Overlay widget registered as a view module for drawing on the page.
    -- `highlighting` flag controls whether word rects are inverted (selection)
    -- or underlined (normal cursor).
    o._overlay = {
        visible = false,
        cursor_rect = nil,  -- {x, y, h} vertical cursor line
        word_rects = nil,   -- array of {x, y, w, h}
        highlighting = false,
        paintTo = function(overlay, bb)
            if not overlay.visible then return end
            if overlay.word_rects then
                for _, r in ipairs(overlay.word_rects) do
                    if overlay.highlighting then
                        bb:invertRect(r.x, r.y, r.w, r.h)
                    else
                        bb:paintRect(r.x, r.y + r.h - Size.border.thick,
                            r.w, Size.border.thick, Blitbuffer.COLOR_DARK_GRAY)
                    end
                end
            end
            if overlay.cursor_rect then
                local r = overlay.cursor_rect
                bb:paintRect(r.x, r.y, Screen:scaleBySize(2), r.h,
                    Blitbuffer.COLOR_BLACK)
            end
        end,
    }

    if ui.view then
        ui.view:registerViewModule("typewriter_cursor", o._overlay)
    end

    return o
end

-- Document type check -------------------------------------------------------

--- Only CRE (EPUB/FB2) documents support xpointer-based word navigation.
function CursorNavigator:isCREDocument()
    return self.ui.rolling ~= nil
end

-- Screen queries -------------------------------------------------------------

function CursorNavigator:getVisibleHeight()
    if self.ui.view and self.ui.view.visible_area then
        return self.ui.view.visible_area.h
    end
    return Screen:getHeight()
end

function CursorNavigator:isXPointerOnScreen(xp)
    if not xp then return false end
    return self.ui.document:isXPointerInCurrentPage(xp)
end

-- Word finding ---------------------------------------------------------------

function CursorNavigator:findFirstWordOnPage()
    local doc = self.ui.document
    local top_xp = doc:getXPointer()
    logger.dbg("CursorNavigator: findFirstWordOnPage, top_xp=", top_xp)
    if not top_xp then return nil end

    -- Step one char before page start so getNextVisibleWordStart
    -- will find a word that begins exactly at the page top.
    local before = doc:getPrevVisibleChar(top_xp)
    local word_xp
    if before then
        word_xp = doc:getNextVisibleWordStart(before)
    end
    if word_xp and self:isXPointerOnScreen(word_xp) then
        return word_xp
    end

    -- Fallback: search forward from the page-start xpointer.
    word_xp = doc:getNextVisibleWordStart(top_xp)
    if word_xp and self:isXPointerOnScreen(word_xp) then
        return word_xp
    end
    return nil
end

function CursorNavigator:findLastWordOnPage()
    logger.dbg("CursorNavigator: findLastWordOnPage")
    local doc = self.ui.document

    -- Walk forward from the first visible word to reliably find the last one.
    local cur_xp = self:findFirstWordOnPage()
    if not cur_xp then return nil end

    local last_xp = cur_xp
    for _ = 1, MAX_WORD_SCAN_ITERATIONS do
        local next_xp = doc:getNextVisibleWordStart(cur_xp)
        if not next_xp then break end
        -- compareXPointers returns 1 if xp2 is after xp1; stop if no forward progress
        if doc:compareXPointers(cur_xp, next_xp) ~= 1 then break end
        if not self:isXPointerOnScreen(next_xp) then break end
        last_xp = next_xp
        cur_xp = next_xp
    end
    logger.dbg("CursorNavigator: findLastWordOnPage, last_xp=", last_xp)
    return last_xp
end

-- Overlay geometry -----------------------------------------------------------

--- Calculate the bounding box of the cursor overlay.
-- Used to issue targeted dirty-region redraws instead of full-screen updates.
-- @return Geom or nil
function CursorNavigator:getOverlayGeom()
    if not self._overlay or not self._overlay.visible then return nil end
    local min_x, min_y, max_x, max_y

    local function expandBounds(r)
        if not r then return end
        if not min_x or r.x < min_x then min_x = r.x end
        if not min_y or r.y < min_y then min_y = r.y end
        if not max_x or r.x + r.w > max_x then max_x = r.x + r.w end
        if not max_y or r.y + r.h > max_y then max_y = r.y + r.h end
    end

    if self._overlay.word_rects then
        for _, r in ipairs(self._overlay.word_rects) do
            expandBounds(r)
        end
    end
    if self._overlay.cursor_rect then
        expandBounds({
            x = self._overlay.cursor_rect.x,
            y = self._overlay.cursor_rect.y,
            w = Screen:scaleBySize(2),
            h = self._overlay.cursor_rect.h,
        })
    end

    if min_x then
        local padding = Size.border.thick or Screen:scaleBySize(2)
        return Geom:new{
            x = math.max(0, min_x - padding),
            y = math.max(0, min_y - padding),
            w = (max_x - min_x) + padding * 2,
            h = (max_y - min_y) + padding * 2,
        }
    end
    return nil
end

--- Hide the overlay and issue a dirty-region redraw.
function CursorNavigator:hideOverlay(old_geom)
    self._overlay.visible = false
    self._overlay.cursor_rect = nil
    self._overlay.word_rects = nil
    if old_geom then
        UIManager:setDirty(self.ui, "fast", old_geom)
    end
end

--- Update overlay rects for the current word (or cursor-only fallback).
-- @param word_info table|nil  Word info from getWordFromPosition.
-- @param sboxes table|nil     Screen boxes for highlighting range.
-- @param old_geom Geom|nil    Previous overlay bounding box for dirty tracking.
-- @param is_highlighting bool Whether we're in selection mode (invert vs underline).
function CursorNavigator:updateOverlay(word_info, sboxes, old_geom, is_highlighting)
    self._overlay.visible = true
    self._overlay.highlighting = is_highlighting or false

    if not word_info or not word_info.sbox then
        -- Cursor-only: show a thin vertical line at the screen position
        local doc = self.ui.document
        local screen_y, screen_x = doc:getScreenPositionFromXPointer(self.current_word_xp)
        local h = Screen:scaleBySize(20)
        self._overlay.cursor_rect = { x = screen_x or 0, y = screen_y or 0, h = h }
        self._overlay.word_rects = nil
    else
        local first_rect = sboxes and sboxes[1] or word_info.sbox
        self._overlay.cursor_rect = { x = first_rect.x, y = first_rect.y, h = first_rect.h }
        self._overlay.word_rects = sboxes
    end

    local new_geom = self:getOverlayGeom()
    if old_geom then UIManager:setDirty(self.ui, "fast", old_geom) end
    if new_geom then UIManager:setDirty(self.ui, "fast", new_geom) end
end

-- Activation / deactivation --------------------------------------------------

function CursorNavigator:activate(from_top)
    logger.dbg("CursorNavigator: activate, from_top=", from_top)
    if not self:isCREDocument() then
        logger.dbg("CursorNavigator: not a CRE document, skipping")
        return false
    end

    local doc = self.ui.document
    local word_xp = from_top
        and self:findFirstWordOnPage()
        or  self:findLastWordOnPage()
    if not word_xp then return false end

    self.current_word_xp = word_xp
    self.current_word_end_xp = doc:getNextVisibleWordEnd(word_xp)
    self.cursor_active = true
    logger.dbg("CursorNavigator: activated, word_xp=", word_xp)
    return true
end

function CursorNavigator:deactivate()
    if not self.cursor_active then return end
    logger.dbg("CursorNavigator: deactivate")
    local old_geom = self:getOverlayGeom()
    self.cursor_active = false
    self.current_word_xp = nil
    self.current_word_end_xp = nil
    self._turning_page_direction = nil
    self:hideOverlay(old_geom)
    if not old_geom then
        UIManager:setDirty(self.ui, "ui")
    end
end

-- Navigation -----------------------------------------------------------------

--- Move cursor to the next/previous word on the same line.
-- @param direction string "left" or "right"
-- @return string|nil "moved" if successful, nil if off-screen/unavailable
function CursorNavigator:moveToWordOnSameLine(direction)
    if not self.cursor_active or not self.current_word_xp then return nil end
    local doc = self.ui.document
    local next_xp

    if direction == "right" then
        next_xp = doc:getNextVisibleWordStart(self.current_word_xp)
        -- If stuck at same position, try advancing from word end
        if next_xp and self.current_word_end_xp
           and doc:compareXPointers(self.current_word_xp, next_xp) ~= 1 then
            logger.dbg("CursorNavigator: moveToWordOnSameLine stuck, trying from word end")
            next_xp = doc:getNextVisibleWordStart(self.current_word_end_xp)
        end
    elseif direction == "left" then
        next_xp = doc:getPrevVisibleWordStart(self.current_word_xp)
    end

    if not next_xp or not self:isXPointerOnScreen(next_xp) then
        return nil -- caller decides whether to page-turn or deactivate
    end

    logger.dbg("CursorNavigator: moved to", next_xp, "word=", doc:getTextFromXPointer(next_xp))
    self.current_word_xp = next_xp
    self.current_word_end_xp = doc:getNextVisibleWordEnd(next_xp)
    return "moved"
end

--- Move cursor to a word on the next/previous line.
-- @param direction string "up" or "down"
-- @return string|nil "moved" if successful, nil if no next-line word found
function CursorNavigator:moveToWordOnNextLine(direction)
    if not self.cursor_active or not self.current_word_xp then return nil end
    local doc = self.ui.document

    local screen_y, screen_x = doc:getScreenPositionFromXPointer(self.current_word_xp)
    if not screen_y or not screen_x then return nil end

    local cur_info = doc:getWordFromPosition({x = screen_x, y = screen_y}, true)
    if not cur_info or not cur_info.sbox then return nil end

    local first_box = cur_info.sbox
    if cur_info.pos0 and cur_info.pos1 and doc.getScreenBoxesFromPositions then
        local sboxes = doc:getScreenBoxesFromPositions(cur_info.pos0, cur_info.pos1, true)
        if sboxes and #sboxes > 0 then
            first_box = sboxes[1]
        end
    end
    local cx = first_box.x + math.floor(first_box.w / 2)

    -- Try progressively larger steps until the probe lands on a
    -- word whose sbox.y is clearly above/below the current line.
    local next_info
    for _, mult in ipairs(VERTICAL_PROBE_MULTIPLIERS) do
        local dy = math.floor(first_box.h * mult)
        local next_y = direction == "up"
            and first_box.y - dy
            or  first_box.y + dy
        local probe = doc:getWordFromPosition({x = cx, y = next_y}, true)
        if probe and probe.sbox and probe.pos0 and
           (direction == "down" and probe.sbox.y > first_box.y or
            direction == "up" and probe.sbox.y < first_box.y) and
           self:isXPointerOnScreen(probe.pos0) then
            next_info = probe
            break
        end
    end

    if not next_info then
        return nil -- caller decides whether to page-turn or deactivate
    end

    logger.dbg("CursorNavigator: moved to next line", next_info.pos0, "word=", next_info.word)
    self.current_word_xp = next_info.pos0
    self.current_word_end_xp = doc:getNextVisibleWordEnd(next_info.pos0)
    return "moved"
end

--- Turn to next/previous page during highlighting.
-- @param direction string Movement direction ("left"/"right"/"up"/"down")
-- @return boolean true if page turn was initiated
function CursorNavigator:goToNextPage(direction)
    local doc = self.ui.document
    local cur_page = doc:getCurrentPage()
    local target_page
    if direction == "right" or direction == "down" then
        target_page = doc:getNextPage(cur_page)
    else
        target_page = doc:getPrevPage(cur_page)
    end

    if target_page and target_page ~= 0 and target_page ~= cur_page then
        logger.dbg("CursorNavigator: turning to page", target_page)
        self._turning_page_direction = direction
        self.ui:handleEvent(Event:new("GotoPage", target_page))
        return true
    end
    return false
end

--- Recover cursor position after a page turn during highlighting.
-- @return boolean true if cursor was recovered
function CursorNavigator:recoverAfterPageTurn()
    if not self._turning_page_direction then return false end
    local direction = self._turning_page_direction
    self._turning_page_direction = nil

    local word_xp
    if direction == "right" or direction == "down" then
        word_xp = self:findFirstWordOnPage()
    else
        word_xp = self:findLastWordOnPage()
    end

    if word_xp then
        self.current_word_xp = word_xp
        self.current_word_end_xp = self.ui.document:getNextVisibleWordEnd(word_xp)
        return true
    end
    return false
end

--- Get word info at the current cursor position.
-- @return word_info, screen_x, screen_y (all nil if unavailable)
function CursorNavigator:getWordInfoAtCursor()
    if not self.current_word_xp then return nil, nil, nil end
    local doc = self.ui.document
    local screen_y, screen_x = doc:getScreenPositionFromXPointer(self.current_word_xp)
    if not screen_y or not screen_x then return nil, nil, nil end
    local word_info = doc:getWordFromPosition({x = screen_x, y = screen_y}, true)
    return word_info, screen_x, screen_y
end

return CursorNavigator
