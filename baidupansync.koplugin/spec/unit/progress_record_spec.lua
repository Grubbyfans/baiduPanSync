describe("progress_record (cloud schema v1)", function()
    local ProgressRecord, Hash

    local function valid_record()
        local digest = string.rep("a", 64)
        return {
            schemaVersion = 1,
            book = {
                id = digest,
                title = "三国演义",
                format = "epub",
                size = 1024,
                contentSha256 = digest,
            },
            progress = {
                type = "xpointer",
                value = "/body/DocFragment[1]/body/div/p[3]/text().5",
                percent = 0.25,
            },
            sync = {
                revision = 12,
                writeId = string.rep("b", 32),
                deviceId = "koreader-mac-0123456789abcdef",
                updatedAt = "2026-11-16T20:00:00+08:00",
            },
        }
    end

    setup(function()
        require("commonrequire")
        ProgressRecord = require("modules.progress_record")
        Hash = require("modules.hash")
    end)

    it("accepts a well-formed cloud record", function()
        assert.is_true(ProgressRecord.validate(valid_record()))
    end)

    it("accepts a record without the optional percent", function()
        local record = valid_record()
        record.progress.percent = nil
        assert.is_true(ProgressRecord.validate(record))
    end)

    it("rejects unknown schema versions", function()
        local record = valid_record()
        record.schemaVersion = 99
        local ok, err = ProgressRecord.validate(record)
        assert.is_nil(ok)
        assert.is_equal("UNSUPPORTED", err.code)
    end)

    it("rejects book.id != book.contentSha256", function()
        local record = valid_record()
        record.book.contentSha256 = string.rep("b", 64)
        local ok, err = ProgressRecord.validate(record)
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    it("rejects malformed digests", function()
        for _, digest in ipairs({ "abc", string.rep("A", 64), string.rep("g", 64) }) do
            local record = valid_record()
            record.book.id = digest
            record.book.contentSha256 = digest
            assert.is_nil(ProgressRecord.validate(record), digest)
        end
    end)

    it("rejects invalid sizes and non-epub formats", function()
        for _, size in ipairs({ -1, 1.5, "1024" }) do
            local record = valid_record()
            record.book.size = size
            assert.is_nil(ProgressRecord.validate(record))
        end
        local record = valid_record()
        record.book.format = "pdf"
        assert.is_nil(ProgressRecord.validate(record))
    end)

    it("rejects missing, empty, control-character and oversized titles", function()
        for _, title in ipairs({ nil, "", "bad\ntitle", "bad\255title", string.rep("书", 200) }) do
            local record = valid_record()
            record.book.title = title
            assert.is_nil(ProgressRecord.validate(record), tostring(title))
        end
    end)

    it("rejects malformed positions and percents", function()
        local record = valid_record()
        record.progress.type = "page"
        assert.is_nil(ProgressRecord.validate(record))

        record = valid_record()
        record.progress.value = ""
        assert.is_nil(ProgressRecord.validate(record))

        record = valid_record()
        record.progress.value = "abc\0def"
        assert.is_nil(ProgressRecord.validate(record))

        for _, percent in ipairs({ 0 / 0, math.huge, -0.1, 1.1, "0.5" }) do
            record = valid_record()
            record.progress.percent = percent
            assert.is_nil(ProgressRecord.validate(record), tostring(percent))
        end
    end)

    it("rejects malformed revision, writeId, deviceId and updatedAt", function()
        for _, revision in ipairs({ 0, -1, 1.5, "12" }) do
            local record = valid_record()
            record.sync.revision = revision
            assert.is_nil(ProgressRecord.validate(record), tostring(revision))
        end
        for _, field in ipairs({ "writeId", "deviceId" }) do
            local record = valid_record()
            record.sync[field] = ""
            assert.is_nil(ProgressRecord.validate(record))
            record = valid_record()
            record.sync[field] = "bad\0id"
            assert.is_nil(ProgressRecord.validate(record))
            record = valid_record()
            record.sync[field] = string.rep("x", 129)
            assert.is_nil(ProgressRecord.validate(record))
        end
        for _, stamp in ipairs({ "2026-11-16 20:00:00", "2026-11-16T20:00:00", "x" }) do
            local record = valid_record()
            record.sync.updatedAt = stamp
            assert.is_nil(ProgressRecord.validate(record), stamp)
        end
    end)

    it("round-trips through encode/decode", function()
        local text = assert(ProgressRecord.encode(valid_record()))
        local decoded, err = ProgressRecord.decode(text)
        assert.is_nil(err)
        assert.is_equal(string.rep("a", 64), decoded.book.id)
        assert.is_equal(12, decoded.sync.revision)
    end)

    it("rejects malformed JSON, non-objects and oversized input", function()
        local record, err = ProgressRecord.decode("{not json")
        assert.is_nil(record)
        assert.is_equal("INVALID_INPUT", err.code)

        record, err = ProgressRecord.decode("[1,2]")
        assert.is_nil(record)
        assert.is_equal("UNSUPPORTED", err.code)

        record, err = ProgressRecord.decode(string.rep(" ", ProgressRecord.MAX_BYTES + 1))
        assert.is_nil(record)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    it("fingerprints exact bytes, including whitespace", function()
        assert.is_equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ProgressRecord.raw_fingerprint("abc"))
        assert.is_not_equal(
            ProgressRecord.raw_fingerprint('{"a":1}'),
            ProgressRecord.raw_fingerprint('{ "a": 1 }'))
    end)

    it("builds a record from capture context and identity", function()
        local context = {
            book = { title = "三国演义", file_name = "sanguo.epub" },
            progress = {
                type = "xpointer",
                value = "/body/DocFragment[1]/body/div/p[3]/text().5",
                percent = 0.25,
            },
        }
        local identity = { content_sha256 = string.rep("c", 64), size = 2048 }
        local record, err = ProgressRecord.build(context, identity, {
            revision = 3,
            write_id = string.rep("d", 32),
            device_id = "koreader-mac-0123456789abcdef",
            now = 1763300000,
        })
        assert.is_nil(err)
        assert.is_equal(string.rep("c", 64), record.book.id)
        assert.is_equal(3, record.sync.revision)
        assert.is_equal(0.25, record.progress.percent)
        assert.is_equal(2048, record.book.size)
        assert.is_truthy(record.sync.updatedAt:match("^%d%d%d%d%-%d%d%-%d%dT"))

        record, err = ProgressRecord.build(context, { content_sha256 = "bad", size = 1 }, {
            revision = 1, write_id = "x", device_id = "y",
        })
        assert.is_nil(record)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    it("computes a known empty-string digest", function()
        assert.is_equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            Hash.sha256_text(""))
    end)
end)
