# Which model can actually be a chat on a KT4

Research notes, so the numbers do not have to be rediscovered.

## The constraint is memory bandwidth, not FLOPs

This is the part that is easy to get wrong, and I did: extrapolating from the
15M model's speed by counting multiply-accumulates suggested a 135M model would
run at ~1 tok/s, which made the whole idea look pointless.

Generation of a quantized model is **bandwidth bound**: for every token, the
whole model has to be read from memory. So the useful estimate is

    tok/s  ~=  effective bandwidth  /  model size

We have the bandwidth measured on the actual device. The 15M fp32 model is
57.9 MB and ran at 8.2 tok/s:

    57.9 MB x 8.2 tok/s  =  ~476 MB/s effective

Cross-check: a documented setup runs SmolLM2-135M-Instruct Q4_K_M on a Raspberry
Pi Zero 2W (512 MB, ~1 GB/s) at 9-11 tok/s. 102 MB x 10 = ~1 GB/s. The model
above holds.

That is why the quantization matters so much here: Q4 moves a quarter of the
bytes, so it roughly quadruples the speed over fp32 on the same CPU.

## The candidates, with real sizes

Sizes are the actual `.gguf` files on Hugging Face, and tok/s is the estimate
above at 476 MB/s.

| model | Q4 size | est. tok/s | 50-token answer | license | arch |
|---|---|---|---|---|---|
| **SmolLM2-135M-Instruct** | **88-101 MB** | **~4.7-5.4** | **~10 s** | Apache 2.0, not gated | Llama |
| Gemma-3-270M-IT | 230-241 MB | ~2.0 | ~25 s | Gemma, **gated** | Gemma3 |
| SmolLM2-360M-Instruct | 219-258 MB | ~1.8-2.2 | ~25 s | Apache 2.0 | Llama |
| Qwen2.5-0.5B-Instruct | 469 MB | ~1.0 | ~50 s | Apache 2.0 | Qwen2 |

Notes that matter beyond the table:

- **Qwen2.5-0.5B does not fit.** 469 MB of a 512 MB device, before the KV cache
  and before KOReader itself. Ruled out by arithmetic, not by preference.
- **Gemma-3-270M has the best instruction following at this size** (IFEval 51.2,
  which beats SmolLM2-135M and Qwen2.5-0.5B), and a 32K context. But it is gated
  behind manual license acceptance, and it is twice as slow.
- **SmolLM2-135M-Instruct is a real instruct model**: trained on 2T tokens of
  web, math and instruction data, not only stories. It answers questions. Its
  limits are real too - 2048 token context, no tool calling, and anything beyond
  simple reasoning or arithmetic is unreliable.

## What this means

A usable chat on the KT4 is achievable at **~5 tok/s with SmolLM2-135M-Instruct
Q4_K_M** - about a 10 second wait for a short reply. Not fast, but a real
question-and-answer assistant, which is what the current TinyStories model can
never be: that one is a base model trained only on children's stories, so it
continues text and has no knowledge to answer with.

## The runtime has to change

`llama2.c` cannot run these:

- its `tokenizer.bin` format is SentencePiece-based, and SmolLM2 uses GPT-2 BPE;
- a 135M model in fp32 is 540 MB, which does not fit in 512 MB - and the Q8_0
  path is the only quantized option `llama2.c` has, which measured *slower* than
  fp32 on this CPU.

So a chat model means **llama.cpp**, which handles GGUF, quantized kernels and
the tokenizer natively. Its integer NEON kernels also matter here: LLVM refuses
to use NEON for floating point on this CPU's target (`neonfp` is off), so the
scalar fp32 path in `llama2.c` is leaving the hardware idle, while integer
kernels can use NEON.

**The open question is whether llama.cpp cross-compiles for
`arm-linux-musleabihf`.** That is the next thing to verify, before any of the
above is worth relying on.

If it builds, the KOReader plugin barely changes: the UI, the engine and the
history trim stay, and only the runner (`run-model.sh`) swaps which binary it
calls - plus a real chat template, since an instruct model needs
`<|im_start|>user ... <|im_end|>`-style framing rather than raw continuation.
