--[[--
Fast StarDict dictionary reader using LuaJIT FFI and mmap.

Supports only uncompressed dictionaries (.dict, not .dict.dz).
Loads the .idx file via mmap and performs binary search for O(log n) lookups.
]]

local ffi = require("ffi")
local C = ffi.C
local bit = require("bit")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

require("ffi/posix_h")

-- MAP_PRIVATE is not in posix_h.lua; define as Lua constant (value 2 on Linux)
local MAP_PRIVATE = 2

local StarDictLookup = {}

--- Parse a .ifo file and return metadata table or nil on error.
function StarDictLookup.parseIfo(ifo_path)
    local f = io.open(ifo_path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()

    local bookname = content:match("\nbookname=(.-)\r?\n")
    if not bookname then return nil end

    local wordcount = content:match("\nwordcount=(%d+)")
    local idxfilesize = content:match("\nidxfilesize=(%d+)")
    local sametypesequence = content:match("\nsametypesequence=(%a+)")

    return {
        bookname = bookname,
        wordcount = wordcount and tonumber(wordcount),
        idxfilesize = idxfilesize and tonumber(idxfilesize),
        sametypesequence = sametypesequence,
        ifo_path = ifo_path,
    }
end

--- Check if a dictionary has an uncompressed .dict file (not .dict.dz).
function StarDictLookup.hasUncompressedDict(ifo_path)
    local base = ifo_path:gsub("%.ifo$", "")
    local dict_path = base .. ".dict"
    local dz_path = base .. ".dict.dz"

    local dict_exists = lfs.attributes(dict_path, "mode") == "file"
    local dz_exists = lfs.attributes(dz_path, "mode") == "file"

    return dict_exists and not dz_exists, dict_path
end

--- Scan directories for eligible dictionaries (uncompressed .dict only).
-- @param data_dir string The base dictionary directory.
-- @return table Array of {ifo_path, dict_path, bookname, ...} tables.
function StarDictLookup.getAvailableDicts(data_dir)
    local results = {}

    local function scanDir(path)
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then return end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and name ~= "res" then
                local fullpath = path .. "/" .. name
                local attrs = lfs.attributes(fullpath)
                if attrs then
                    if attrs.mode == "directory" then
                        scanDir(fullpath)
                    elseif fullpath:match("%.ifo$") then
                        local has_dict, dict_path = StarDictLookup.hasUncompressedDict(fullpath)
                        if has_dict then
                            local meta = StarDictLookup.parseIfo(fullpath)
                            if meta then
                                meta.dict_path = dict_path
                                meta.idx_path = fullpath:gsub("%.ifo$", ".idx")
                                table.insert(results, meta)
                            end
                        end
                    end
                end
            end
        end
    end

    scanDir(data_dir)

    -- Also scan data_dir_ext
    local ext_dir = data_dir .. "_ext"
    if lfs.attributes(ext_dir, "mode") == "directory" then
        scanDir(ext_dir)
    end

    table.sort(results, function(a, b) return a.bookname < b.bookname end)
    return results
end


--[[--
Opened dictionary instance with mmap'd index and open dict file handle.
]]
local DictInstance = {}
DictInstance.__index = DictInstance

--- Open a dictionary for fast lookups.
-- @param meta table The metadata table from getAvailableDicts.
-- @return DictInstance or nil, error_string
function StarDictLookup.open(meta)
    local self = setmetatable({}, DictInstance)
    self.meta = meta
    self.bookname = meta.bookname
    self.sametypesequence = meta.sametypesequence

    -- Get idx file size
    local idx_attrs = lfs.attributes(meta.idx_path)
    if not idx_attrs or idx_attrs.mode ~= "file" then
        return nil, "Index file not found: " .. meta.idx_path
    end
    self.idx_size = idx_attrs.size

    -- Open idx file and mmap it
    local idx_fd = C.open(meta.idx_path, C.O_RDONLY)
    if idx_fd < 0 then
        return nil, "Failed to open index file"
    end

    local idx_data = C.mmap(nil, self.idx_size, C.PROT_READ, MAP_PRIVATE, idx_fd, 0)
    C.close(idx_fd)

    if tonumber(ffi.cast("intptr_t", idx_data)) == C.MAP_FAILED then
        return nil, "Failed to mmap index file"
    end

    self.idx_data = ffi.cast("const uint8_t*", idx_data)
    self.idx_ptr = idx_data -- keep original for munmap

    -- Build a compact offset table: only store the byte position of each
    -- entry in the mmap'd data as a uint32_t.  This avoids creating a Lua
    -- table + strings per entry which OOMs on low-RAM devices (Kindle).
    -- StarDict .idx format per entry:
    --   null-terminated word string
    --   4-byte big-endian offset into .dict
    --   4-byte big-endian size of definition in .dict
    -- The index is already sorted and lowercase, so no post-processing needed.
    local data = self.idx_data
    local size = self.idx_size

    -- First pass: count entries
    local count = 0
    local scan_pos = 0
    while scan_pos < size do
        while scan_pos < size and data[scan_pos] ~= 0 do scan_pos = scan_pos + 1 end
        if scan_pos >= size then break end
        scan_pos = scan_pos + 1 -- skip null
        if scan_pos + 8 > size then break end
        scan_pos = scan_pos + 8
        count = count + 1
    end

    -- Allocate compact C array (~4 bytes per entry, no GC pressure)
    self.entry_count = count
    self.entry_offsets = ffi.new("uint32_t[?]", count)

    -- Second pass: record byte offsets
    scan_pos = 0
    local idx = 0
    while scan_pos < size and idx < count do
        self.entry_offsets[idx] = scan_pos
        idx = idx + 1
        while scan_pos < size and data[scan_pos] ~= 0 do scan_pos = scan_pos + 1 end
        if scan_pos >= size then break end
        scan_pos = scan_pos + 1
        if scan_pos + 8 > size then break end
        scan_pos = scan_pos + 8
    end

    logger.dbg("StarDictLookup: indexed", count, "entries from", meta.bookname)

    -- Open .dict file handle for reading definitions
    self.dict_fh = io.open(meta.dict_path, "rb")
    if not self.dict_fh then
        self:close()
        return nil, "Failed to open dict file: " .. meta.dict_path
    end

    return self
end

--- Binary search for a word (case-insensitive).
-- Reads words directly from the mmap'd index on the fly — only ~17
-- temporary strings for a 400K-entry dictionary.
-- @param word string The word to look up.
-- @return table {word, offset, size} or nil.
function DictInstance:lookup(word)
    if not word or word == "" then return nil end

    local target = word:lower()
    local data = self.idx_data
    local lo, hi = 0, self.entry_count - 1

    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local entry_pos = self.entry_offsets[mid]

        -- Read null-terminated word directly from mmap
        local word_end = entry_pos
        while data[word_end] ~= 0 do word_end = word_end + 1 end
        local entry_word = ffi.string(data + entry_pos, word_end - entry_pos)

        if entry_word == target then
            -- Read the 8 metadata bytes after the null terminator
            local mp = word_end + 1
            local offset = bit.bor(
                bit.lshift(data[mp], 24),
                bit.lshift(data[mp + 1], 16),
                bit.lshift(data[mp + 2], 8),
                data[mp + 3]
            )
            local data_size = bit.bor(
                bit.lshift(data[mp + 4], 24),
                bit.lshift(data[mp + 5], 16),
                bit.lshift(data[mp + 6], 8),
                data[mp + 7]
            )
            return { word = entry_word, offset = offset, size = data_size }
        elseif entry_word < target then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    return nil
end

--- Read the definition for an index entry.
-- @param entry table From lookup().
-- @return string The raw definition text, or nil.
function DictInstance:getDefinition(entry)
    if not entry or not self.dict_fh then return nil end

    self.dict_fh:seek("set", entry.offset)
    local data = self.dict_fh:read(entry.size)
    if not data then return nil end

    -- If sametypesequence is set, the data doesn't have per-entry type markers.
    -- For type 'm' (plain text) or 'h' (html), the data is just the text.
    -- For others, first byte might be a type marker.
    if self.sametypesequence then
        return data
    end

    -- Without sametypesequence, each field starts with a type byte.
    -- We look for the first text-type field.
    local pos = 1
    while pos <= #data do
        local type_char = data:sub(pos, pos)
        pos = pos + 1
        if type_char == "m" or type_char == "l" or type_char == "g" or type_char == "t" or type_char == "h" then
            -- Null-terminated string for lowercase types
            local null_pos = data:find("\0", pos, true)
            if null_pos then
                return data:sub(pos, null_pos - 1)
            else
                return data:sub(pos)
            end
        elseif type_char == "M" or type_char == "L" or type_char == "G" or type_char == "T" or type_char == "H" then
            -- Size-prefixed data for uppercase types: 4-byte big-endian size
            if pos + 3 <= #data then
                local b1, b2, b3, b4 = data:byte(pos, pos + 3)
                local field_size = bit.bor(
                    bit.lshift(b1, 24), bit.lshift(b2, 16),
                    bit.lshift(b3, 8), b4
                )
                pos = pos + 4
                return data:sub(pos, pos + field_size - 1)
            end
            break
        else
            -- Unknown type, try to skip (null-terminated)
            local null_pos = data:find("\0", pos, true)
            if null_pos then
                pos = null_pos + 1
            else
                break
            end
        end
    end

    -- Fallback: return raw data
    return data
end

--- Get the first N lines of a definition.
-- @param entry table From lookup().
-- @return string Trimmed text.
function DictInstance:getDefinitionPreview(entry)
    local definition = self:getDefinition(entry)
    if not definition then return nil end

    -- Strip HTML tags if this is an HTML dictionary
    local is_html = self.sametypesequence == "h" or self.sametypesequence == "H"
    if is_html then
        -- Replace <br>, <br/>, <p>, </p> with newlines
        definition = definition:gsub("<[bB][rR]%s*/?>"  , "\n")
        definition = definition:gsub("</?[pP]%s*>"       , "\n")
        -- Strip all remaining HTML tags (replace with space to avoid words merging)
        definition = definition:gsub("<[^>]+>", " ")
        -- Decode common HTML entities
        definition = definition:gsub("&amp;",  "&")
        definition = definition:gsub("&lt;",   "<")
        definition = definition:gsub("&gt;",   ">")
        definition = definition:gsub("&quot;", '"')
        definition = definition:gsub("&nbsp;", " ")
        definition = definition:gsub("&#(%d+);", function(n)
            local cp = tonumber(n)
            if cp < 128 then
                return string.char(cp)
            elseif cp < 2048 then
                return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
            else
                return string.char(
                    0xE0 + math.floor(cp / 4096),
                    0x80 + math.floor(cp / 64) % 64,
                    0x80 + cp % 64)
            end
        end)
        -- Collapse runs of spaces introduced by tag removal
        definition = definition:gsub(" +", " ")
    end

    -- Trim leading/trailing whitespace
    definition = definition:gsub("^%s+", ""):gsub("%s+$", "")

    return definition
end

--- Close the dictionary and release resources.
function DictInstance:close()
    if self.dict_fh then
        self.dict_fh:close()
        self.dict_fh = nil
    end
    if self.idx_ptr then
        C.munmap(self.idx_ptr, self.idx_size)
        self.idx_ptr = nil
        self.idx_data = nil
    end
    self.entry_offsets = nil
    self.entry_count = 0
end

StarDictLookup.DictInstance = DictInstance

return StarDictLookup
