<h1 align="center">E-INK CHAT</h1>

<p align="center">
  <strong>An offline chat that runs entirely on the Kindle.</strong><br />
  Nothing leaves the device.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Kindle-e--ink-111111?style=flat-square" alt="Kindle" />
  <img src="https://img.shields.io/badge/llama2.c-story-6b6b6b?style=flat-square" alt="llama2.c story mode" />
  <img src="https://img.shields.io/badge/llama.cpp-chat-6b6b6b?style=flat-square" alt="llama.cpp chat mode" />
  <img src="https://img.shields.io/badge/GTK%203-native%20window-6b6b6b?style=flat-square" alt="GTK 3 native window" />
  <img src="https://img.shields.io/badge/License-MIT%20%2B%20AGPL--3.0-yellow.svg?style=flat-square" alt="MIT + AGPL-3.0" />
</p>

<p align="center">
  <a href="#on-the-kindle">On the Kindle</a>
  ·
  <a href="#on-your-desk">On your desk</a>
  ·
  <a href="#the-native-window">The native window</a>
  ·
  <a href="#the-two-modes">The two modes</a>
  ·
  <a href="#make-it-yours">Make it yours</a>
  ·
  <a href="#community">Community</a>
</p>

---

Two modes, picked by what is installed on the device:

| | model | runtime | what it does |
|---|---|---|---|
| **chat** | SmolLM2-135M-Instruct, Q4_K_M (101 MB) | **llama.cpp** | you ask a question, it answers |
| story | TinyStories 15M | **llama2.c** | continues a story — a base model, so it cannot answer |

