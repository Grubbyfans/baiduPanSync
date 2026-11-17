--[[--
Conflict classification (spec 5.4) and position fingerprints.

The primary change criterion is the SHA-256 of the exact remote JSON bytes, not
`revision`: two records may share a revision and still differ, and a record may
change revision without a semantically different position. Timestamps and
percent are never used to pick a winner.

`position_fingerprint` intentionally excludes `percent` (display only), so the
same XPointer with an unknown or slightly different percentage is treated as
the same position and does not force a navigation.
]]

local Hash = require("modules/hash")
local ProgressRecord = require("modules/progress_record")

local Conflict = {}

Conflict.KINDS = {
    FIRST_CONTACT = "first_contact",
    UNCHANGED = "unchanged",
    REMOTE_CHANGED = "remote_changed",
    REMOTE_CREATED = "remote_created",
    REMOTE_DELETED = "remote_deleted",
    SAME_REVISION_DIFFERENT_RECORD = "same_revision_different_record",
}

function Conflict.position_fingerprint(progress)
    local valid = ProgressRecord.validate_position(progress)
    if not valid then return nil end
    return Hash.sha256_text("xpointer\n" .. progress.value)
end

--- Classifies an incoming record against the stored baseline.
-- @tparam table|nil baseline stored baseline (nil = never associated)
-- @tparam string|nil incoming_fingerprint raw-byte fingerprint of the incoming
--   record, or nil when the remote record is confirmed absent
-- @tparam number|nil incoming_revision display revision of the incoming record
-- @treturn table {kind, remote_changed, requires_confirmation, same_revision}
function Conflict.classify(baseline, incoming_fingerprint, incoming_revision)
    local result = {
        kind = Conflict.KINDS.UNCHANGED,
        remote_changed = false,
        requires_confirmation = false,
        same_revision = false,
    }

    if not baseline then
        result.kind = Conflict.KINDS.FIRST_CONTACT
        result.remote_changed = incoming_fingerprint ~= nil
        result.requires_confirmation = true
        return result
    end

    if baseline.remote_state == "absent" then
        if incoming_fingerprint == nil then
            return result
        end
        result.kind = Conflict.KINDS.REMOTE_CREATED
        result.remote_changed = true
        result.requires_confirmation = true
        return result
    end

    if incoming_fingerprint == nil then
        result.kind = Conflict.KINDS.REMOTE_DELETED
        result.remote_changed = true
        result.requires_confirmation = true
        return result
    end

    if baseline.base_remote_fingerprint == incoming_fingerprint then
        return result
    end

    result.remote_changed = true
    result.requires_confirmation = true
    result.same_revision = baseline.base_revision == incoming_revision
    result.kind = result.same_revision
        and Conflict.KINDS.SAME_REVISION_DIFFERENT_RECORD
        or Conflict.KINDS.REMOTE_CHANGED
    return result
end

--- True when applying the incoming position requires a navigation.
function Conflict.needs_navigation(local_progress, incoming_progress)
    if not local_progress or not incoming_progress then return true end
    local local_fp = Conflict.position_fingerprint(local_progress)
    local incoming_fp = Conflict.position_fingerprint(incoming_progress)
    if not local_fp or not incoming_fp then return true end
    return local_fp ~= incoming_fp
end

return Conflict
