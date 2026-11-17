--[[--
Backend identity (spec 2.1).

`backendId` is a local, stable identifier for a backend configuration. It is
the SHA-256 of an unambiguous, length-prefixed encoding of:

- WebDAV: type, normalized root URL, username (password never included);
- Baidu:  type, AppKey, normalized application directory, stable user id
          (tokens/secrets never included).

WebDAV normalization only applies the equivalences the spec confirms: scheme
and host case, default ports, and the trailing slash of the root path. Path
case and semantics are preserved; embedded credentials, queries and fragments
are rejected. Usernames keep their service-defined case.

Because identity changes create an independent baseline, changing server,
root directory or account resets the baseline, while changing only a password
or token (not part of the hash) does not.
]]

local Errors = require("modules/errors")
local Hash = require("modules/hash")

local BackendIdentity = {}

local ENCODING_VERSION = "bps-backend-v1"

local function fail(message)
    return nil, Errors.new(Errors.CODES.INVALID_INPUT, message)
end

local function has_control(value)
    return value:find("%c") ~= nil or value:find("%z") ~= nil
end

--- Normalizes a WebDAV root URL.
-- @treturn string|nil normalized
-- @treturn Errors|nil
function BackendIdentity.normalize_webdav(url)
    if type(url) ~= "string" or url == "" then
        return fail("WebDAV 根地址不能为空")
    end
    if url:find("%s") or has_control(url) then
        return fail("WebDAV 根地址不能包含空白或控制字符")
    end
    if url:find("[?#]") then
        return fail("WebDAV 根地址不能包含查询或片段")
    end
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then
        return fail("WebDAV 根地址必须包含 http:// 或 https://")
    end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return fail("WebDAV 根地址只支持 http/https")
    end

    local authority, path = rest:match("^([^/]+)(/.*)$")
    if not authority then
        authority, path = rest, ""
    end
    if authority:find("@") then
        return fail("WebDAV 根地址不能内嵌凭据")
    end

    local host, port
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^(%[[^%]]+%])(:%d+)$")
        if not host then
            host, port = authority, nil
        end
    else
        host, port = authority:match("^([^:]+)(:%d+)$")
        if not host then
            host, port = authority, nil
        end
    end
    if not host or host == "" then
        return fail("WebDAV 根地址缺少主机")
    end
    host = host:lower()
    if host:find("[^%w%.:%-%[%]]") then
        return fail("WebDAV 根地址包含不支持的主机字符")
    end

    local normalized_port
    if port then
        local number = tonumber(port:sub(2))
        if not number or number < 1 or number > 65535 then
            return fail("WebDAV 端口无效")
        end
        local default_port = scheme == "http" and 80 or 443
        if number ~= default_port then
            normalized_port = tostring(number)
        end
    end

    path = path or ""
    if has_control(path) then
        return fail("WebDAV 根路径包含控制字符")
    end
    if path == "" or path == "/" then
        path = "/"
    else
        path = path:gsub("/+$", "") .. "/"
        if path:sub(1, 1) ~= "/" then path = "/" .. path end
    end

    return string.format("%s://%s%s%s",
        scheme, host, normalized_port and (":" .. normalized_port) or "", path)
end

--- Normalizes the Baidu application directory to `/apps/<name>/` form.
function BackendIdentity.normalize_baidu_dir(dir)
    if type(dir) ~= "string" or dir == "" then
        return fail("百度应用目录不能为空")
    end
    if has_control(dir) then
        return fail("百度应用目录包含控制字符")
    end
    dir = dir:gsub("/+", "/")
    if dir:sub(1, 1) ~= "/" then dir = "/" .. dir end
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    if dir == "/" then
        return fail("百度应用目录不能是根目录")
    end
    return dir
end

local function validate_opaque(value, name)
    if type(value) ~= "string" or value == "" then
        return fail(name .. " 不能为空")
    end
    if #value > 256 then
        return fail(name .. " 过长")
    end
    if has_control(value) then
        return fail(name .. " 包含控制字符")
    end
    return true
end

-- Length-prefixed field encoding: fixes delimiters and field order so that
-- different configurations can never concatenate to the same byte string.
local function encode_fields(fields)
    local parts = { ENCODING_VERSION, tostring(#fields) }
    for _, field in ipairs(fields) do
        parts[#parts + 1] = string.format("%d:%s%d:%s",
            #field[1], field[1], #field[2], field[2])
    end
    return table.concat(parts, "|")
end

--- Computes backendId for a backend profile.
-- @tparam table profile {type="webdav"|"baidu", ...}
-- @treturn string|nil 64 lowercase hex
-- @treturn Errors|nil
function BackendIdentity.compute(profile)
    if type(profile) ~= "table" then
        return fail("后端配置必须是对象")
    end
    local fields
    if profile.type == "webdav" then
        local root, err = BackendIdentity.normalize_webdav(profile.root_url)
        if not root then return nil, err end
        local ok_name, name_err = validate_opaque(profile.username, "WebDAV 用户名")
        if not ok_name then return nil, name_err end
        fields = {
            { "type", "webdav" },
            { "root", root },
            { "username", profile.username },
        }
    elseif profile.type == "baidu" then
        local ok_key, key_err = validate_opaque(profile.app_key, "AppKey")
        if not ok_key then return nil, key_err end
        local app_dir, dir_err = BackendIdentity.normalize_baidu_dir(profile.app_dir)
        if not app_dir then return nil, dir_err end
        local ok_user, user_err = validate_opaque(profile.user_id, "百度用户标识")
        if not ok_user then return nil, user_err end
        fields = {
            { "type", "baidu" },
            { "app_key", profile.app_key },
            { "app_dir", app_dir },
            { "user_id", profile.user_id },
        }
    else
        return fail("不支持的后端类型: " .. tostring(profile.type))
    end

    local digest = Hash.sha256_text(encode_fields(fields))
    if not Hash.is_sha256_hex(digest) then
        return fail("无法计算后端标识")
    end
    return digest
end

return BackendIdentity
