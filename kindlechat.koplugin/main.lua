--[[--
E-INK HACK: plugin entry point.

Registers an "E-INK HACK" entry under KOReader's Tools menu. The model itself
(binary plus weights) lives in extensions/kindlechat, produced by the sibling
kindlechat project; this plugin only drives it.
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local ChatDialog = require("kindlechat_dialog")

-- Where build/deploy put the binary and the weights.
local APP_DIR = "/mnt/us/extensions/kindlechat"

-- Generation defaults. They can also be set in the app's chat.conf, but these
-- are what the dialog sends to the runner.
local DEFAULT_STEPS = 60
local DEFAULT_TEMP = 0.8
local DEFAULT_TOPP = 0.9
-- Matches the runner's -c: the model's own 8192 context would want ~189 MB of
-- KV cache, out of the Kindle's 512 MB.
local CHAT_CTX = 1024

local KindleChat = WidgetContainer:extend{
    name = "kindlechat",
    is_doc_only = false,
}

function KindleChat:init()
    self.ui.menu:registerToMainMenu(self)
end

function KindleChat:addToMainMenu(menu_items)
    menu_items.KindleChat = {
        sorting_hint = "tools",
        text = _("E-INK HACK"),
        callback = function()
            self:openChat()
        end,
    }
end

local function is_file(path)
    return lfs.attributes(path, "mode") == "file"
end

--[[--
Finds a quantized instruct model, which is what turns this from a story
generator into something that answers questions.

Any .gguf under model/ counts; the runner picks the same file.
--]]
function KindleChat:findGGUF()
    local dir = APP_DIR .. "/model"
    local iter, obj = lfs.dir(dir)
    if not iter then return nil end
    local found
    for entry in iter, obj do
        if entry:match("%.gguf$") then
            found = dir .. "/" .. entry
            break
        end
    end
    return found
end

--[[--
Looks for a usable runner + weights pair.

An instruct model (.gguf) wins when present. Otherwise the fp32 TinyStories pair,
which measured faster on the KT4 than its Q8_0 counterpart.
--]]
function KindleChat:hasModel()
    if self:findGGUF() then
        return is_file(APP_DIR .. "/llama-completion")
    end
    if is_file(APP_DIR .. "/llama") and is_file(APP_DIR .. "/model/stories15M.bin") then
        return true
    end
    if is_file(APP_DIR .. "/llama-q8") and is_file(APP_DIR .. "/model/stories15M_q80.bin") then
        return true
    end
    return false
end

function KindleChat:openChat()
    local gguf = self:findGGUF()
    local haveEngine = gguf and is_file(APP_DIR .. "/llama-completion")
        or is_file(APP_DIR .. "/llama") or is_file(APP_DIR .. "/llama-q8")

    if not self:hasModel() or not haveEngine then
        UIManager:show(InfoMessage:new{
            text = _([[Cannot find a model under /mnt/us/extensions/kindlechat.

For a chat, install llama-completion plus a .gguf under model/.
For the story mode, install the llama binary plus model/stories15M.bin.
See the kindlechat project for the build and deploy steps.]]),
            timeout = 10,
        })
        return
    end

    self.dialog = ChatDialog:new{
        plugin_dir = self.path,
        app_dir = APP_DIR,
        chat_mode = gguf ~= nil,
        ctx = CHAT_CTX,
        steps = DEFAULT_STEPS,
        temp = DEFAULT_TEMP,
        topp = DEFAULT_TOPP,
    }
    UIManager:show(self.dialog)
end

return KindleChat
