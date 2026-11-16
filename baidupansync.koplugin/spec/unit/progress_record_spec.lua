describe("progress_record", function()
    local ProgressRecord

    local function valid_record()
        return {
            schemaVersion = 1,
            recordType = "local-progress",
            book = {
                title = "三国演义",
                fileName = "sanguo.epub",
                format = "epub",
                size = 1024,
                partialMd5 = string.rep("a", 32),
            },
            progress = {
                type = "xpointer",
                value = "/body/DocFragment[1]/body/div/p[3]/text().5",
                percent = 0.25,
            },
            exportedAt = "2026-11-16T20:00:00+08:00",
        }
    end

    setup(function()
        require("commonrequire")
        ProgressRecord = require("modules.progress_record")
    end)

    it("accepts a well-formed record", function()
        assert.is_true(ProgressRecord.validate(valid_record()))
    end)

    it("accepts a record without optional fields", function()
        local record = valid_record()
        record.book.title = nil
        record.book.partialMd5 = nil
        record.progress.percent = nil
        record.exportedAt = nil
        assert.is_true(ProgressRecord.validate(record))
    end)

    it("rejects unknown schema versions", function()
        local record = valid_record()
        record.schemaVersion = 2
        local ok, err = ProgressRecord.validate(record)
        assert.is_nil(ok)
        assert.is_equal("UNSUPPORTED", err.code)
    end)

    it("rejects a cloud record type", function()
        local record = valid_record()
        record.recordType = "progress"
        local ok, err = ProgressRecord.validate(record)
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    it("rejects invalid book sizes", function()
        for _, size in ipairs({ -1, 1.5, "1024" }) do
            local record = valid_record()
            record.book.size = size
            assert.is_nil(ProgressRecord.validate(record))
        end
    end)

    it("rejects a file name containing path separators", function()
        local record = valid_record()
        record.book.fileName = "../evil.epub"
        assert.is_nil(ProgressRecord.validate(record))
    end)

    it("rejects control characters and invalid UTF-8 text", function()
        local record = valid_record()
        record.book.title = "bad\ntitle"
        assert.is_nil(ProgressRecord.validate(record))

        record = valid_record()
        record.book.title = "bad\255title"
        assert.is_nil(ProgressRecord.validate(record))
    end)

    it("rejects overlong text fields", function()
        local record = valid_record()
        record.book.title = string.rep("书", 200) -- 600 UTF-8 bytes
        assert.is_nil(ProgressRecord.validate(record))
    end)

    it("rejects malformed partial MD5 values", function()
        for _, md5 in ipairs({ "ABCDEF", string.rep("g", 32), string.rep("A", 32) }) do
            local record = valid_record()
            record.book.partialMd5 = md5
            assert.is_nil(ProgressRecord.validate(record))
        end
    end)

    it("rejects NUL and oversized XPointers", function()
        local record = valid_record()
        record.progress.value = "abc\0def"
        assert.is_nil(ProgressRecord.validate(record))

        record = valid_record()
        record.progress.value = "/body/" .. string.rep("x", ProgressRecord.MAX_XPOINTER_BYTES)
        assert.is_nil(ProgressRecord.validate(record))
    end)

    it("rejects non-finite and out-of-range percent values", function()
        for _, percent in ipairs({ 0 / 0, math.huge, -math.huge, -0.1, 1.1, "0.5" }) do
            local record = valid_record()
            record.progress.percent = percent
            assert.is_nil(ProgressRecord.validate(record), "percent " .. tostring(percent))
        end
    end)

    it("decodes and re-encodes a record", function()
        local text = ProgressRecord.encode(valid_record())
        assert.is_string(text)
        local decoded, err = ProgressRecord.decode(text)
        assert.is_nil(err)
        assert.is_equal(1, decoded.schemaVersion)
        assert.is_equal(0.25, decoded.progress.percent)
        assert.is_equal("sanguo.epub", decoded.book.fileName)
    end)

    it("rejects malformed JSON and oversized input", function()
        local record, err = ProgressRecord.decode("{not json")
        assert.is_nil(record)
        assert.is_equal("INVALID_INPUT", err.code)

        record, err = ProgressRecord.decode(string.rep(" ", ProgressRecord.MAX_BYTES + 1))
        assert.is_nil(record)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    it("refuses to encode an invalid record", function()
        local record = valid_record()
        record.progress.value = ""
        local text, err = ProgressRecord.encode(record)
        assert.is_nil(text)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    describe("matches_book", function()
        it("requires the same size", function()
            local record = valid_record()
            local ok, reason = ProgressRecord.matches_book(record, {
                size = 1025, file_name = "sanguo.epub", title = "三国演义",
            })
            assert.is_false(ok)
            assert.is_equal("size", reason)
        end)

        it("rejects different partial MD5 values", function()
            local record = valid_record()
            local ok, reason = ProgressRecord.matches_book(record, {
                size = 1024, file_name = "sanguo.epub", title = "三国演义",
                partial_md5 = string.rep("b", 32),
            })
            assert.is_false(ok)
            assert.is_equal("partialMd5", reason)
        end)

        it("accepts a matching file name even when the title changed", function()
            local record = valid_record()
            local ok = ProgressRecord.matches_book(record, {
                size = 1024, file_name = "sanguo.epub", title = "三国演义（修订）",
            })
            assert.is_true(ok)
        end)

        it("rejects a different book with the same size", function()
            local record = valid_record()
            local ok, reason = ProgressRecord.matches_book(record, {
                size = 1024, file_name = "other.epub", title = "另一本书",
            })
            assert.is_false(ok)
            assert.is_equal("name", reason)
        end)
    end)

    it("formats ISO timestamps with an offset", function()
        local stamp = ProgressRecord.iso_timestamp(os.time())
        assert.is_truthy(stamp:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[+-]%d%d:%d%d$"))
    end)
end)
