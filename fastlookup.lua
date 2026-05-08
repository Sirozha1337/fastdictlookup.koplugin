--[[--
Fast dictionary lookup and footnote preview controller.

Manages the StarDict dictionary instance, word lookups, footnote
detection, and the floating preview widget lifecycle.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local HtmlUtil = require("htmlutil")

-- Footnote detection flags (used by cre.cpp in KOReader):
-- 0x0001: Prefer interpreting as footnote when uncertain (fallback to true).
-- 0x0002: Trust the source xpointer (allows checking element attributes/styles).
-- 0x0004: Trust role= and epub:type= attributes.
-- 0x0008: Accept classic FB2 footnotes.
-- 0x0010: Target must have an anchor (#id), not just a link to an HTML file.
-- 0x0040: Target must not be a target of a TOC entry.
-- 0x0100: Source link must not be empty content.
-- 0x0200: Source node vertical alignment is sub/sup/top/bottom.
-- 0x0400: Source node readable text is a number (<=3 digits).
-- 0x0800: Source node readable text is 1-2 letters + numbers (e.g. A1).
-- 0x1000: Target must not contain, or be contained in, H1..H6 headers.
-- 0x4000: Try to extend the footnote boundary after the target to capture all text.
-- 0x8000: Limit the extended target readable text to `max_text_size`.
local FOOTNOTE_FLAGS = 0x0001 + 0x0002 + 0x0004 + 0x0008 + 0x0010
                     + 0x0040 + 0x0100 + 0x0200 + 0x0400 + 0x0800
                     + 0x1000 + 0x4000 + 0x8000

--- Maximum number of characters to extract from a footnote target.
local MAX_FOOTNOTE_TEXT_SIZE = 10000

--- HTML-to-text flags passed to getHTMLFromXPointer(s) for footnotes.
local FOOTNOTE_HTML_FLAGS = 0x1001

local FastLookupController = {}
FastLookupController.__index = FastLookupController

function FastLookupController:new(ui)
    local o = setmetatable({}, self)
    o.ui = ui
    o.fast_lookup_enabled = false
    o.fast_lookup_dict_ifo = nil
    o._dict_instance = nil
    o._fast_lookup_widget = nil
    o._dict_select_dialog = nil
    return o
end

--- Return the StarDict data directory path.
function FastLookupController:getDataDir()
    return G_defaults:readSetting("STARDICT_DATA_DIR")
        or os.getenv("STARDICT_DATA_DIR")
        or DataStorage:getDataDir() .. "/data/dict"
end

--- Open (or reopen) the selected dictionary for fast lookups.
function FastLookupController:openDict()
    self:closeDict()
    if not self.fast_lookup_dict_ifo then return end

    local StarDictLookup = require("stardictlookup")
    local meta = StarDictLookup.parseIfo(self.fast_lookup_dict_ifo)
    if not meta then
        logger.warn("FastLookup: failed to parse ifo:", self.fast_lookup_dict_ifo)
        return
    end
    local has_dict, dict_path = StarDictLookup.hasUncompressedDict(self.fast_lookup_dict_ifo)
    if not has_dict then
        logger.warn("FastLookup: no uncompressed .dict for:", self.fast_lookup_dict_ifo)
        return
    end
    meta.dict_path = dict_path
    meta.idx_path = self.fast_lookup_dict_ifo:gsub("%.ifo$", ".idx")

    local instance, err = StarDictLookup.open(meta)
    if not instance then
        logger.warn("FastLookup: failed to open dict:", err)
        return
    end
    self._dict_instance = instance
    logger.dbg("FastLookup: dict opened:", instance.bookname, "#entries:", instance.entry_count)
end

--- Close the dictionary and release resources.
function FastLookupController:closeDict()
    if self._dict_instance then
        self._dict_instance:close()
        self._dict_instance = nil
    end
end

--- Show a dialog for selecting the active dictionary.
function FastLookupController:showDictSelectionDialog(touchmenu_instance)
    local StarDictLookup = require("stardictlookup")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")

    local data_dir = self:getDataDir()
    local dicts = StarDictLookup.getAvailableDicts(data_dir)

    if #dicts == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No uncompressed StarDict dictionaries found.\nOnly dictionaries with .dict files (not .dict.dz) are supported."),
        })
        return
    end

    local buttons = {}
    for _, dict in ipairs(dicts) do
        local is_selected = self.fast_lookup_dict_ifo == dict.ifo_path
        local label = dict.bookname
        if is_selected then
            label = "★ " .. label
        end
        if dict.wordcount then
            label = label .. " (" .. dict.wordcount .. ")"
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                self.fast_lookup_dict_ifo = dict.ifo_path
                if self.ui.doc_settings then
                    self.ui.doc_settings:saveSetting("typewriter_fast_lookup_dict", dict.ifo_path)
                end
                if self.fast_lookup_enabled then
                    self:openDict()
                end
                UIManager:close(self._dict_select_dialog)
                self._dict_select_dialog = nil
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }})
    end

    self._dict_select_dialog = ButtonDialog:new{
        title = _("Select dictionary for fast lookup"),
        buttons = buttons,
    }
    UIManager:show(self._dict_select_dialog)
end

--- Dismiss the floating lookup widget if visible.
function FastLookupController:dismissWidget()
    if self._fast_lookup_widget then
        UIManager:close(self._fast_lookup_widget)
        self._fast_lookup_widget = nil
    end
end

--- Show the floating lookup widget with word and definition.
function FastLookupController:showWidget(word, definition, dict_name, word_box_bottom_y)
    self:dismissWidget()

    local FastLookupWidget = require("fastlookupwidget")
    self._fast_lookup_widget = FastLookupWidget:new{
        word = word,
        definition = definition,
        dict_name = dict_name,
        word_box_bottom_y = word_box_bottom_y,
    }
    UIManager:show(self._fast_lookup_widget)
end

--- Look up a word in the dictionary (pure query, no side effects).
-- @param word string The word to look up.
-- @return cleaned_word, definition (both nil if not found)
function FastLookupController:lookupWord(word)
    if not word then return nil, nil end

    -- Clean the word: trim whitespace and punctuation
    word = word:gsub("^[%s%p]+", ""):gsub("[%s%p]+$", "")
    if word == "" then return nil, nil end

    local entry = self._dict_instance:lookup(word)
    if not entry then return nil, nil end

    return word, self._dict_instance:getDefinitionPreview(entry)
end

--- Extract footnote text for a link at the given xpointers.
-- @param link_xpointer string The link target xpointer.
-- @param a_xpointer string The anchor element xpointer.
-- @return string|nil Plain text of the footnote, or nil.
function FastLookupController:getFootnoteText(link_xpointer, a_xpointer)
    if not link_xpointer or link_xpointer == ""
       or not a_xpointer or a_xpointer == "" then
        return nil
    end

    local doc = self.ui.document
    local is_footnote, _reason, _extStopReason, extStartXP, extEndXP =
        doc:isLinkToFootnote(a_xpointer, link_xpointer, FOOTNOTE_FLAGS, MAX_FOOTNOTE_TEXT_SIZE)

    if not is_footnote then return nil end

    local html
    if extStartXP and extEndXP then
        html = doc:getHTMLFromXPointers(extStartXP, extEndXP, FOOTNOTE_HTML_FLAGS)
    else
        html = doc:getHTMLFromXPointer(link_xpointer, FOOTNOTE_HTML_FLAGS, true)
    end

    if not html then return nil end

    return HtmlUtil.stripHtml(html)
end

return FastLookupController
