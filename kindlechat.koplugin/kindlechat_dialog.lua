--[[--
The chat view.

The layout is the same shape as KOReader's own full-screen dialogs: a TitleBar, a
scrollable body and a button row at the bottom. Reusing ScrollTextWidget means
scrolling, the scrollbar and the e-ink refresh come for free, and the InputDialog
brings KOReader's on-screen keyboard -- which is the whole reason this is a
plugin instead of a hand-drawn framebuffer UI.

The chrome is kept sparse on purpose. A 600x800 8-bpp panel (the qemu-kindle4
machine, and every Kindle in that family) ghosts on grey and on extra widgets, so
the conversation is black type on white, one primary action, and a Stop that
only exists while the model is writing.

Two modes, picked by what is installed:

  chat   a .gguf is present, so llama.cpp runs an instruct model that answers.
         The prompt is built in the model's chat format (ChatML) and the turns
         are kept as messages.
  story  no .gguf, so the TinyStories base model runs: it continues text rather
         than answering, and the prompt is simply the tail of the transcript.

Without the chat framing an instruct model emits end-of-text immediately, so the
format is not cosmetic -- it is the difference between an answer and nothing.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Engine = require("kindlechat_engine")

-- English averages roughly 4 characters per token for this vocabulary.
local CHARS_PER_TOKEN = 4
-- Never let the on-screen transcript grow without bound: re-laying out a huge
-- TextBoxWidget gets slow on an e-ink device.
local MAX_DISPLAY_CHARS = 8000

local SYSTEM_PROMPT = "You are a helpful assistant."

local EMPTY_CHAT = "Ask a question.\nThe model runs on this Kindle. Nothing leaves the device."
local EMPTY_STORY = "Write the first line.\nThe model will continue the story from there."
local IDLE_CHAT = "Ask a question."
local IDLE_STORY = "Write the next line."

-- ChatML, which is what SmolLM2-Instruct uses. Changing the model means changing
-- this (Gemma uses <start_of_turn>user ... <end_of_turn>, for instance).
local function chatml(messages)
    local out = { "<|im_start|>system\n" .. SYSTEM_PROMPT .. "<|im_end|>\n" }
    for _, m in ipairs(messages) do
        out[#out + 1] = "<|im_start|>" .. m.role .. "\n" .. m.text .. "<|im_end|>\n"
    end
    out[#out + 1] = "<|im_start|>assistant\n"
    return table.concat(out)
end

local ChatDialog = InputContainer:extend{
    covers_fullscreen = true,
    transcript = "",
    messages = nil,
    chat_mode = false,
    generating = false,
    cancel_generation = nil,
}

function ChatDialog:init()
    local screen = Device.screen
    self.screen_w = screen:getWidth()
    self.screen_h = screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.show_parent = self

    self.messages = self.messages or {}

    -- 22 px reads at arm's length on a 600x800 panel without crowding the
    -- title bar. cfont is KOReader's body face: hinted, high-contrast.
    self.face = Font:getFace("cfont", 22)
    self.status_face = Font:getFace("smallinfofont")
    self.status_text = self.chat_mode and _(IDLE_CHAT) or _(IDLE_STORY)

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.chat_mode and _("Chat") or _("Stories"),
        with_bottom_line = true,
        close_callback = function() UIManager:close(self) end,
        show_parent = self,
    }

    self.status_widget = TextWidget:new{
        text = self.status_text,
        face = self.status_face,
        max_width = self.screen_w - 2 * Size.padding.default,
    }

    self.write_button = Button:new{
        text = self.chat_mode and _("Ask") or _("Write"),
        callback = function()
            if not self.generating then self:showInput() end
        end,
        show_parent = self,
    }
    self.stop_button = Button:new{
        text = _("Stop"),
        enabled = false,
        callback = function() self:stop() end,
        show_parent = self,
    }
    self.clear_button = Button:new{
        text = _("Clear"),
        callback = function()
            if self.generating then return end
            self.transcript = ""
            self.messages = {}
            self:setStatus(self.chat_mode and _(IDLE_CHAT) or _(IDLE_STORY))
            self:refreshView()
        end,
        show_parent = self,
    }

    self:buildLayout()
    self:setBusy(false)
end

function ChatDialog:buildLayout()
    local span = Size.span.vertical_default
    local gap = Size.span.horizontal_default
    local button_row = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.write_button:getSize().h },
        HorizontalGroup:new{
            self.write_button,
            HorizontalSpan:new{ width = gap },
            self.stop_button,
            HorizontalSpan:new{ width = gap },
            self.clear_button,
        },
    }

    -- Whatever is left after the chrome goes to the transcript.
    local body_height = self.screen_h
        - self.title_bar:getHeight()
        - self.status_widget:getSize().h
        - button_row:getSize().h
        - 4 * span
    if body_height < math.floor(self.screen_h * 0.4) then
        body_height = math.floor(self.screen_h * 0.4)
    end

    self.scroller = ScrollTextWidget:new{
        text = self:displayText(),
        face = self.face,
        width = self.screen_w - 2 * Size.padding.default,
        height = body_height,
        dialog = self,
        show_parent = self,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{
            self.title_bar,
            VerticalSpan:new{ width = span },
            self.scroller,
            VerticalSpan:new{ width = span },
            self.status_widget,
            VerticalSpan:new{ width = span },
            button_row,
        },
    }
end

function ChatDialog:setStatus(text)
    self.status_text = text or ""
    if self.status_widget then
        self.status_widget:setText(self.status_text)
    end
    UIManager:setDirty(self, "ui")
end

function ChatDialog:displayText()
    if self.transcript ~= "" then
        return self.transcript
    end
    return self.chat_mode and _(EMPTY_CHAT) or _(EMPTY_STORY)
end

local function setEnabled(btn, on)
    if not btn then return end
    if on then
        if btn.enable then btn:enable() else btn.enabled = true end
    else
        if btn.disable then btn:disable() else btn.enabled = false end
    end
end

function ChatDialog:setBusy(busy)
    setEnabled(self.write_button, not busy)
    setEnabled(self.stop_button, busy)
    setEnabled(self.clear_button, not busy)
end

function ChatDialog:stop()
    if not self.generating then return end
    if self.cancel_generation then
        self.cancel_generation()
        self.cancel_generation = nil
    end
    self.generating = false
    self:setBusy(false)
    self:setStatus(_("Stopped."))
end

function ChatDialog:refreshView()
    if self.scroller and self.scroller.text_widget then
        self.scroller.text_widget:setText(self:displayText())
        self.scroller:updateScrollBar()
        if self.transcript ~= "" then
            self.scroller:scrollToBottom()
        end
    end
    UIManager:setDirty(self, "ui")
end

--[[--
How many characters of prompt may be sent.

The context has to hold the prompt *and* the answer. In chat mode the context is
capped by the runner's -c (1024 tokens, to keep the KV cache near 24 MB instead
of the model's default 8192, which would want ~189 MB).
--]]
function ChatDialog:promptBudgetChars()
    local steps = self.steps or 60
    local ctx = self.chat_mode and (self.ctx or 1024) or (self.ctx or 256)
    local tokens = ctx - steps - 16  -- margin for the template and tokenizer
    if tokens < 16 then tokens = 16 end
    return tokens * CHARS_PER_TOKEN
end

--[[--
Story mode: the tail of the transcript, cut at a line boundary so the model does
not start mid-word. This is the history trim, and it is not an optimization --
the context length is a hard ceiling, so a long conversation cannot be sent.
--]]
function ChatDialog:trimmedTranscript()
    local text = self.transcript
    local budget = self:promptBudgetChars()
    if #text <= budget then return text end

    local cut = #text - budget
    local nl = text:find("\n", cut, true)
    if nl and nl < cut + 200 then
        cut = nl
    end
    return text:sub(cut + 1)
end

--[[--
Chat mode: the newest turns that still fit, framed in the model's chat format.
Older turns are dropped -- same reason as above.
--]]
function ChatDialog:chatPrompt()
    local budget = self:promptBudgetChars()
    local kept = {}
    local total = #SYSTEM_PROMPT

    for i = #self.messages, 1, -1 do
        local m = self.messages[i]
        local cost = #m.text + 32  -- role markers and newlines
        if total + cost > budget then break end
        table.insert(kept, 1, m)
        total = total + cost
    end

    return chatml(kept)
end

function ChatDialog:buildPrompt()
    if self.chat_mode then
        return self:chatPrompt()
    end
    return self:trimmedTranscript()
end

--[[--
Keeps the displayed transcript bounded. The prompt is trimmed separately, so
this only affects what is on screen.
--]]
function ChatDialog:trimDisplay()
    if #self.transcript <= MAX_DISPLAY_CHARS then return end
    local cut = #self.transcript - MAX_DISPLAY_CHARS
    local nl = self.transcript:find("\n", cut, true)
    if nl then cut = nl end
    self.transcript = "..." .. self.transcript:sub(cut + 1)
end

function ChatDialog:showInput()
    if not self.input_dialog then
        local placeholder = self.chat_mode and _("Ask a question.")
            or _("Write the next part of the story.")
        self.input_dialog = InputDialog:new{
            title = self.chat_mode and _("Ask") or _("Write"),
            input = "",
            description = placeholder,
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(self.input_dialog)
                        end,
                    },
                    {
                        text = _("Send"),
                        is_enter_default = true,
                        callback = function()
                            local text = self.input_dialog:getInputText()
                            UIManager:close(self.input_dialog)
                            self:send(text)
                        end,
                    },
                },
            },
        }
    end
    self.input_dialog:setInputText("")
    UIManager:show(self.input_dialog)
    self.input_dialog:onShowKeyboard()
