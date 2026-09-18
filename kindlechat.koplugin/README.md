# kindlechat.koplugin

A KOReader plugin: an offline chat on top of a local TinyStories model running
on the Kindle itself.

## Why a plugin and not a standalone UI

The first attempt was a scriptlet that drew to the framebuffer with FBInk. It
worked, but a chat needs a keyboard and scrollable text -- and those are exactly
what KOReader already solved, well, on this hardware. Reusing them means:

- the on-screen keyboard comes from `InputDialog` (no QWERTY to hand-draw and
  calibrate);
- scrolling, the scrollbar and the e-ink refresh come from `ScrollTextWidget`;
- the whole UI is KOReader's, so it behaves like every other screen on the device.

What the plugin does *not* do is run the model. That is still the llama2.c binary
built by the app in the repository root (the scriptlet, builds and tooling),
under `/mnt/us/extensions/kindlechat`. This directory is only the interface to
it.

## Requirements

- KOReader installed on the Kindle (tested against the layout under
  `koreader/plugins/`).
- The model app installed: `/mnt/us/extensions/kindlechat` with a `llama` (or
  `llama-q8`) binary, `model/tokenizer.bin` and one of the `stories15M` weights.
  See the repository README for the build and deploy steps.

## Install

`tools/deploy.ps1` in the repository root copies this folder to
`koreader/plugins/kindlechat.koplugin/` and verifies every file. Then **restart
KOReader** and open **Tools -> E-INK HACK**.

## Files

| File | What it is |
|---|---|
| `_meta.lua` | Plugin metadata (name, description, version) |
| `main.lua` | Registers the Tools menu entry and opens the dialog |
| `kindlechat_dialog.lua` | The chat view: title bar, transcript, buttons, prompt trimming |
| `kindlechat_engine.lua` | Runs the model and polls its output back into the UI |
| `run-model.sh` | The shell runner the engine invokes |
| `tests/` | Development only; not deployed |

Module names are prefixed (`kindlechat_*`) because KOReader adds each plugin
directory to `package.path`, so a bare `engine.lua` would collide with any other
plugin using the same name.

## How a turn works

```
Tools -> E-INK HACK
   |
   |  Write  ->  InputDialog + KOReader keyboard
   v
ChatDialog:send(text)          appends the text to the transcript
   |
   v
ChatDialog:trimmedPrompt()     the tail of the transcript, within the token budget
   |
   v
Engine.start()                 writes the prompt to /tmp/kindlechat-prompt.txt
   |                           runs:  APP_DIR=... sh run-model.sh <prompt> <out> 60 0.8 0.9  &
   v
run-model.sh                   runs the llama binary, then writes
   |                           "__KINDLE_CHAT_DONE__ <tok/s>" at the end of <out>
   v
Engine tick (every 0.4s)       reads <out>, strips the sentinel, calls on_update
   |
   v
ChatDialog:refreshView()       setText + scrollToBottom + setDirty
```

### Why polling instead of io.popen

`io.popen` blocks the UI thread until the process exits. Generation takes
seconds, and the whole point is to show the text *while* it is written. Polling a
file keeps KOReader responsive, so the user can scroll or close the dialog (which
cancels generation) during a turn.

### Why the prompt goes through a file

`run-model.sh` reads the prompt with `$(cat "$prompt_file")`, so the user's text
is never placed on a command line. Typing `"quotes" and $dollars; rm -rf /` is
just text: the shell never parses it. `tests/test-run-model.sh` asserts exactly
that.

### The history trim is not an optimization

The model's position embeddings stop at **256 tokens**, so that is a hard ceiling
on the prompt *plus* the answer. `ChatDialog:promptBudgetChars` reserves the
answer's tokens and returns only the tail of the transcript, cut at a line
boundary. A long conversation cannot be sent whole -- it is arithmetic, not
policy.

## Testing

Three layers, all runnable on a PC with no Kindle and no KOReader install:

```sh
sh tests/test-run-model.sh        # the runner, with a stub llama binary
cd tests && lua test_engine.lua   # the sentinel parser, KOReader modules stubbed
```

And the one that matters most, because it runs inside a **real KOReader**:

```sh
sh ../dev-tools/koreader-headless.sh kindlechat.koplugin \
    kindlechat.koplugin/tests/koreader-probe.lua
```

That harness downloads KOReader's Linux build once, installs this plugin into a
throwaway config, and runs it with SDL's dummy video driver -- so no display is
needed. The probe then walks the same path a tap does: require the dialog, build
it, show it, open the input dialog (the keyboard), and run one full turn against
a stub model binary, checking that the output lands in the transcript.

This layer exists because the first two were not enough. It has already caught
two bugs that no static check would have seen:

- `ScrollTextWidget` was used but never required -- the dialog died on the first
  tap, and Lua's error took KOReader down with it;
- `ffi/util` has no `writeToFile`, so the prompt was never written and every turn
  came back empty.

Both are now covered by the probe.

A Lua syntax check is part of `../dev-tools/check.sh` when an interpreter is
available.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| No "E-INK HACK" under Tools | Plugin not loaded | Restart KOReader; check `koreader/plugins/kindlechat.koplugin/main.lua` exists |
| "Cannot find the model under ..." | The app is not installed | Run `tools/deploy.ps1` from the repository root |
| "Generating..." never ends | The runner never wrote the sentinel | Check `/tmp/kindlechat-out.txt` and `/tmp/kindlechat-out.txt.err` over SSH |
| Wrong or garbled output | fp32/Q8 pair mismatch | The runner picks fp32 first; confirm both files of that pair exist |
| Blank screen after opening | Very old KOReader without `ScrollTextWidget` | Update KOReader |

## License

AGPL-3.0, the same license as KOReader: the plugin runs inside it as a plugin,
requiring its modules. See [LICENSE](LICENSE).
