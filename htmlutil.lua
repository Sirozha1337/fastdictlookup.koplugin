--[[--
Utility for stripping HTML tags and decoding entities to plain text.
Shared by footnote rendering and dictionary definition previews.
]]

local HtmlUtil = {}

--- Strip HTML tags, decode entities, and normalize whitespace.
-- @param html string The HTML content.
-- @return string Plain text.
function HtmlUtil.stripHtml(html)
    local text = html
        :gsub("<div[^>]*>", "\n")
        :gsub("</div>", "\n")
        :gsub("<[bB][rR]%s*/?>", "\n")
        :gsub("</?[pP]%s*>", "\n")
        :gsub("<[^>]+>", " ")

    -- Decode common HTML entities
    text = text:gsub("&amp;",  "&")
               :gsub("&lt;",   "<")
               :gsub("&gt;",   ">")
               :gsub("&quot;", '"')
               :gsub("&nbsp;", " ")
               :gsub("&#(%d+);", function(n)
                   local cp = tonumber(n)
                   if cp < 128 then
                       return string.char(cp)
                   elseif cp < 2048 then
                       return string.char(
                           0xC0 + math.floor(cp / 64),
                           0x80 + cp % 64)
                   else
                       return string.char(
                           0xE0 + math.floor(cp / 4096),
                           0x80 + math.floor(cp / 64) % 64,
                           0x80 + cp % 64)
                   end
               end)

    -- Normalize whitespace
    text = text:gsub(" +", " ")
               :gsub("\n ", "\n")
               :gsub(" \n", "\n")
               :gsub("\n+", "\n")
               :gsub("^%s+", "")
               :gsub("%s+$", "")

    return text
end

return HtmlUtil
