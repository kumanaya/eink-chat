--[[--
Unit tests for kindlechat_engine.lua's sentinel parsing.

Engine.parse is a pure function, so it can be tested without a Kindle, without
KOReader and without the model: the KOReader modules it needs are stubbed in this
directory (ui/uimanager.lua, ffi/util.lua, logger.lua).

Run from this directory with any Lua 5.1/LuaJIT:

    cd tests
    lua test_engine.lua

See the dev-tools README in the e-ink-hack workshop for building a Lua with Zig
if you do not have one.
--]]

package.path = "../?.lua;" .. package.path

local Engine = require("kindlechat_engine")

local fail = 0
local function check(desc, got, want)
    if got == want then
        print(string.format("  ok       %s", desc))
    else
        print(string.format("  FAILED   %s\n             got : %s\n             want: %s",
            desc, tostring(got), tostring(want)))
        fail = fail + 1
    end
end

print("=== Engine.parse ===")

-- nothing written yet
local t, f = Engine.parse(nil)
check("nil -> empty text, not finished", tostring(t) .. "/" .. tostring(f), "/false")

t, f = Engine.parse("")
check("empty -> not finished", tostring(f), "false")

-- generation in progress
t, f = Engine.parse("Once upon a time, there was")
check("partial -> text preserved", t, "Once upon a time, there was")
check("partial -> not finished", tostring(f), "false")

-- finished: exactly the shape run-model.sh writes
local full = "Once upon a time, there was a robot.\n\n__KINDLE_CHAT_DONE__ 8.218893\n"
local toks, err
t, f, toks, err = Engine.parse(full)
check("finished -> text without the sentinel", t, "Once upon a time, there was a robot.\n\n")
check("finished -> marked finished", tostring(f), "true")
check("finished -> tok/s read back", tostring(toks), "8.218893")
check("finished -> no error", tostring(err), "nil")

-- the sentinel also carries the two device-only numbers: load time and free RAM
local with_extra, load, mem
t, f, toks, err, load, mem = Engine.parse("hi\n\n__KINDLE_CHAT_DONE__ 4.7 12.4 183\n")
check("sentinel -> tok/s", tostring(toks), "4.7")
check("sentinel -> load seconds", tostring(load), "12.4")
check("sentinel -> free MB", tostring(mem), "183")

-- and it must not break when the runner could not measure them
t, f, toks, err, load, mem = Engine.parse("hi\n\n__KINDLE_CHAT_DONE__ 4.7 ? ?\n")
check("sentinel -> unknowns survive", tostring(load) .. "/" .. tostring(mem), "?/?")

-- the sentinel must never leak into the displayed text
check("sentinel absent from the text", tostring(t:find("__KINDLE_CHAT", 1, true)), "nil")

-- tok/s unavailable ("?"), which is what the runner writes when it cannot read it
t, f, toks, err = Engine.parse("text\n\n__KINDLE_CHAT_DONE__ ?\n")
check("tok/s '?' -> finished", tostring(f), "true")
check("tok/s '?' -> passed through (the UI skips it)", tostring(toks), "?")

-- environment failure
t, f, toks, err = Engine.parse("__KINDLE_CHAT_ERROR__ no runner found under /x\n")
check("error -> finished", tostring(f), "true")
check("error -> message captured", tostring(err), "no runner found under /x")
check("error -> empty text (nothing to show)", tostring(t), "")

-- the error marker wins over the success marker
t, f, toks, err = Engine.parse("__KINDLE_CHAT_ERROR__ boom\n__KINDLE_CHAT_DONE__ 1\n")
check("error takes priority", tostring(err), "boom")

print()
if fail == 0 then
    print("RESULT: all good")
else
    print(string.format("RESULT: %d failure(s)", fail))
end
os.exit(fail == 0 and 0 or 1)
