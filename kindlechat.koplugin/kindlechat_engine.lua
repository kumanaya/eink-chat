--[[--
Runs the local llama2.c binary and streams its output back to the UI.

The model runs as a separate process that writes to a file, and we poll that
file. Deliberately not io.popen:

  - popen blocks the UI thread for the whole generation, and we want the partial
    text on screen while it is still being written;
  - polling keeps KOReader responsive, so the user can still scroll, or close the
    dialog and cancel.

run-model.sh finishes the output file with a sentinel line, which is how we know
generation ended (and where we read the throughput from).
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local Engine = {}

local DONE_MARK = "__KINDLE_CHAT_DONE__"
local ERROR_MARK = "__KINDLE_CHAT_ERROR__"

-- 0.4s feels instant to the eye without hammering a slow CPU: at ~8 tok/s a
-- token lands every ~125ms, so the refresh is never the bottleneck.
local POLL_INTERVAL = 0.4
-- 0.4s * 1500 = 10 minutes. A runaway generation must not poll forever.
local MAX_POLLS = 1500

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Plain io.open on purpose: KOReader's helper modules differ between versions
-- (ffi/util has no writeToFile), and this needs no helper at all.
local function write_file(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

--[[--
Splits the sentinel off the accumulated output.

The sentinel carries three numbers the runner collected: throughput, how long the
weights took to load, and how much RAM was left. The last two are only knowable on
the device, which is why they are reported rather than guessed.

Returns text, finished, tok_s, error_message, load_s, mem_mb
--]]
function Engine.parse(raw)
    if not raw then return "", false end

    local err = raw:match(ERROR_MARK .. "%s*([^\n]*)")
    if err then
        return "", true, nil, err
    end

    local pos = raw:find(DONE_MARK, 1, true)
    if pos then
        local toks, load, mem = raw:sub(pos + #DONE_MARK):match("^%s*(%S+)%s*(%S*)%s*(%S*)")
        return raw:sub(1, pos - 1), true, toks, nil, load, mem
    end

    return raw, false
end

--[[--
Engine.start(opts, on_update, on_done) -> cancel()

opts = {
    script   = path to run-model.sh (inside the plugin directory)
    app_dir  = APP_DIR for the runner
    prompt   = the prompt text
    steps    = max tokens to generate
    temp     = sampling temperature
    topp     = top-p
    work_dir = where to keep the temp files (defaults to /tmp)
}

on_update(text)                 called on every poll with the text so far
on_done(text, tok_s, err)       called once, when generation ends
--]]
function Engine.start(opts, on_update, on_done)
    local dir = opts.work_dir or "/tmp"
    local prompt_file = dir .. "/kindlechat-prompt.txt"
    local out_file = dir .. "/kindlechat-out.txt"

    write_file(prompt_file, opts.prompt or "")
    os.remove(out_file)
    os.remove(out_file .. ".err")

    -- Everything interpolated here is controlled by us (plugin path, fixed
    -- APP_DIR, /tmp paths). The user's text only ever travels through the prompt
    -- file, so it never reaches a shell parser.
    local cmd = string.format(
        'APP_DIR="%s" sh "%s" "%s" "%s" %d %s %s >/dev/null 2>&1 &',
        opts.app_dir or "/mnt/us/extensions/kindlechat",
        opts.script,
        prompt_file,
        out_file,
        opts.steps or 60,
        tostring(opts.temp or 0.8),
        tostring(opts.topp or 0.9)
    )

    logger.dbg("kindlechat: running", cmd)

    -- os.execute, not ffi/util's util.execute: the latter is a direct exec with no
    -- shell and it waits for the child, so it can neither set APP_DIR= nor
    -- background a job. os.execute goes through /bin/sh, where the trailing "&"
    -- detaches the runner and returns at once.
    os.execute(cmd)

    local state = { cancelled = false, polls = 0 }

    local tick
    tick = function()
        if state.cancelled then return end
        state.polls = state.polls + 1

        local text, finished, toks, err, load, mem = Engine.parse(read_file(out_file))
        if on_update then on_update(text, finished) end

        if finished then
            state.cancelled = true
            if on_done then on_done(text, toks, err, load, mem) end
            return
        end

        if state.polls >= MAX_POLLS then
            state.cancelled = true
            if on_done then on_done(text, nil, "timed out") end
            return
        end

        UIManager:scheduleIn(POLL_INTERVAL, tick)
    end

    UIManager:scheduleIn(POLL_INTERVAL, tick)

    return function()
        state.cancelled = true
        UIManager:unschedule(tick)
    end
end

return Engine
