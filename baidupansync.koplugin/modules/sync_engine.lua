--[[--
Local sync engine for Stage B (manual JSON exchange).

No network backend is involved. The "remote record" is the JSON file in the
export directory, and its exact bytes are fingerprinted like a cloud record.

Flow (export):
    preparing (full SHA-256 identity, cached when valid)
    -> writing (build record: revision from the local baseline + 1, new writeId)
    -> verifying (read back the file, validate, compare writeId/identity)
    -> committing_local (store the baseline: raw fingerprint, revision, position)
    -> done | failed | uncertain | cancelled

Flow (import):
    preparing (read + validate record, hash the opened book)
    -> reading_remote (identity match + baseline classification)
    -> awaiting_confirm (user decision, conflict kind exposed to the dialog)
    -> rechecking (identity re-checked; changed book aborts)
    -> persisting_restore/applying/checking_position (ProgressService)
    -> committing_local (baseline updated only after a confirmed apply)
    -> done | failed | uncertain | cancelled

Manual-exchange baselines live under a fixed, internal `backendId`
(`ManualBackendId`) so they can reuse the backendId+bookId isolation and never
mix with real WebDAV/Baidu baselines added in later stages. It is not a
user-selectable backend.
]]

local Errors = require("modules/errors")
local Hash = require("modules/hash")
local Conflict = require("modules/conflict")
local ProgressRecord = require("modules/progress_record")
local Task = require("modules/task")

local SyncEngine = {}
SyncEngine.__index = SyncEngine

-- Internal identity of the manual file-exchange channel. Kept as a hex id so
-- it has exactly the same shape as a real backendId.
SyncEngine.MANUAL_BACKEND_ID = Hash.sha256_text("baidupansync.manual-exchange.v1")

function SyncEngine:new(o)
    o = o or {}
    for _, field in ipairs({ "identity", "progress", "exports", "state", "config" }) do
        if not o[field] then
            error("SyncEngine requires " .. field)
        end
    end
    return setmetatable({
        identity = o.identity,
        progress = o.progress,
        exports = o.exports,
        state = o.state,
        config = o.config,
        random = o.random or require("modules/random"),
        now = o.now or os.time,
        device_label = o.device_label or "koreader",
    }, self)
end

function SyncEngine:get_manual_backend_id()
    return SyncEngine.MANUAL_BACKEND_ID
end

function SyncEngine:_new_task(kind, on_state)
    return Task:new{ kind = kind, on_state = on_state }
end

function SyncEngine:_set_failure(task, err)
    local target = "failed"
    if err and err.code == Errors.CODES.CANCELLED then
        target = "cancelled"
    elseif err and (err.outcome == "uncertain" or err.code == Errors.CODES.UNCERTAIN) then
        target = "uncertain"
    end
    if task:can_transition(target) then
        task:transition(target, { code = err and err.code })
    end
end

function SyncEngine:_identify(context, opts, completion)
    self.identity:identify(context.book.file_path, {
        use_cache = opts.use_cache ~= false,
        chunk_size = opts.chunk_size,
        on_hash_start = opts.on_hash_start,
        on_hash_finish = opts.on_hash_finish,
        on_progress = opts.on_progress,
        is_cancelled = opts.is_cancelled,
        schedule = opts.schedule,
    }, completion)
end