The interface is `kindlechat.koplugin/`: a KOReader plugin, so the keyboard,
the scrolling and the e-ink refresh are KOReader's own. The app it drives is
the rest of this repository, deployed to `/mnt/us/extensions/kindlechat`.
There is also a KOReader-free window — `chat-ui.c`, a GTK app with its own
keyboard — see [The native window](#the-native-window).

Status: story mode measured **8.2 tok/s on a KT4**. Chat mode is built,
deployed and running; its speed on the device is the outstanding measurement.
The long story, with the numbers and the dead ends, is in
[docs/engineering.md](docs/engineering.md).

> [!NOTE]
> A house project of **E-INK HACK**. The workshop is on
> [Discord](https://discord.gg/KYChSeuyk) — Kindle, Kobo, any e-ink panel.

---

## On the Kindle

### The app

Copy over USB:

```
chat.sh                    →  /mnt/us/documents/chat.sh
chat.conf                  →  /mnt/us/extensions/kindlechat/chat.conf
out/llama                  →  /mnt/us/extensions/kindlechat/llama
model/stories15M.bin       →  /mnt/us/extensions/kindlechat/model/stories15M.bin
vendor/tokenizer.bin       →  /mnt/us/extensions/kindlechat/model/tokenizer.bin
```

Eject. It shows up as **E-INK HACK**; tap to open, tap again to go back. If a
file is missing, the scriptlet itself shows an error screen explaining what.
`tools/deploy.ps1` does the same copy and verifies every file by hash.

### The chat UI

```sh
cp -r kindlechat.koplugin /path/to/koreader/plugins/
```

Restart KOReader, then **Tools → E-INK HACK**. The plugin starts the runner
under `/mnt/us/extensions/kindlechat` and polls the output back onto the
screen.

### The native window

`chat-ui` is a GTK window that talks to `llama-server` directly: no KOReader.

```
out/chat-ui-kindle  →  /mnt/us/extensions/kindlechat/chat-ui
chat-ui.sh          →  /mnt/us/documents/chat-ui.sh
```

Eject. It shows up as **E-INK HACK CHAT**. The window is GTK over the X server
the framework already runs, so the transcript, the scrolling and the keyboard
are ordinary widgets; the answer streams in as chat bubbles while the model
writes. It starts and stops `llama-server` itself when nothing is listening on
`127.0.0.1:8080`, and brings its own QWERTY (with shift and backspace). To use
the framework's keyboard instead, start it once with `--native-keyboard`.

Build the binary with `sh tools/build-chatui.sh --kindle` — the script prints
the koxtoolchain steps when the cross compiler is missing.

### Chat mode

Two files are large enough to stay out of the repository: the runner and the
`gguf` model. Put them next to the app and the plugin starts answering
questions instead of continuing stories:

```
llama-completion                        →  /mnt/us/extensions/kindlechat/llama-completion
model/SmolLM2-135M-Instruct-Q4_K_M.gguf →  /mnt/us/extensions/kindlechat/model/
```

## On your desk

Dependencies (llama2.c sources + TinyStories 15M, ~58 MB):

```sh
sh tools/fetch.sh                # or, on Windows: .\tools\fetch.ps1
WITH_CHAT=1 sh tools/fetch.sh    # + SmolLM2-135M-Instruct Q4_K_M (~101 MB)
```

Build with Zig — no WSL, no Docker, no toolchain:

```sh
./build.sh                       # -> out/llama
SRC=runq.c ./build.sh            # -> out/llama-q8 (quantized model)
```

On Windows: `.\build.ps1` (or `.\build.ps1 -Src runq.c`). The build ends by
checking the ELF: ARM, EABI5, hard-float, self-contained.

Try it on the PC before copying:

```sh
TARGET=host ./build.sh
./out/llama model/stories15M.bin -z vendor/tokenizer.bin -n 80 -i "Once upon a time"
```

Tests, with no Kindle around:

```sh
sh tests/functional.sh                  # chat.sh against a fake llama
sh kindlechat.koplugin/tests/test-run-model.sh
cd kindlechat.koplugin/tests && lua test_engine.lua
```

And inside a real headless KOReader (uses the `dev-tools` folder from the
[e-ink-hack](https://github.com/kumanaya/e-ink-hack) workshop):

```sh
sh ../dev-tools/koreader-headless.sh kindlechat.koplugin kindlechat.koplugin/tests/koreader-probe.lua
```

The native window is a GTK app, built and tested apart (needs the GTK 3
development files):

```sh
sh tools/build-chatui.sh          # -> out/chat-ui
sh tests/chatui-smoke.sh          # parsing tests + a headless window run
./out/chat-ui                     # starts llama-server itself when it finds a .gguf
```

## The two modes

| | story | chat |
|---|---|---|
| Model | TinyStories 15M, base | SmolLM2-135M-Instruct, Q4_K_M |
| Runtime | llama2.c (`out/llama`) | llama.cpp (`llama-completion`) |
| Context | 256 tokens | 1024 tokens (`-c 1024`) |
| Prompt | plain continuation | ChatML template |
| Needs | binary + `stories15M.bin` | binary + a `.gguf` |

The plugin picks chat mode when it finds a `.gguf` and `llama-completion`,
and falls back to the story mode otherwise.

Why llama.cpp for chat: llama2.c's tokenizer is SentencePiece-based and every
small instruct model uses BPE; a 135M model in fp32 does not fit in the
512 MB; and llama.cpp's integer kernels use NEON, which is exactly what the
compiler refuses to do for floating point on this CPU. The numbers are in
[docs/engineering.md](docs/engineering.md) and
[docs/model-choice.md](docs/model-choice.md).

## Make it yours

Everything in `chat.conf` (it is shell, loaded with `.`):

| Key | Default | What it does |
|---|---|---|
| `PROMPT` | `Once upon a time, there was a little robot` | Text sent to the model |
| `STEPS` | `80` | Tokens to generate (prompt + steps within the context) |
| `TEMP` / `TOPP` | `0.8` / `0.9` | Sampling |
| `STREAM_LINE` | `8` | Line where the generated text starts |
| `STATUS_LINE` | `28` | Status line (tok/s) |
| `MAX_WAIT` | `600` | Cap on waiting for the tap, in seconds |

The layout is guessed for the KT4's 800x600 panel; adjust `STREAM_LINE` and
`STATUS_LINE` if text runs off the screen. `chat.sh` prefers the fp32 pair on
purpose (it measured faster); uncomment `BIN`/`MODEL` in `chat.conf` to force
the Q8_0 pair.

The native window has its own knobs (`./out/chat-ui --help`): `--font-size`,
`--max-turns` (messages kept in the request), `--no-spawn`, `--server-bin`,
`--server-args` and `--refresh-cmd` (an e-ink housekeeping command run after
each answer).

---

<h2 align="center">Community</h2>

<p align="center">
  A house project of <strong>E-INK HACK</strong>.<br />
  Kindle, Kobo, or anything with a slow, honest screen — bring the hack.
</p>

<p align="center">
  <a href="https://discord.gg/KYChSeuyk">
    <img src="https://invidget.switchblade.xyz/KYChSeuyk" alt="Join the E-INK HACK Discord" />
  </a>
</p>

<table align="center">
  <tr>
    <td align="center" width="220">
      <a href="https://discord.gg/KYChSeuyk">
        <img src="https://img.shields.io/badge/Discord-join%20the%20workshop-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord" /><br />
        <sub>Where the hacks land</sub>
      </a>
    </td>
    <td align="center" width="220">
      <a href="https://github.com/kumanaya/eink-chat">
        <img src="https://img.shields.io/badge/GitHub-eink--chat-181717?style=for-the-badge&logo=github" alt="GitHub" /><br />
        <sub>This chat</sub>
      </a>
    </td>
    <td align="center" width="220">
      <a href="https://x.com/danielkumanaya">
        <img src="https://img.shields.io/badge/X-danielkumanaya-000000?style=for-the-badge&logo=x&logoColor=white" alt="X" /><br />
        <sub>What we are shipping</sub>
      </a>
    </td>
  </tr>
</table>

---

MIT for the app, AGPL-3.0 for the plugin. See [LICENSE](LICENSE) and
[kindlechat.koplugin/LICENSE](kindlechat.koplugin/LICENSE). The vendored
llama2.c sources under `vendor/` keep their own MIT license, from
[karpathy/llama2.c](https://github.com/karpathy/llama2.c).
