# E-INK CHAT - engineering log

The long story behind the app: measurements, dead ends and the numbers that
chose the models. Commands run from the repository root.

An offline chat that runs entirely on the Kindle. Two modes, picked by what is
installed on the device:

| | model | runtime | what it does |
|---|---|---|---|
| **chat** | SmolLM2-135M-Instruct, Q4_K_M (101 MB) | **llama.cpp** | you ask a question, it answers |
| story | TinyStories 15M | **llama2.c** | continues a story - a base model, so it cannot answer |

Chat mode is the point of the project, and getting there needed both a different
model and a different runtime. The reasoning, with the numbers, is in
[model-choice.md](model-choice.md).

For the interface there is `kindlechat.koplugin`, a KOReader plugin, so the
keyboard, the scrolling and the e-ink rendering are KOReader's own.

Status: the story mode **measured 8.2 tok/s on the KT4**. The chat model is
built, verified and deployed, but its token rate **on the device is not measured
yet** - the memory-bandwidth estimate is ~5 tok/s.

Builds **on Windows** with Zig (no WSL, no Docker, no toolchain); the chat
runtime cross-compiles from WSL with portable tools and no sudo. See
[Step 2](#step-2---build) and [Chat runtime](#chat-runtime-llamacpp).

## Why MVP before UI

Three unknowns decided whether the whole project was viable, and none of them
could be settled by reading documentation:

1. **Real speed** - how many tokens/s an ARMv7 at ~1 GHz does with 15M parameters.
2. **Memory** - does the model (58 MB fp32) fit in the 512 MB with the framework running?
3. **Binary** - does the cross-compile produce something the KT4 can run?

The MVP answered all three with the minimum amount of code: no keyboard, no UI, no linked FBInk.

## Result measured on the KT4

First real run, `stories15M` fp32 (`run.c`), Zig binary, 80 tokens:

| Measurement | Value |
|---|---|
| **tok/s** | **8.2** |
| Time for 80 tokens | ~10 s |
| Streaming | **confirmed** - the text appears token by token on the screen |
| Binary | `out/llama`, 1.40 MB, static ARM EABI5 hard-float |
| Model | 58 MB fp32 |

That the streaming is real matters: it means `fbink` does **not** buffer the model
output, so the chat UI can draw as tokens arrive, with no hack.

What this decides:

- **It fits and it runs.** 58 MB of model coexisted with the framework in the 512 MB.
- **The 135M instruct model is ruled out in practice.** It has ~9x more parameters
  than the 15M; even with Q8_0 it would be at ~2-3 tok/s. A fine-tune of the 15M
  itself keeps this speed (or ~2x with Q8) and is the chosen path.

## Q8_0 without PyTorch

The quantized model shrinks from 58 MB to **16.31 MB**, and on the x86 host it was
~2x faster - though on the KT4 it turned out **slower**, see below. The official
path (`export.py --version 2`) requires PyTorch, so I wrote my own converter
that goes straight from v0 fp32 to v2 Q8_0:

```sh
python tools/quantize.py model/stories15M.bin model/stories15M_q80.bin
```

| | fp32 | Q8_0 |
|---|---|---|
| Size | 58.0 MB | **16.31 MB** |
| tok/s (x86 host, for comparison) | 83.6 | **163.4** |
| tok/s (KT4, measured) | **8.2** | 5.5 |
| Max quantization error | - | 0.0023 |

### On the KT4 the Q8 was slower - and the reason is the compiler

The expectation (2x faster, as on x86) **did not transfer**. Measured on the KT4:
8.2 tok/s in fp32 versus 5.5 in Q8_0.

Investigating the generated ARM assembly:

- The **fp32 matmul is pure scalar** - `vmla.f32 s0, s2, s2`, one float MAC per
  instruction, **zero NEON**.
- The Q8 **actually uses NEON** for the integer multiply (`vmlal.s16 q8, d18, d20`),
  but it pays for `int ↔ float` conversions and the per-group scales in scalar VFP.
- The reason fp32 does not vectorize is not a flag: LLVM **disables the `neonfp` feature**
  on all these ARMv7 targets (`generic`, `cortex_a9`, `cortex_a7`, `cortex_a15`),
  that is, it refuses to use NEON for floating point on these CPUs.

I tested `-O3`, `-Ofast`, `-mcpu=cortex_a9/a7/a15` and even rewriting the matmul with
4 independent accumulators to break the serial dependency of the reduction. **All
of them gave the same instruction mix** (2 NEON, ~50 VFP; the rewritten matmul only
unrolled scalar, 113 VFP). It is a backend decision, not our code's.

Conclusion: **~8.2 tok/s is the ceiling for this CPU with this compiler**. The Q8 stays in the
project for its size (16 MB versus 58 MB), not for speed - and `chat.sh`
prefers fp32, with the Q8 as fallback and forceable via `chat.conf`.

The official llama2.c path recommends `make runfast` (which is `-Ofast`), so this
is not a flag oversight.

### What the Q8 brought that's good

The `tools/quantize.py` converter works and is proven (byte parity between the
numpy and stdlib paths, verified round-trip). If the target ever changes - another
compiler, armv8, or a bigger model where memory bandwidth weighs more -
the Q8 is already ready.

The converter **self-verifies**: it re-reads the generated file following the `runq.c`
layout, rebuilds the weights and compares with the source (the round-trip gives the same 0.0023, that is,
there is no layout error, only the quantization one).

It runs with or without numpy, and both paths give **identical bytes** (checked by md5).
The fallback is not decorative: WSL's `python3` does not have numpy.

> **Expensive bug:** in v2, tensors that exist per layer are written
> **interleaved** - `q(layer0) s(layer0) q(layer1) s(layer1)...` - and not
> "all the int8 and then all the scales". Getting this wrong **does not change the
> file size** and `runq.c` loads it without complaining; it just produces garbage. It was
> `runq.c` compiled on the host that caught it, not the size check.

To use the Q8 on the Kindle, install both pairs - `chat.sh` still prefers fp32,
since that measured faster, and you force the Q8 through `chat.conf`:

```
extensions/kindlechat/llama-q8                      <- .\build.ps1 -Src runq.c
extensions/kindlechat/model/stories15M_q80.bin      <- tools/quantize.py
```

If the fp32 pair is missing, it falls back to Q8 without complaining.

## Chat runtime (llama.cpp)

Chat mode needs llama.cpp, because three things rule llama2.c out:

- its `tokenizer.bin` is SentencePiece-based, and every small instruct model uses BPE;
- a 135M model in fp32 is 540 MB, which does not fit in 512 MB - and fp32 is all
  llama2.c has besides its Q8_0 path, which measured *slower* here;
- llama.cpp's integer kernels use NEON, which is exactly what LLVM refuses to do
  for floating point on this CPU (`neonfp` is off), so llama2.c's scalar fp32
  path leaves the hardware idle.

```sh
sh tools/build-llamacpp.sh          # -> out/llama-completion (ARMv7, static)
sh tools/build-llamacpp.sh --host   # same source for this machine, to try prompts
```

Nothing is installed system-wide: the script fetches Zig, CMake and Ninja as
portable builds into `~/tc`, so no sudo is needed.

Three things in that build are not obvious:

- **`GGML_LLAMAFILE=OFF` is required on ARMv7.** llamafile's sgemm uses fp16
  intrinsics (`vld1q_f16`) that a Cortex-A9 does not have, and the build stops
  there. It is an x86-oriented path, so nothing is lost.
- Only the **`llama-completion`** target is built. The umbrella `llama` app also
  wants the server, which is disabled, so it cannot link.
- **`-DCMAKE_EXE_LINKER_FLAGS="-s"`** matters: unstripped, the binary comes out
  at 83 MB instead of 7 MB.

`llama-completion` is called with `-no-cnv`, because the plugin applies the
model's chat template itself. That is not cosmetic: an instruct model given an
untemplated prompt emits end-of-text immediately, which looks exactly like "the
model answered nothing". `-c 1024` is load-bearing too - the model's own context
is 8192, and the KV cache for that would be ~189 MB of the Kindle's 512 MB.

The model is opt-in because of its size:

```sh
WITH_CHAT=1 sh tools/fetch.sh       # or on Windows: .\tools\fetch.ps1 -Chat
```

## How it works

```
chat.sh  (scriptlet in /mnt/us/documents)   │
   ├─ header          → fbink -y 0        (fixed header)
   │
   ├─ run_inference
   │     ./llama model.bin -z tokenizer.bin -t 0.8 -p 0.9 -n 80 -i "<prompt>"
   │        │ stdout: 1 token at a time, with fflush  → streaming
   │        └─ | tee last.txt | fbink -y 8      → appears on screen live
   │        stderr: "achieved tok/s: N" → chat.log
   │
   ├─ status          → shows tok/s on screen (the measurement that matters)
   │
   └─ wait_for_tap    → stays alive until you tap (otherwise the screen goes back to the library)
```

Details that come from reading `run.c` ([karpathy/llama2.c](https://github.com/karpathy/llama2.c)):

- `-i <string>` sets the prompt and the default mode (`generate`) runs **one** generation and exits -
  it does not keep reading stdin, which is what we want here.
- `-n <steps>` is clamped to `seq_len` (256) by the code itself.
- `safe_printf` + `fflush(stdout)` on every token -> you can see the text appearing.
- `achieved tok/s` goes to **stderr**, which is why it goes to the log and not to the screen.

## Structure

```
chat.sh              scriptlet: install in /mnt/us/documents/
chat.conf            prompt, steps, temperature, layout, timeouts
chat-ui.c            native GTK window over llama-server, no KOReader
chat-ui.sh           scriptlet: opens the native window from the library
build.ps1            builds on Windows (Zig, no WSL)
build.sh             builds on Linux/WSL/macOS (Zig or koxtoolchain)
docs/engineering.md  this file: the measurements behind the app
docs/model-choice.md which model can actually be a chat here, with the numbers
tools/fetch.ps1      downloads the dependencies on Windows
tools/fetch.sh       downloads the dependencies (Linux/WSL)
tools/build-llamacpp.sh  cross-compiles the chat runtime (llama.cpp)
tools/build-chatui.sh    compiles the GTK window (host or Kindle)
tools/quantize.py    converts the v0 fp32 model -> v2 Q8_0 (no PyTorch)
tools/deploy.ps1     copies everything to a connected Kindle, verifying hashes
tools/probe-device.sh collects info from the Kindle (run it on the device)
tools/inspect-elf.py checks whether the binary works on the Kindle
tests/functional.sh  test of chat.sh on the PC, with a fake binary
tests/chatui-smoke.sh  build + parsing self-test + a headless window run
vendor/              llama2.c code (run.c, runq.c) + tokenizer.bin
model/               weights (not versioned)
out/                 compiled binaries (not versioned)

kindlechat.koplugin/ the chat UI as a KOReader plugin (AGPL-3.0)
```

The main interface lives in `kindlechat.koplugin/`, deployed to
`koreader/plugins/`. The KOReader-free one is `chat-ui.c` / `chat-ui.sh`.

`chat.sh` accepts `APP_DIR` via environment variable, which allows testing it
outside the Kindle without touching `/mnt/us`.

## Tests

```sh
sh ../dev-tools/check.sh .     # syntax, CRLF/BOM, scriptlet header
sh tests/functional.sh         # runs chat.sh with a fake llama, without fbink
```

The functional test checks that the model output is captured, that `tok/s` is extracted
from stderr and shown, and that the arguments reach the binary with the right quoting
(including a prompt with spaces). See `../dev-tools/README.md`.


## Step 1 - Download dependencies

Windows:

```powershell
.\tools\fetch.ps1
```

Linux / WSL / macOS:

```sh
sh tools/fetch.sh
```

Downloads ~58 MB. What it brings:

| File | Source | Size |
|---|---|---|
| `vendor/run.c` | llama2.c | 38 KB |
| `vendor/runq.c` | llama2.c (Q8_0) | 43 KB |
| `vendor/tokenizer.bin` | llama2.c | 424 KB |
| `model/stories15M.bin` | `karpathy/tinyllamas` | 58 MB |

## Step 2 - Build

### Windows (no WSL, no Docker)

Uses **Zig** as the cross-compiler: `zig cc -target arm-linux-musleabihf` produces a
**static hard-float** ARMv7, which is exactly the Kindle's format. It needs no
toolchain, and no Linux.

```powershell
winget install zig.zig
.\build.ps1                      # produces out\llama
.\build.ps1 -Src runq.c          # produces out\llama-q8 (quantized model)
.\build.ps1 -DownloadZig         # downloads zig by itself (~90 MB) if you don't have it
```

At the end it runs `tools/inspect-elf.py` and confirms class, EABI, float ABI and whether the
binary is self-contained:

```
  machine            40 (ARM)        OK
  EABI               VER5            OK
  float ABI          hard-float      OK
  self-contained     yes (no PT_INTERP)  OK
  RESULT: works on the Kindle
```

### Linux / WSL / macOS

The same path, via `build.sh` (Zig runs on all three):

```sh
./build.sh                       # default: zig-arm
SRC=runq.c ./build.sh            # out/llama-q8
```

### Alternative: koxtoolchain (glibc)

The **`kindlehf`** target (`arm-kindlehf-linux-gnueabihf`) covers every Kindle with
firmware **>= 5.16.3**; below that, `kindlepw2`. It is KOReader's official path,
but it requires Linux and ~30 min of build:

```sh
sudo apt-get install -y build-essential autoconf automake bison flex gawk \
    libtool libtool-bin libncurses-dev curl file git gperf help2man \
    texinfo unzip wget
git clone --recursive --depth 1 https://github.com/koreader/koxtoolchain.git
cd koxtoolchain && chmod +x gen-tc.sh && ./gen-tc.sh kindlehf
cd .. && TARGET=kindlehf ./build.sh
```

It is only worth it if the Zig binary does not run on your device (see Troubleshooting).

### Validate on the PC before copying

```sh
TARGET=host ./build.sh        # or .\build.ps1 -Target host
./out/llama model/stories15M.bin -z vendor/tokenizer.bin -n 80 -i "Once upon a time"
```

It should output simple English text (a children's story) and, at the end of
stderr, `achieved tok/s: N`. **That number on the PC is the ceiling** - the Kindle will be much slower.

## Step 3 - Install on the Kindle

Copy over USB:

```
chat.sh                    →  /mnt/us/documents/chat.sh
chat.conf                  →  /mnt/us/extensions/kindlechat/chat.conf
out/llama                  →  /mnt/us/extensions/kindlechat/llama
model/stories15M.bin       →  /mnt/us/extensions/kindlechat/model/stories15M.bin
vendor/tokenizer.bin       →  /mnt/us/extensions/kindlechat/model/tokenizer.bin
```

Eject, and tap **E-INK HACK** in the library. Tap again to go back.

If something is missing, the scriptlet itself shows an error screen explaining what.

## Step 4 - Collect the numbers

Run `tools/probe-device.sh` on the Kindle (KTerm or SSH):

```sh
sh /mnt/us/kindlechat-probe.sh
```

It generates `/mnt/us/kindlechat-probe.txt` with CPU, ABI, memory, screen, input
devices, available tools and the fbink state. After running the app,
`/mnt/us/extensions/kindlechat/chat.log` brings the `tok/s` and the time for each step.

## Configuration

Everything in `chat.conf` (it is shell, loaded with `.`):

| Key | Default | What it does |
|---|---|---|
| `PROMPT` | `Once upon a time, there was a little robot` | Text sent to the model |
| `STEPS` | `80` | Tokens to generate (prompt + steps <= 256) |
| `TEMP` / `TOPP` | `0.8` / `0.9` | Sampling |
| `STREAM_LINE` | `8` | Line where the generated text starts |
| `STATUS_LINE` | `28` | Status line (tok/s) |
| `MAX_WAIT` | `600` | Cap on waiting for the tap, in seconds |

## Troubleshooting

| Symptom | Probable cause | What to do |
|---|---|---|
| "not found" / error screen | Missing file or in the wrong place | Check the paths from Step 3 |
| `Illegal instruction` | Incompatible CPU flags | `ARCH_FLAGS="" ./build.sh` (or `$env:ARCH_FLAGS=''`) |
| `No such file or directory` when running, even though the file exists | Dynamic binary with no loader | Confirm `float ABI: hard-float` and `self-contained: yes` in `inspect-elf.py` |
| Nothing appears on screen | fbink missing | `ls -l /mnt/us/libkh/bin/fbink`; see `chat.log` |
| Screen flickers a lot / "turns off" and comes back | Refresh area too large | Do not use `-r` in fbink (see below) |
| Text cut off at the end of the screen | `STREAM_LINE`/`STATUS_LINE` | Adjust in `chat.conf` |
| Goes back to the library by itself | Script finished | Already handled by `wait_for_tap`; if it persists, see `MAX_WAIT` |
| Very slow | 15M fp32 on ARMv7 | Measure the tok/s and consider the Q8_0 model (future step) |

> **Watch out for the `-r` in fbink.** It is **not refresh** - it is `--rpadded`, which
> fills the line with spaces up to the edge. This makes the redrawn area become the
> full width of the screen and the panel flicker much more. Refresh is already the
> fbink **default** behavior (the opposite option is `-b, --norefresh`); the
> explicit refresh flag is `-s, --refresh`.
>
> I got this by assuming the `-r` from the `sh_integration` launcher without checking the
> manual. It cost me a trip to the device.

> The Zig binary was validated in **format** (ARM, EABI5, hard-float, static)
> with `tools/inspect-elf.py` **and executed on the KT4 successfully** - the Zig/musl
> route works and needs no toolchain. `TARGET=kindlehf` with koxtoolchain (glibc)
> stays as plan B, in case a future build fails due to libc.

## The native window (no KOReader)

The plugin route answers "how do I get a chat UI for free". The other question
is what happens without KOReader - and the Kindle already has a toolkit: the
framework runs X, and its own UI is GTK. `chat-ui.c` is a GTK 3 window that
talks to `llama-server` over HTTP and streams the answer into chat bubbles, so
the transcript, the scrolling and the keyboard are library widgets instead of
pixels drawn by hand.

- **Input.** An on-screen QWERTY (shift, backspace, enter) built from a static
  layout in C, so nothing depends on the framework. The native keyboard can be
  borrowed instead with `lipc-set-prop com.lab126.keyboard open <appID>:abc:1`
  (`--native-keyboard`): the window is an X client, so the key events land on
  the focused entry.
- **Model process.** A per-turn `llama-completion` reloads the 101 MB from
  flash every time. The window starts `llama-server` once on `127.0.0.1:8080`
  and speaks the OpenAI-compatible `/v1/chat/completions` with
  `"stream": true`, parsing the SSE deltas; the process stays warm and the
  1024-token context lives in the server.
- **Window title.** The Kindle's awesome WM only manages windows titled in the
  lab126 key-value format, `L:A_N:application_PC:N_ID:<app>`; a plain title
  leaves the window unmanaged and the panel shows the white root. The app title
  is set to that format on the device and stays plain on the PC.
- **E-ink.** GTK draws through X; the refresh strategy is the framework's.
  `--refresh-cmd` exists so a full-panel refresh (`fbink -s`) can run after each
  answer, where ghosting accumulates.
- **Toolkit.** The source builds against GTK 3 (the PC) and GTK 2 (the Kindle
  SDK does not ship GTK 3); CSS is the GTK 3 path only. The cross build is
  koxtoolchain `kindlehf` plus the Kindle SDK overlaid into its sysroot, and the
  backend is the same Zig/musl llama.cpp build (`tools/build-llamacpp.sh
  --server`). The stripped ARM binary is 26 KB and links only firmware
  libraries.
- **What is missing.** It has not run on the KT4 yet: X repaint behavior on
  e-ink, real keyboard latency and the 101 MB server load are the numbers to
  collect on the device.

## What's missing

The MVP proved the path. What is left is the real app - this is the list, in
dependency order.

| # | Track | State |
|---|---|---|
| 1 | Device probe | **no longer needed for the UI** - see note below |
| 2 | Chat UI | **done** - `kindlechat.koplugin` |
| 3 | Keyboard | **done** - KOReader's `InputDialog` |
| 4 | Instruct model | **done** - SmolLM2-135M-Instruct through llama.cpp |
| 5 | Q8_0 | done; it did not help on this CPU | 
| 6 | Multi-turn + history trim | **done** - the plugin keeps turns and trims them |
| 7 | Memory management | partly - `-c 1024` caps the KV cache; end-to-end RSS still unmeasured |
| 8 | Packaging | `tools/deploy.ps1` done; a KPM package is still open |
| 9 | **Measure the chat model on the device** | the outstanding item |

Note on item 1: the whole probe was for drawing our own UI - the screen geometry,
which input device is the touchscreen, whether the native keyboard could be read.
Moving the interface into KOReader answered all three by construction, since
KOReader already knows its screen and brings its own keyboard. That is why the
probe is no longer on the critical path.

### 9. Measure the chat model on the device

Everything up to here is verified off-device: the ARM binary's ELF, the runner's
chat branch against a stub, and the whole plugin inside a real headless KOReader.
What has never run is `llama-completion` **on the Kindle**, with the real model.

Three numbers to get, all from one run:

- tok/s, to check the ~5 tok/s estimate;
- **model load time**, which is the unknown that matters most: the runner starts a
  fresh process per turn, so the ~101 MB have to come off flash every time. If
  that is slow, the fix is to keep the process alive and feed prompts over stdin
  (llama-completion reads further turns there), or to run `llama-server` and talk
  to it over HTTP;
- `MemAvailable` while it runs, to see how much of the 512 MB is left.

### 1. Device probe - the next step, and it is cheap

`tools/probe-device.sh` runs on the Kindle and answers what we still do not know:

- **the screen's real resolution** - `STREAM_LINE=8` and `STATUS_LINE=28` in `chat.conf` are
  my guess; I need the framebuffer's `virtual_size`
- **which `/dev/input/eventN` is the touch** and which axes it reports (`ABS_X/ABS_Y` or
  `ABS_MT_*`) - that is what defines the keyboard's hit-test
- **whether the native keyboard works** (`--kbd-test`), which decides half of Phase 2
- **available RAM** with the framework running: the app ran, but we never measured the RSS,
  so we do not know the real headroom

### 2. Chat UI (C + FBInk)

A single binary, with static `libfbink` (`make static KINDLE=1`), no IPC and no
`spawn` on every token.

- areas: conversation, input field, keyboard
- drawing: FBInk's `DRAW` primitives (rectangle/line) for the boxes and keys
- **regional** refresh (`-s top,left,width,height` with `-W GC16`) so as not to flicker the
  whole screen on every token
- the **streaming is already proven**: fbink does not buffer, so it is possible to draw
  token by token

### 3. Keyboard - the biggest UI risk

Two routes, and the probe decides which:

- **Native** - `com.lab126.keyboard` exposes writable `open`/`close` and readable `appID`/`preedit`.
  If it is possible to read the typed text, it saves half the work.
  **Not confirmed** - that is exactly what `--kbd-test` investigates.
- **Own** - a QWERTY drawn with FBInk plus hit-test on the tap coordinates.
  More work, 100% predictable.

### 4. Instruct model - done, by changing the runtime instead of fine-tuning

The earlier plan here was to fine-tune `stories15M` into an instruction-follower.
Working through the numbers killed that idea: a fine-tune of a 15M model trained
only on children's stories still has **no knowledge**, so it could follow "write a
story about a sad robot" and never answer "what is the capital of France". The
problem was never the training objective, it was the model.

So the model changed - SmolLM2-135M-Instruct, a real instruct model trained on 2T
tokens - and that forced the runtime to change with it (see
[Chat runtime](#chat-runtime-llamacpp)). The estimate is ~5 tok/s on this CPU;
**the device measurement is still outstanding**.

The old fine-tune path would also have needed torch, which is not installed here.
This path did not: llama.cpp builds with Zig.

### 5. Q8_0 - done, but it did not help on this hardware

Done without PyTorch, with our own converter (`tools/quantize.py`, self-verifying).
Measured on the KT4: **slower** than fp32 (5.5 versus 8.2 tok/s) due to a compiler
backend decision. See [Q8_0 without PyTorch](#q8_0-without-pytorch).

### 6. Multi-turn and history trim

The model's context is **256 tokens in total** - around 190 words of whole conversation.
This is the model's absolute ceiling, so deleting history is not an optimization,
it is a requirement:

- `CTX_MAX=256`, reserve `GEN_MAX` for the answer -> `PROMPT_BUDGET ~ 190`
- on each turn, discard the oldest pairs until they fit
- `run.c` **does not report** how many tokens the prompt consumed; it needs a patch
  to report `pos`, or counting on the UI side

### 7. Memory management

From the original request: read `MemAvailable` from `/proc/meminfo` and decide model/`STEPS`,
warning when it gets tight. A "no framework" mode would free ~100-150 MB, but there is a
catch: the app is launched by `appmgrd`, so stopping the framework takes down the parent.

### 8. Packaging

A KPM package (`;kpm install`). For day-to-day development the copy is already
scripted: `tools/deploy.ps1` finds the Kindle drive, copies both pairs and
verifies every file by hash.

### The torch blocker

It is left only for the **instruct fine-tune**. `export.py` only exports from a
PyTorch checkpoint (`stories15M.pt`), so training depends on Python + torch -
here we have Python 3.14 without torch, and torch usually has no wheel for 3.14.
Ways out:

- **a venv with Python 3.12 + torch** (~2-3 GB download)
- **train elsewhere** (Colab) and bring only the finished `.bin`

The Q8_0 **no longer** depends on that: `tools/quantize.py` does the conversion
straight from v0 fp32, without torch.

### Known limitations (they are not bugs)

- **256-token context** - ~190 words of whole conversation; the trim is mandatory.
- **3-4 year old child's English** - it is the TinyStories vocabulary.
- **No USB transfer with the app open** - scriptlet behavior.
- **`STREAM_LINE`/`STATUS_LINE` are guesses** until the probe confirms the resolution.

## License

MIT. See [LICENSE](../LICENSE). The vendored llama2.c sources under `vendor/`
(`run.c`, `runq.c`, `tokenizer.bin`) keep their own MIT license, from
[karpathy/llama2.c](https://github.com/karpathy/llama2.c).