--- Exports the current position as a cloud-schema progress record.
-- @tparam table context ProgressService capture
-- @tparam table opts {
--   on_state=function(state, info), on_hash_start=function(total),
--   on_hash_finish=function(), on_progress=function(done,total),
--   is_cancelled=function(), schedule=function(callback), chunk_size=number }
-- @tparam function completion completion(err, result)
function SyncEngine:export_current(context, opts, completion)
    opts = opts or {}
    completion = completion or function() end
    if type(context) ~= "table" or type(context.book) ~= "table"
        or type(context.progress) ~= "table" then
        completion(Errors.new(Errors.CODES.INVALID_INPUT, "书籍上下文无效"))
        return
    end

    local task = self:_new_task("export", opts.on_state)
    local finished = false
    local function finish(err, result)
        if finished then return end
        finished = true
        completion(err, result)
    end
    local function fail(err, result)
        self:_set_failure(task, err)
        finish(err, result)
    end

    task:transition("preparing")
    self:_identify(context, {
        on_hash_start = opts.on_hash_start,
        on_hash_finish = opts.on_hash_finish,
        on_progress = opts.on_progress,
        is_cancelled = opts.is_cancelled,
        schedule = opts.schedule,
        chunk_size = opts.chunk_size,
    }, function(identity_err, identity)
        if identity_err then
            return fail(identity_err)
        end

        if self.progress._check_context then
            local valid, err = self.progress:_check_context(context)
            if not valid then return fail(err) end
        end
        if identity.size ~= context.book.size
            or (context.book.mtime and context.book.mtime ~= identity.mtime) then
            return fail(Errors.new(Errors.CODES.CONFLICT, "捕获位置后书籍文件已变化，请重试"))
        end
        local writing_ok = task:transition("writing")
        if not writing_ok then
            return fail(Errors.new(Errors.CODES.INVALID_INPUT, "导出任务状态异常"))
        end

        local base, base_err = self.state:get(SyncEngine.MANUAL_BACKEND_ID, identity.book_id)
        if base_err then return fail(base_err) end
        local revision = (base and base.base_revision or 0) + 1

        local write_id, random_err = self.random.hex(16)
        if not write_id then return fail(random_err) end
        local device_id, device_err = self.config:ensure_device_id{
            label = self.device_label,
        }
        if not device_id then return fail(device_err) end

        local record, build_err = ProgressRecord.build(context, identity, {
            revision = revision,
            write_id = write_id,
            device_id = device_id,
            now = self.now(),
        })
        if not record then return fail(build_err) end

        local path, save_err = self.exports:save(record, {
            filename = string.format("progress-%s-rev%d.json",
                identity.book_id:sub(1, 8), revision),
        })
        if not path then return fail(save_err) end

        task:transition("verifying")
        local raw, read_err = self.exports:read(path)
        if not raw then
            return fail(Errors.new(Errors.CODES.UNCERTAIN,
                "导出文件已写入但无法回读: " .. (read_err and read_err.message or ""),
                { outcome = "uncertain" }), { path = path, record = record })
        end
        local readback, decode_err = ProgressRecord.decode(raw)
        if not readback
            or readback.sync.writeId ~= record.sync.writeId
            or readback.book.id ~= identity.book_id
            or readback.book.contentSha256 ~= identity.content_sha256
            or readback.sync.revision ~= revision then
            return fail(Errors.new(Errors.CODES.UNCERTAIN,
                "导出文件回读校验失败: " .. (decode_err and decode_err.message or ""),
                { outcome = "uncertain" }), { path = path, record = record })
        end

        local fingerprint = ProgressRecord.raw_fingerprint(raw)
        if not fingerprint then
            return fail(Errors.new(Errors.CODES.INVALID_INPUT, "无法计算导出记录指纹"))
        end

        task:transition("committing_local")
        local baseline = {
            remote_state = "present",
            base_revision = revision,
            base_remote_fingerprint = fingerprint,
            last_progress_fingerprint = Conflict.position_fingerprint(record.progress),
            updated_at = record.sync.updatedAt,
            last_write_id = write_id,
        }
        local committed, commit_err = self.state:put(
            SyncEngine.MANUAL_BACKEND_ID, identity.book_id, baseline)
        if not committed then
            task:transition("uncertain", { code = commit_err and commit_err.code })
            return finish(Errors.new(
                commit_err and commit_err.code or Errors.CODES.IO,
                "已导出文件，但本地基线未更新: "
                    .. (commit_err and commit_err.message or ""),
                { outcome = "uncertain" }),
                { path = path, record = record, fingerprint = fingerprint,
                  baseline_committed = false })
        end

        task:transition("done")
        finish(nil, {
            record = record,
            raw = raw,
            path = path,
            fingerprint = fingerprint,
            revision = revision,
            identity = identity,
            task = task,
            baseline_committed = true,
        })
    end)
end

