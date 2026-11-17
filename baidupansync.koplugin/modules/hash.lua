--[[--
Chunked SHA-256 hashing (spec 3.2 / 3.3).

- incremental `ffi/sha2` stream, never builds the whole file in memory;
- reads one chunk, then yields to the scheduler so the UI can process cancel
  taps and repaint the progress dialog;
- checks the cancellation flag between chunks; a cancelled hash is never
  returned or cached;
- re-checks size and mtime after the last chunk and refuses a digest if the
  file changed while it was being read;
- completion is called exactly once.

The scheduler is injectable (`opts.schedule(callback)`), so tests can run
deterministically without UIManager.
]]

local sha2 = require("ffi/sha2")
local lfs = require("libs/libkoreader-lfs")

local Errors = require("modules/errors")

local Hash = {}

Hash.DEFAULT_CHUNK_SIZE = 1024 * 1024
Hash.MAX_CHUNK_SIZE = 4 * 1024 * 1024

function Hash.is_sha256_hex(value)
    return type(value) == "string" and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

--- Synchronous digest of a short string (JSON records, identity fields).
function Hash.sha256_text(text)
    if type(text) ~= "string" then return nil end
    return sha2.sha256(text)
end

--- Hashes a file asynchronously in chunks.
-- @tparam string path
-- @tparam table opts {
--   chunk_size=number, on_progress=function(done,total),
--   is_cancelled=function(), schedule=function(callback),
--   task=Task (optional, for state reporting) }
-- @tparam function completion completion(err, hex_digest, stat)
function Hash.file(path, opts, completion)
    opts = opts or {}
    completion = completion or function() end
    local chunk_size = opts.chunk_size or Hash.DEFAULT_CHUNK_SIZE
    if type(chunk_size) ~= "number" or chunk_size <= 0 then
        chunk_size = Hash.DEFAULT_CHUNK_SIZE
    end
    if chunk_size > Hash.MAX_CHUNK_SIZE then
        chunk_size = Hash.MAX_CHUNK_SIZE
    end
    local is_cancelled = opts.is_cancelled or function() return false end
    local schedule = opts.schedule or function(callback)
        require("ui/uimanager"):scheduleIn(0, callback)
    end
    local on_progress = opts.on_progress

    if type(path) ~= "string" or path == "" then
        completion(Errors.new(Errors.CODES.INVALID_INPUT, "书籍路径无效"))
        return
    end

    local attr = lfs.attributes(path)
    if not attr then
        completion(Errors.new(Errors.CODES.NOT_FOUND, "书籍文件不存在"))
        return
    end
    if attr.mode ~= "file" then
        completion(Errors.new(Errors.CODES.INVALID_INPUT, "书籍路径不是普通文件"))
        return
    end

    local handle, open_err = io.open(path, "rb")
    if not handle then
        completion(Errors.new(Errors.CODES.IO,
            "无法读取书籍文件: " .. tostring(open_err)))
        return
    end

    local size = attr.size
    local mtime = attr.modification
    local update = sha2.sha256()
    local processed = 0
    local finished = false

    local function finish(err, digest)
        if finished then return end
        finished = true
        handle:close()
        if not err and on_progress then
            pcall(on_progress, processed, size)
        end
        completion(err, digest, { size = size, mtime = mtime })
    end

    local function report()
        if not on_progress then return true end
        local ok, err = pcall(on_progress, processed, size)
        if not ok then
            finish(Errors.new(Errors.CODES.INVALID_INPUT,
                "哈希进度回调失败: " .. tostring(err)))
            return false
        end
        return true
    end

    local function check_changed()
        local after = lfs.attributes(path)
        if not after then
            return Errors.new(Errors.CODES.CONFLICT,
                "书籍文件在计算摘要期间被移除或替换")
        end
        if after.size ~= size or after.modification ~= mtime then
            return Errors.new(Errors.CODES.CONFLICT,
                "书籍文件在计算摘要期间发生变化，已放弃本次摘要")
        end
        return nil
    end

    local function step()
        if is_cancelled() then
            finish(Errors.new(Errors.CODES.CANCELLED, "已取消计算书籍摘要"))
            return
        end

        local chunk, read_err = handle:read(chunk_size)
        if not chunk then
            if processed ~= size then
                finish(Errors.new(Errors.CODES.IO,
                    "读取书籍文件中断: " .. tostring(read_err)))
                return
            end
            local changed_err = check_changed()
            if changed_err then
                finish(changed_err)
                return
            end
            local digest = update()
            if not Hash.is_sha256_hex(digest) then
                finish(Errors.new(Errors.CODES.IO, "无法生成有效的 SHA-256 摘要"))
                return
            end
            finish(nil, digest)
            return
        end

        update(chunk)
        processed = processed + #chunk
        if processed > size then
            finish(Errors.new(Errors.CODES.CONFLICT,
                "书籍文件在计算摘要期间增长，已放弃本次摘要"))
            return
        end
        if not report() then return end
        if processed == size then
            -- Let the final read return nil on the next step so that EOF is
            -- confirmed and the post-hash stat check runs in one place.
            schedule(step)
            return
        end
        schedule(step)
    end

    if report() then
        schedule(step)
    end
end

return Hash
