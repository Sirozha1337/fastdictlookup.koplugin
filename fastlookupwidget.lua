--[[--
Floating widget that shows a short dictionary definition preview
at the bottom or top of the screen.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")

local FastLookupWidget = InputContainer:extend{
    word = nil,
    definition = nil,
    dict_name = nil,
    -- "bottom" or "top"
    position = "bottom",
    -- Set by caller to avoid obscuring the highlighted word
    word_box_bottom_y = nil,
    -- Mark as toast so we never block event propagation to widgets below us
    toast = true,
}

function FastLookupWidget:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = Size.padding.large
    local margin = Size.margin.default
    local max_width = screen_w - 4 * (padding + margin)
    local max_height = math.floor(screen_h / 6)
    local font_size = 18

    -- Title: the looked-up word in bold
    local title_widget = TextWidget:new{
        text = self.word or "",
        face = Font:getFace("smalltfont", font_size),
        bold = true,
        max_width = max_width,
    }

    -- Definition text (first few lines)
    local def_text = self.definition or _("No definition found.")
    local definition_widget = TextBoxWidget:new{
        text = def_text,
        face = Font:getFace("smalltfont", font_size),
        width = max_width,
        height = max_height,
        height_overflow_show_ellipsis = true,
    }

    -- Dict name (subtle, at the bottom)
    local dict_label = self.dict_name and ("— " .. self.dict_name) or ""
    local dict_widget = TextWidget:new{
        text = dict_label,
        face = Font:getFace("smalltfont", font_size - 2),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = max_width,
    }

    local content = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            HorizontalSpan:new{ width = 0 },
            title_widget,
        },
        VerticalSpan:new{ width = Size.span.vertical_default },
        definition_widget,
        VerticalSpan:new{ width = Size.span.vertical_default },
        dict_widget,
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        radius = Size.radius.window,
        margin = margin,
        padding = padding,
        content,
    }

    local frame_h = self.frame:getSize().h

    -- Decide position: if the word is in the bottom half, show at top; otherwise bottom.
    if self.position == "top" or (self.word_box_bottom_y and self.word_box_bottom_y > screen_h / 2) then
        -- Show at top
        self[1] = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = frame_h },
                self.frame,
            },
        }
    else
        -- Show at bottom
        self[1] = BottomContainer:new{
            dimen = Screen:getSize(),
            CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = frame_h },
                self.frame,
            },
        }
    end
end

function FastLookupWidget:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
end

function FastLookupWidget:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "partial", self.frame.dimen or self[1].dimen
    end)
end

function FastLookupWidget:dismiss()
    UIManager:close(self)
end

return FastLookupWidget
