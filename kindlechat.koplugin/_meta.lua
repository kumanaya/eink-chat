--[[--
E-INK HACK: an offline chat on top of a local model running on the Kindle.

The model runs entirely on the device -- either SmolLM2-135M-Instruct through
llama.cpp, or the TinyStories base model through llama2.c (both under
extensions/kindlechat). This plugin is only the interface: it reuses KOReader's
widgets, so the on-screen keyboard, scrolling and e-ink rendering are the ones
that already work well on a Kindle.
--]]

return {
    name = "kindlechat",
    fullname = _("E-INK HACK"),
    description = _([[Offline chat with a local model running on the Kindle itself.

Either SmolLM2-135M-Instruct through llama.cpp (chat mode), or the TinyStories
15M base model through llama2.c (story mode), both under extensions/kindlechat.
Nothing leaves the device.]]),
    version = "0.1.0",
}