--- Imports a record file produced by this plugin (or a compatible device).
-- @tparam string path file inside the export directory
-- @tparam table context ProgressService capture of the currently opened book
-- @tparam table opts {
--   confirm=function(info, decide), on_state=..., hash callbacks ... }
-- @tparam function completion completion(err, result)
function SyncEngine:import_from_file(path, context, opts, completion)
    opts = opts or {}
    completion = completion or function() end
    if type(context) ~= "table" or type(context.book) ~= "table"
        or type(context.progress) ~= "table" then
        completion(Errors.new(Errors.CODES.INVALID_INPUT, "书籍上下文无效"))
        return
    end
    if type(opts.confirm) ~= "function" then
        completion(Errors.new(Errors.CODES.INVALID_INPUT, "缺少导入确认回调"))
        return
    end

    local task = self:_new_task("import", opts.on_state)
    local finished = false
    local function finish(err, result)
        if finished then return end
        finished = true
        completion(err, result)
    end
    local function fail(err, result)
        self:_set_failure(task, err)
        finish(err, result)
    end

    task:transition("preparing")
    local raw, read_err = self.exports:read(path)
    if not raw then return fail(read_err) end
    local record, decode_err = ProgressRecord.decode(raw)
    if not record then return fail(decode_err) end

    self:_identify(context, {
        on_hash_start = opts.on_hash_start,
        on_hash_finish = opts.on_hash_finish,
        on_progress = opts.on_progress,
        is_cancelled = opts.is_cancelled,
        schedule = opts.schedule,
        chunk_size = opts.chunk_size,
    }, function(identity_err, identity)
        if identity_err then return fail(identity_err) end

        if identity.content_sha256 ~= record.book.contentSha256
            or identity.size ~= record.book.size then
            return fail(Errors.new(Errors.CODES.CONFLICT,
                "当前书籍与记录的完整 SHA-256 不一致，拒绝应用"))
        end

        local baseline, baseline_err = self.state:get(
            SyncEngine.MANUAL_BACKEND_ID, record.book.id)
        if baseline_err then return fail(baseline_err) end
        local fingerprint = ProgressRecord.raw_fingerprint(raw)
        if not fingerprint then
            return fail(Errors.new(Errors.CODES.INVALID_INPUT, "无法计算导入记录指纹"))
        end
        local classification = Conflict.classify(
            baseline, fingerprint, record.sync.revision)

        task:transition("reading_remote", { classification = classification.kind })
        task:transition("awaiting_confirm", { classification = classification.kind })

        local decided = false
        local function decide(accepted)
            if decided or task:is_terminal() then return end
            decided = true
            if not accepted then
                task:transition("cancelled")
                finish(Errors.new(Errors.CODES.CANCELLED, "用户取消导入"))
                return
            end
            task:transition("rechecking")
            if opts.is_cancelled and opts.is_cancelled() then
                task:transition("cancelled")
                finish(Errors.new(Errors.CODES.CANCELLED, "用户取消导入"))
                return
            end

            self:_identify(context, { use_cache = true }, function(recheck_err, rechecked)
                if recheck_err then return fail(recheck_err) end
                if rechecked.content_sha256 ~= record.book.contentSha256
                    or rechecked.size ~= record.book.size then
                    return fail(Errors.new(Errors.CODES.CONFLICT,
                        "书籍在导入过程中发生变化，已停止"))
                end

                context.book.content_sha256 = rechecked.content_sha256
                self.progress:apply(context, record.progress, function(apply_err, apply_result)
                    if apply_err then
                        return fail(apply_err, {
                            record = record,
                            classification = classification,
                            apply_result = apply_result,
                        })
                    end
                    task:transition("committing_local")
                    local new_baseline = {
                        remote_state = "present",
                        base_revision = record.sync.revision,
                        base_remote_fingerprint = fingerprint,
                        last_progress_fingerprint = Conflict.position_fingerprint(record.progress),
                        updated_at = record.sync.updatedAt,
                        last_write_id = record.sync.writeId,
                    }
                    local committed, commit_err = self.state:put(
                        SyncEngine.MANUAL_BACKEND_ID, record.book.id, new_baseline)
                    if not committed then
                        task:transition("uncertain", { code = commit_err and commit_err.code })
                        return finish(Errors.new(
                            commit_err and commit_err.code or Errors.CODES.IO,
                            "已恢复阅读位置，但本地基线未更新: "
                                .. (commit_err and commit_err.message or ""),
                            { outcome = "uncertain" }),
                            { record = record, applied = true,
                              baseline_committed = false,
                              classification = classification })
                    end
                    task:transition("done")
                    finish(nil, {
                        record = record,
                        raw = raw,
                        fingerprint = fingerprint,
                        classification = classification,
                        applied = true,
                        baseline_committed = true,
                        apply_result = apply_result,
                        task = task,
                    })
                end, {
                    on_state = function(state)
                        if task:can_transition(state) then
                            task:transition(state)
                        end
                    end,
                })
            end)
        end

        local info = {
            record = record,
            raw = raw,
            baseline = baseline,
            classification = classification,
            fingerprint = fingerprint,
            identity = identity,
            context = context,
        }
        local ok_confirm, confirm_err = pcall(opts.confirm, info, decide)
        if not ok_confirm then
            fail(Errors.new(Errors.CODES.INVALID_INPUT,
                "确认回调失败: " .. tostring(confirm_err)))
        end
    end)
end

-- A single engine must not interleave confirmations, restore points or baselines.
for _, name in ipairs({ "export_current", "import_from_file" }) do
    local implementation = SyncEngine[name]
    SyncEngine[name] = function(self, ...)
        local args = { ... }
        local index = name == "export_current" and 3 or 4
        local completion = args[index] or function() end
        if self._active then
            return completion(Errors.new(Errors.CODES.CONFLICT, "已有同步任务，请等待其完成或取消"))
        end
        self._active = true
        local finished = false
        args[index] = function(err, result)
            if finished then return end
            finished = true
            self._active = false
            completion(err, result)
        end
        local ok = pcall(implementation, self, unpack(args, 1, index))
        if not ok and not finished then
            args[index](Errors.new(Errors.CODES.INVALID_INPUT, "同步任务异常，已停止；请核对文件及基线"))
        end
    end
end
return SyncEngine