end

function ChatDialog:send(text)
    text = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
    if text == "" or self.generating then return end

    if self.chat_mode then
        table.insert(self.messages, { role = "user", text = text })
        -- "You" / ">" keeps the turn scannable on a 8-bpp panel; the probe
        -- still matches the "> " user line.
        self.transcript = self.transcript .. (self.transcript == "" and "" or "\n\n")
            .. "You\n> " .. text
    else
        self.transcript = self.transcript .. text .. "\n"
    end

    self:trimDisplay()
    self:refreshView()
    self:generate()
end

function ChatDialog:generate()
    self.generating = true
    self:setBusy(true)
    self:setStatus(_("Writing..."))

    if self.chat_mode then
        self.transcript = self.transcript .. "\nKindle\n"
        self:refreshView()
    end

    local prompt = self:buildPrompt()
    -- Everything before this point is ours; the model's output is appended after.
    local keep = #self.transcript

    self.cancel_generation = Engine.start({
        script = self.plugin_dir .. "/run-model.sh",
        app_dir = self.app_dir,
        prompt = prompt,
        steps = self.steps,
        temp = self.temp,
        topp = self.topp,
    }, function(partial)
        self.transcript = self.transcript:sub(1, keep) .. partial
        self:refreshView()
    end, function(_text, toks, err, load, mem)
        self.generating = false
        self.cancel_generation = nil
        self:setBusy(false)

        local reply = self.transcript:sub(keep + 1):gsub("^%s+", ""):gsub("%s+$", "")
        if self.chat_mode then
            table.insert(self.messages, { role = "assistant", text = reply })
            self.transcript = self.transcript:sub(1, keep) .. reply
        elseif not self.transcript:match("\n$") then
            self.transcript = self.transcript .. "\n"
        end

        self:trimDisplay()
        if err then
            self:setStatus(_("Error: ") .. tostring(err))
        else
            -- load time and free RAM are only knowable on the device, so they
            -- are shown rather than assumed.
            local parts = {}
            if toks and toks ~= "?" then parts[#parts + 1] = string.format("%s tok/s", toks) end
            if load and load ~= "?" then parts[#parts + 1] = string.format("load %ss", load) end
            if mem and mem ~= "?" then parts[#parts + 1] = string.format("%s MB free", mem) end
            if #parts == 0 then
                self:setStatus(self.chat_mode and _(IDLE_CHAT) or _(IDLE_STORY))
            else
                self:setStatus(table.concat(parts, "  |  "))
            end
        end
        self:refreshView()
    end)
end

function ChatDialog:onCloseWidget()
    if self.cancel_generation then
        self.cancel_generation()
        self.cancel_generation = nil
    end
end

return ChatDialog
