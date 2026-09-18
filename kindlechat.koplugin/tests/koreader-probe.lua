--[[--
Probe that exercises the plugin inside a real KOReader, headless.

Run through the harness:

    sh ../dev-tools/koreader-headless.sh kindlechat.koplugin \
        kindlechat.koplugin/tests/koreader-probe.lua

The harness installs the plugin into a throwaway KOReader and loads this file as
a plugin, so everything below runs against the real widget toolkit. It walks the
same path a tap does: require the dialog, build it, show it, open the input
dialog, and run one full turn against a stub model binary.

Two modes are checked, because they build the prompt differently:
  story mode  no .gguf; the TinyStories base model continues the transcript
  chat mode   a .gguf; an instruct model answers, and the prompt must be framed
              in ChatML or the model emits end-of-text and answers nothing

The first line is injected by the harness so the plugin's modules resolve.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")

local PLUGIN_DIR = _KCHAT_PLUGIN_DIR
local APP_DIR = os.getenv("KCHAT_APP_DIR")
local RESULT = os.getenv("KCHAT_PROBE_RESULT") or "/tmp/zzprobe.txt"

local PROMPT_SEEN = "/tmp/zzprobe-prompt.txt"

package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

-- io.open rather than a KOReader helper: ffi/util has no writeToFile, which is
-- exactly what this probe caught the first time it ran.
local function write_file(path, data)
    local f = io.open(path, "w")
    if not f then return end
    f:write(data)
    f:close()
end

local fails = 0

local function record(ok, msg)
    logger.info(string.format("ZZPROBE %s %s", ok and "ok" or "FAILED", msg))
    local f = io.open(RESULT, "a")
    if f then
        f:write(string.format("%s %s\n", ok and "ok" or "FAILED", msg))
        f:close()
    end
    if not ok then fails = fails + 1 end
end

-- Runs fn and records the outcome, so one broken step does not stop the probe.
local function step(desc, fn)
    local ok, err = pcall(fn)
    record(ok, desc .. (ok and "" or (" -- " .. tostring(err))))
    return ok, err
end

local function makeStoryStub()
    write_file(APP_DIR .. "/llama", [[#!/bin/sh
echo "Once upon a time, there was a stub robot."
echo "The stub robot was happy."
echo "achieved tok/s: 42.5" >&2
]])
    -- ffi/util's execute is a direct exec taking varargs, NOT a shell string
    ffiUtil.execute("chmod", "+x", APP_DIR .. "/llama")
    write_file(APP_DIR .. "/model/stories15M.bin", "")
    write_file(APP_DIR .. "/model/tokenizer.bin", "")
end

-- A stub llama-completion: records the -p prompt and answers like the real one.
local function makeChatStub()
    write_file(APP_DIR .. "/llama-completion", [[#!/bin/sh
prev=""
for a in "$@"; do
    if [ "$prev" = "-p" ]; then printf '%s' "$a" > ]] .. PROMPT_SEEN .. [[ ; fi
    prev="$a"
done
echo "The capital of France is Paris. [end of text]"
echo "common_perf_print: eval time = 100 ms / 10 runs ( 10.00 ms per token, 42.50 tokens per second)" >&2
]])
    ffiUtil.execute("chmod", "+x", APP_DIR .. "/llama-completion")
    write_file(APP_DIR .. "/model/stub-instruct.q4_k_m.gguf", "not a real model")
end

local function newDialog(chat_mode)
    local ChatDialog = require("kindlechat_dialog")
    return ChatDialog:new{
        plugin_dir = PLUGIN_DIR,
        app_dir = APP_DIR,
        chat_mode = chat_mode,
        ctx = 1024,
        steps = 20,
        temp = 0.8,
        topp = 0.9,
    }
end

-- t+3s: the UI is up by now.
UIManager:scheduleIn(3, function()
    local dialog
    if not step("require the chat dialog", function()
        dialog = newDialog(false)
    end) then return end

    step("the dialog built a scrollable transcript", function()
        assert(dialog.scroller, "no scroller")
        assert(dialog.scroller.text_widget, "no text widget inside the scroller")
    end)

    step("the dialog has the input and clear buttons", function()
        assert(dialog.write_button, "no write button")
        assert(dialog.clear_button, "no clear button")
    end)

    if not step("show the dialog", function()
        UIManager:show(dialog)
    end) then return end

    -- The keyboard is the whole reason this is a plugin, so open it for real.
    step("open the input dialog (KOReader's keyboard)", function()
        dialog:showInput()
        assert(dialog.input_dialog, "no input dialog was created")
        assert(dialog.input_dialog:getInputText() == "", "input should start empty")
    end)

    step("close the input dialog", function()
        UIManager:close(dialog.input_dialog)
    end)

    -- --- story mode: one full turn -------------------------------------------
    step("prepare the story stub binary", function()
        makeStoryStub()
    end)

    step("send a message (story mode)", function()
        dialog:send("Once upon a time, there was a little robot")
    end)

    record(dialog.generating == true, "story: generation started")

    UIManager:scheduleIn(5, function()
        logger.info("ZZPROBE story status=[" .. (dialog.status_text or "") .. "]")
        logger.info("ZZPROBE story transcript=[" .. (dialog.transcript or ""):gsub("\n", "\\n") .. "]")

        record((dialog.transcript or ""):find("stub robot", 1, true) ~= nil,
            "story: the model output reached the transcript")
        record(not dialog.generating, "story: generation finished")
        record((dialog.status_text or ""):find("42.5", 1, true) ~= nil,
            "story: the tok/s from the runner is shown")

        step("close the story dialog", function()
            UIManager:close(dialog)
        end)

        -- --- chat mode: the prompt must be framed in ChatML ------------------
        local chat
        if not step("prepare the chat stub (a .gguf and llama-completion)", function()
            makeChatStub()
        end) then
            logger.info("ZZPROBE DONE fails=" .. tostring(fails))
            return
        end

        if not step("build the dialog in chat mode", function()
            chat = newDialog(true)
            assert(chat.chat_mode, "chat_mode should be on")
        end) then
            logger.info("ZZPROBE DONE fails=" .. tostring(fails))
            return
        end

        step("show the chat dialog", function()
            UIManager:show(chat)
        end)

        step("send a question (chat mode)", function()
            chat:send("What is the capital of France?")
        end)

        UIManager:scheduleIn(5, function()
            local prompt = ""
            local f = io.open(PROMPT_SEEN, "r")
            if f then prompt = f:read("*a") or "" f:close() end
            logger.info("ZZPROBE chat prompt=[" .. prompt:gsub("\n", "\\n") .. "]")
            logger.info("ZZPROBE chat status=[" .. (chat.status_text or "") .. "]")
            logger.info("ZZPROBE chat transcript=[" .. (chat.transcript or ""):gsub("\n", "\\n") .. "]")

            -- This is the assertion that matters most: without the ChatML
            -- framing an instruct model answers nothing at all.
            record(prompt:find("<|im_start|>user", 1, true) ~= nil,
                "chat: the prompt is framed in ChatML")
            record(prompt:find("What is the capital of France?", 1, true) ~= nil,
                "chat: the question is in the prompt")
            record(prompt:find("<|im_start|>assistant", 1, true) ~= nil,
                "chat: the prompt ends on the assistant turn")
            record((chat.transcript or ""):find("Paris", 1, true) ~= nil,
                "chat: the answer reached the transcript")
            record((chat.transcript or ""):find("> What is the capital", 1, true) ~= nil,
                "chat: the question is shown as a user line")
            record(not (chat.transcript or ""):find("%[end of text%]"),
                "chat: the end-of-text marker was stripped")
            record(#(chat.messages or {}) == 2, "chat: both turns were kept as messages")

            step("close the chat dialog", function()
                UIManager:close(chat)
            end)

            logger.info("ZZPROBE DONE fails=" .. tostring(fails))
        end)
    end)
end)
