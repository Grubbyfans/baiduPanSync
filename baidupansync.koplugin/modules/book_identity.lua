--[[--
Book identity: full-content SHA-256, cache and invalidation (spec 3.2).

The identity is the SHA-256 of the whole EPUB. `bookId` is that digest, so the
same bytes on another device/path resolve to the same key, and any content
change becomes a new book.

The cache is only an optimization keyed by path + size + mtime. Those
attributes are invalidation clues, not proof of content identity: a file that
keeps its size and mtime but changes content cannot be detected without
re-reading it, which the spec explicitly accepts as a limit. The cache is
disposable: if it is corrupt or has a future version, it is ignored (and
overwritten by the next successful hash), because it is derived data, unlike
config/sync state.

`partial MD5` is not used here; it remains an optional matching clue supplied
by the reader's doc_settings.
]]

local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local Errors = require("modules/errors")
local FileUtil = require("modules/file_util")
local Hash = require("modules/hash")

local BookIdentity = {}
BookIdentity.__index = BookIdentity
BookIdentity.SCHEMA_VERSION = 1
BookIdentity.CACHE_FILE = "hash_cache.json"
BookIdentity.MAX_CACHE_ENTRIES = 200

local function valid_entry(entry)
    return type(entry) == "table"
        and type(entry.size) == "number" and entry.size >= 0
        and type(entry.mtime) == "number"
        and Hash.is_sha256_hex(entry.sha256)
end

function BookIdentity:new(o)
    o = o or {}
    if type(o.dir) ~= "string" or o.dir == "" then
        error("BookIdentity requires a directory")
    end
    local dir = o.dir:gsub("/+$", "")
    return setmetatable({
        dir = dir,
        file = dir .. "/" .. BookIdentity.CACHE_FILE,
        now = o.now or os.time,
    }, self)
end

function BookIdentity:get_path()
    return self.file
end

function BookIdentity:_read_cache()
    local attr = lfs.attributes(self.file)
    if not attr then
        return { schemaVersion = BookIdentity.SCHEMA_VERSION, data = { entries = {} } }
    end
    if attr.mode ~= "file" then return nil, "cache path is not a file" end
    local text, read_err = FileUtil.read_file(self.file, 512 * 1024)
    if not text then return nil, read_err end
    local ok, decoded = pcall(json.decode, text)
    if not ok or type(decoded) ~= "table"
        or decoded.schemaVersion ~= BookIdentity.SCHEMA_VERSION
        or type(decoded.data) ~= "table"
        or type(decoded.data.entries) ~= "table" then
        return nil, "cache is unreadable"
    end
    return decoded
end

function BookIdentity:_write_cache(cache)
    local entries = cache.data.entries
    local count, oldest_path, oldest_at = 0, nil, nil
    for path, entry in pairs(entries) do
        count = count + 1
        if not valid_entry(entry) then
            entries[path] = nil
        else
            local at = tonumber(entry.computed_at) or 0
            if not oldest_at or at < oldest_at then
                oldest_at, oldest_path = at, path
            end
        end
    end
    if count > BookIdentity.MAX_CACHE_ENTRIES and oldest_path then
        entries[oldest_path] = nil
    end
    local ok, text = pcall(json.encode, cache)
    if not ok or type(text) ~= "string" then return false end
    local mkdir_ok = FileUtil.mkdir_p(self.dir)
    if not mkdir_ok then return false end
    return FileUtil.write_atomic(self.file, text)
end

-- Returns the cached digest only when size and mtime still match.
function BookIdentity:get_cached(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local cache = self:_read_cache()
    if not cache then return nil end
    local entry = cache.data.entries[path]
    if not valid_entry(entry) then return nil end
    if entry.size ~= attr.size or entry.mtime ~= attr.modification then
        return nil
    end
    return entry.sha256, entry
end

function BookIdentity:put_cached(path, size, mtime, digest)
    if not Hash.is_sha256_hex(digest) then return false end
    local cache = self:_read_cache()
    if not cache then
        cache = { schemaVersion = BookIdentity.SCHEMA_VERSION, data = { entries = {} } }
    end
    cache.data.entries[path] = {
        size = size,
        mtime = mtime,
        sha256 = digest,
        computed_at = self.now(),
    }
    return self:_write_cache(cache)
end

function BookIdentity:invalidate(path)
    local cache = self:_read_cache()
    if not cache or cache.data.entries[path] == nil then return true end
    cache.data.entries[path] = nil
    return self:_write_cache(cache)
end

--- Computes (or reuses) the full identity of a book.
-- @tparam string path
-- @tparam table opts {
--   use_cache=boolean,
--   on_hash_start=function(total_bytes), on_hash_finish=function(),
--   on_progress=function(done,total), is_cancelled=function(),
--   schedule=function(callback), chunk_size=number }
-- @tparam function completion completion(err, identity)
-- identity = {book_id, content_sha256, size, mtime, path, cached}
function BookIdentity:identify(path, opts, completion)
    opts = opts or {}
    completion = completion or function() end
    local attr = lfs.attributes(path)
    if not attr then
        completion(Errors.new(Errors.CODES.NOT_FOUND, "书籍文件不存在"))
        return
    end
    if attr.mode ~= "file" then
        completion(Errors.new(Errors.CODES.INVALID_INPUT, "书籍路径不是普通文件"))
        return
    end

    if opts.use_cache ~= false then
        local cached = self:get_cached(path)
        if cached then
            completion(nil, {
                book_id = cached,
                content_sha256 = cached,
                size = attr.size,
                mtime = attr.modification,
                path = path,
                cached = true,
            })
            return
        end
    end

    if opts.on_hash_start then pcall(opts.on_hash_start, attr.size) end
    local function hash_finished()
        if opts.on_hash_finish then pcall(opts.on_hash_finish) end
    end

    Hash.file(path, {
        chunk_size = opts.chunk_size,
        on_progress = opts.on_progress,
        is_cancelled = opts.is_cancelled,
        schedule = opts.schedule,
    }, function(err, digest, stat)
        hash_finished()
        if err then
            completion(err)
            return
        end
        if not stat or stat.size ~= attr.size or stat.mtime ~= attr.modification then
            completion(Errors.new(Errors.CODES.CONFLICT,
                "书籍文件在计算摘要期间发生变化，请重试"))
            return
        end
        local cache_ok = self:put_cached(path, stat.size, stat.mtime, digest)
        completion(nil, {
            book_id = digest,
            content_sha256 = digest,
            size = stat.size,
            mtime = stat.mtime,
            path = path,
            cached = false,
            cache_warning = cache_ok and nil or "无法写入摘要缓存",
        })
    end)
end

return BookIdentity
