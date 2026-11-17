--[[--
SHA-256 throughput / cancellation benchmark (spec 3.3).

Run through the spec wrapper so the KOReader LuaJIT environment is available:

    ./spec/run.sh --bench
    BPS_BENCH_MB=10,100,300 ./spec/run.sh --bench

This measures the macOS/desktop emulator only. Target-device numbers (Kindle
Voyage, Kobo Clara BW) must be recorded separately and are not implied by this
script. The throughput budget is not a pass/fail gate here.
]]

require("ffi/loadlib")

local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local Hash = require("modules.hash")

local function make_file(path, mb)
    local file = assert(io.open(path, "wb"))
    local chunk = string.rep("\0", 1024 * 1024)
    for _ = 1, mb do file:write(chunk) end
    file:close()
end

local function bench(mb)
    local path = string.format("/tmp/bps-bench-%d.bin", mb)
    make_file(path, mb)
    local queue = {}
    local digest, failure
    local s1, us1 = ffiUtil.gettime()
    Hash.file(path, {
        chunk_size = 1024 * 1024,
        schedule = function(callback) queue[#queue + 1] = callback end,
    }, function(err, hex)
        failure = err
        digest = hex
    end)
    local chunks = 0
    while #queue > 0 do
        chunks = chunks + 1
        table.remove(queue, 1)()
    end
    local s2, us2 = ffiUtil.gettime()
    local seconds = (s2 - s1) + (us2 - us1) / 1000000
    local size = lfs.attributes(path, "size")
    os.remove(path)
    assert(not failure and digest, failure and failure.message or "no digest")
    assert(size == mb * 1024 * 1024)
    print(string.format("BENCH %4d MB: %7.3f s  %7.1f MB/s  chunks=%d  sha256=%s…",
        mb, seconds, mb / seconds, chunks, digest:sub(1, 12)))
end

local sizes = { 10, 100 }
if os.getenv("BPS_BENCH_MB") then
    sizes = {}
    for value in os.getenv("BPS_BENCH_MB"):gmatch("%d+") do
        sizes[#sizes + 1] = tonumber(value)
    end
end

for _, mb in ipairs(sizes) do bench(mb) end

-- Cancellation latency: stop after the first 1 MiB chunk.
local path = "/tmp/bps-bench-cancel.bin"
make_file(path, 100)
local queue, processed = {}, 0
local failure_code
local s1, us1 = ffiUtil.gettime()
Hash.file(path, {
    chunk_size = 1024 * 1024,
    schedule = function(callback) queue[#queue + 1] = callback end,
    is_cancelled = function() return processed >= 1 end,
    on_progress = function() processed = processed + 1 end,
}, function(err) failure_code = err and err.code end)
while #queue > 0 do table.remove(queue, 1)() end
local s2, us2 = ffiUtil.gettime()
local seconds = (s2 - s1) + (us2 - us1) / 1000000
os.remove(path)
print(string.format("CANCEL after %d chunk(s): %.3f s, code=%s",
    processed, seconds, tostring(failure_code)))
assert(failure_code == "CANCELLED", "cancellation did not report CANCELLED")
