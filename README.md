<h1 align="center">E-INK CHAT</h1>

<p align="center">
  <strong>An offline chat that runs entirely on the Kindle.</strong><br />
  Nothing leaves the device.
</p>

---

Two modes, picked by what is installed on the device:

| | model | runtime | what it does |
|---|---|---|---|
| **chat** | SmolLM2-135M-Instruct, Q4_K_M (101 MB) | **llama.cpp** | you ask a question, it answers |
| story | TinyStories 15M | **llama2.c** | continues a story — a base model, so it cannot answer |

`kindlechat.koplugin/` is the interface: a KOReader plugin, so the keyboard,
the scrolling and the e-ink refresh are KOReader's own. `kindlechat/` is the
app it drives, deployed to `/mnt/us/extensions/kindlechat`.

Status: story mode measured **8.2 tok/s on a KT4**. Chat mode is built,
deployed and running; its speed on the device is the outstanding measurement.

## Layout

```
kindlechat/             the app: scriptlet, builds and model tooling (MIT)
kindlechat.koplugin/    the chat UI as a KOReader plugin (AGPL-3.0)
```

## Start

- Build and install the app: [kindlechat/README.md](kindlechat/README.md)
- Install the plugin:

  ```sh
  cp -r kindlechat.koplugin /path/to/koreader/plugins/
  ```

- Exercise the plugin with no Kindle around (uses the `dev-tools` folder from
  the [e-ink-hack](https://github.com/kumanaya/e-ink-hack) workshop):

  ```sh
  sh ../dev-tools/koreader-headless.sh kindlechat.koplugin kindlechat.koplugin/tests/koreader-probe.lua
  ```

## License

MIT for the app ([kindlechat/LICENSE](kindlechat/LICENSE)), AGPL-3.0 for the
plugin ([kindlechat.koplugin/LICENSE](kindlechat.koplugin/LICENSE)). The
vendored llama2.c sources under `kindlechat/vendor/` keep their own MIT
license.
