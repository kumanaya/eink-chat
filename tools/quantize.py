#!/usr/bin/env python3
"""
Convert a llama2.c v0 (fp32) model into v2 (Q8_0) -- without PyTorch.

Why this exists: llama2.c's export.py only exports from a PyTorch checkpoint, so
producing a Q8_0 file the official way needs torch installed (~2-3 GB). But
stories15M.bin is already in the v0 fp32 format, and v0 -> v2 is just arithmetic
over binary blobs, so this script does it directly.

Both layouts were verified against both ends:
  - the writer: export.py (legacy_export and version2_export) from karpathy/llama2.c
  - the reader: runq.c::read_checkpoint + memory_map_weights

v0 layout (fp32):
  header: 7 int32 = dim, hidden_dim, n_layers, n_heads, n_kv_heads,
                    vocab_size, seq_len
          (a NEGATIVE vocab_size means a separate classifier, not shared)
  then, in this order, all fp32:
    tok_embeddings
    [rms_att] per layer           (one contiguous block)
    [wq] [wk] [wv] [wo]           (per layer, per tensor)
    [rms_ffn] per layer
    [w1] [w2] [w3] per layer
    rms_final
    freqs_cos, freqs_sin          (seq_len x head_size/2)
    wcls                          (only when the classifier is not shared)

v2 layout (Q8_0):
  256 byte header:
    uint32 magic 'ak42', int32 version=2, config (7 int32),
    uint8 shared_classifier, int32 group_size, zero padding up to 256
  then fp32: rms_att, rms_ffn, rms_final
  then, for every tensor: int8 q[n] followed by fp32 s[n/GS]
    tok_embeddings, wq, wk, wv, wo, w1, w2, w3, (wcls)

Usage:
  python tools/quantize.py model/stories15M.bin model/stories15M_q80.bin
  python tools/quantize.py input.bin output.bin --group-size 64

It works without numpy too (just slower); force the pure path with
KINDLE_NO_NUMPY=1 to test both.
"""

import array
import os
import struct
import sys

MAGIC = 0x616B3432
HEADER_SIZE = 256
Q_MAX = 127.0

CFG_NAMES = ["dim", "hidden_dim", "n_layers", "n_heads", "n_kv_heads",
             "vocab_size", "seq_len"]


# --------------------------------------------------------------------------
# optional numpy

def load_numpy():
    if os.environ.get("KINDLE_NO_NUMPY"):
        return None
    try:
        import numpy  # noqa: F401
        return numpy
    except ImportError:
        return None


NP = load_numpy()


# --------------------------------------------------------------------------
# reading v0

class ModelV0:
    """Reads the v0 header and computes the offset of every tensor."""

    def __init__(self, path):
        with open(path, "rb") as f:
            raw = f.read()

        if len(raw) < 28:
            raise ValueError("file too short to hold a header")

        cfg = struct.unpack_from("<7i", raw, 0)
        (self.dim, self.hidden_dim, self.n_layers, self.n_heads,
         self.n_kv_heads, vocab_signed, self.seq_len) = cfg

        # in v0 the sign of vocab_size flags a separate classifier
        self.vocab_size = abs(vocab_signed)
        self.shared_classifier = vocab_signed > 0
        self.head_size = self.dim // self.n_heads
        self.raw = raw
        self.size = len(raw)

        self.tensors = self._map()
        self._validate()

    def _map(self):
        """(label, offset_in_floats, element_count) in v0 order."""
        dim, hd, L = self.dim, self.hidden_dim, self.n_layers
        kv = self.n_kv_heads
        hs = self.head_size
        V, S = self.vocab_size, self.seq_len

        t = []
        off = 0

        def add(label, n):
            nonlocal off
            t.append((label, off, n))
            off += n

        add("tok_embeddings", V * dim)
        add("rms_att", L * dim)
        add("wq", L * dim * (self.n_heads * hs))
        add("wk", L * dim * (kv * hs))
        add("wv", L * dim * (kv * hs))
        add("wo", L * (self.n_heads * hs) * dim)
        add("rms_ffn", L * dim)
        add("w1", L * hd * dim)
        add("w2", L * dim * hd)
        add("w3", L * hd * dim)
        add("rms_final", dim)
        add("freqs_cos", S * (hs // 2))
        add("freqs_sin", S * (hs // 2))
        if not self.shared_classifier:
            add("wcls", V * dim)

        self.total_floats = off
        return t

    def _validate(self):
        expected = 28 + self.total_floats * 4
        if expected != self.size:
            raise ValueError(
                f"size mismatch: expected {expected} bytes "
                f"(28 header + {self.total_floats} floats), "
                f"file has {self.size}. "
                "Unrecognized v0 layout."
            )

    def offset(self, label):
        """(offset_in_floats, element_count) for a tensor."""
        for name, off, n in self.tensors:
            if name == label:
                return off, n
        raise KeyError(label)


# --------------------------------------------------------------------------
# quantization

def f32(x):
    """
    Force the value to float32 (Python computes in float64).

    Needed because the reference export.py divides in float32: without this the
    stdlib path produces different bytes than the numpy path for the same model
    -- both valid, but not reproducible.
    """
    return struct.unpack("<f", struct.pack("<f", x))[0]


def quantize(q_vals, gs):
    """
    Symmetric Q8_0 in groups of `gs`, matching export.py's quantize_q80 and
    runq.c's quantize(): scale = max|x| / 127, q = round(x/scale).

    Returns (int8_bytes, float32_scale_bytes).
    """
    n = len(q_vals)
    if n % gs != 0:
        raise ValueError(f"tensor of {n} elements is not a multiple of GS={gs}")

    if NP is not None:
        g = NP.asarray(q_vals, dtype=NP.float32).reshape(-1, gs)
        wmax = NP.abs(g).max(axis=1)
        scales = wmax / NP.float32(Q_MAX)
        safe = NP.where(scales == 0, NP.float32(1.0), scales)
        q = NP.rint(g / safe[:, None]).astype(NP.int8)
        return q.tobytes(), scales.astype("<f4").tobytes()

    # stdlib path: no dependency, ~11s for the 15M model, identical output
    scales = array.array("f")
    out = bytearray(n)
    for base in range(0, n, gs):
        group = q_vals[base:base + gs]
        wmax = 0.0
        for v in group:
            a = -v if v < 0 else v
            if a > wmax:
                wmax = a
        scale = f32(wmax / Q_MAX)
        scales.append(scale)
        div = scale if scale != 0 else 1.0
        for i, v in enumerate(group):
            # float32 + round half to even, matching torch.round
            integer = int(round(f32(v / div)))
            if integer > 127:
                integer = 127
            elif integer < -127:
                integer = -127
            out[base + i] = integer & 0xFF
    if sys.byteorder != "little":
        scales.byteswap()
    return bytes(out), scales.tobytes()


def read_floats(raw, off, n):
    """Slice of floats from the file. With numpy, avoids an intermediate copy."""
    start = 28 + off * 4
    if NP is not None:
        return NP.frombuffer(raw, dtype="<f4", count=n, offset=start)
    return array.array("f", raw[start:start + n * 4])


def v2_plan(m, gs):
    """
    The blocks of the v2 quantized section, in EXACT file order.

    Subtle point: for tensors that exist once per layer, the file is NOT
    "all the int8 first, then all the scales". runq.c's init_quantized_tensors
    (and export.py's loop) write, per layer, the int8 values and immediately
    after them that layer's scales:

        q(layer0) s(layer0) q(layer1) s(layer1) ...

    Getting this wrong does not change the file size and runq.c still loads it
    without complaining -- it just produces garbage, because it reads the scales
    from the wrong place.

    Returns [(label, layer_index, offset_in_source_floats, n)].
    """
    L = m.n_layers
    hs = m.head_size
    plan = []

    def add(label, n_sub, size_each):
        off, total = m.offset(label)
        if total != n_sub * size_each:
            raise ValueError(
                f"{label}: {total} elements, but v2 expects "
                f"{n_sub} x {size_each} = {n_sub * size_each}")
        for k in range(n_sub):
            plan.append((label, k, off + k * size_each, size_each))

    add("tok_embeddings", 1, m.vocab_size * m.dim)
    add("wq", L, m.dim * (m.n_heads * hs))
    add("wk", L, m.dim * (m.n_kv_heads * hs))
    add("wv", L, m.dim * (m.n_kv_heads * hs))
    add("wo", L, (m.n_heads * hs) * m.dim)
    add("w1", L, m.dim * m.hidden_dim)
    add("w2", L, m.hidden_dim * m.dim)
    add("w3", L, m.dim * m.hidden_dim)
    if not m.shared_classifier:
        add("wcls", 1, m.dim * m.vocab_size)
    return plan


def dequantize(qb, sb, gs):
    """Rebuild float32 from the int8 values + scales (what runq.c does)."""
    if NP is not None:
        q = NP.frombuffer(qb, dtype=NP.int8).astype(NP.float32)
        s = NP.frombuffer(sb, dtype="<f4")
        return q * NP.repeat(s, gs)
    q = array.array("b", qb)
    s = array.array("f", sb)
    return array.array("f", [q[i] * s[i // gs] for i in range(len(q))])


def verify(out_path, m, gs, plan):
    """
    Read our own output back following runq.c's layout and compare it with the
    source. If the block order were wrong, the error here would explode.
    """
    worst = 0.0
    worst_where = ""
    with open(out_path, "rb") as f:
        f.seek(HEADER_SIZE + (m.n_layers * m.dim * 2 + m.dim) * 4)
        for label, k, off, n in plan:
            qb = f.read(n)
            sb = f.read((n // gs) * 4)
            if len(qb) != n or len(sb) != (n // gs) * 4:
                raise ValueError(f"file ended early at block {label}[{k}]")
            orig = read_floats(m.raw, off, n)
            recon = dequantize(qb, sb, gs)
            if NP is not None:
                err = float(NP.abs(recon - orig.astype(NP.float32)).max())
            else:
                err = max(abs(recon[i] - orig[i]) for i in range(n))
            if err > worst:
                worst, worst_where = err, f"{label}[{k}]"

        leftover = len(f.read(1))
    if leftover != 0:
        raise ValueError("bytes left at the end: the layout is larger than expected")

    print()
    print(f"verification (reread using runq.c's layout): "
          f"max error {worst:.6f} at {worst_where}")
    return worst


# --------------------------------------------------------------------------

def convert(src, dst, gs_requested=64):
    m = ModelV0(src)

    gs = gs_requested
    while m.dim % gs != 0:
        gs //= 2
        if gs < 1:
            raise ValueError("could not find a valid group size")

    print(f"source : {src}")
    print(f"  dim={m.dim} hidden={m.hidden_dim} layers={m.n_layers} "
          f"heads={m.n_heads}/{m.n_kv_heads} vocab={m.vocab_size} "
          f"seq={m.seq_len}")
    print(f"  classifier: "
          f"{'shared' if m.shared_classifier else 'SEPARATE'}")
    print(f"  {m.total_floats} floats = {m.size} bytes")
    if gs != gs_requested:
        print(f"  group size: {gs_requested} -> {gs} (dim is not a multiple)")
    print(f"group  : {gs}")
    print(f"engine : "
          f"{'numpy ' + NP.__version__ if NP is not None else 'stdlib (no numpy)'}")

    with open(dst, "wb") as out:
        # --- 256 byte header ---
        out.write(struct.pack("<I", MAGIC))
        out.write(struct.pack("<i", 2))
        out.write(struct.pack("<7i", m.dim, m.hidden_dim, m.n_layers,
                              m.n_heads, m.n_kv_heads, m.vocab_size, m.seq_len))
        out.write(struct.pack("<B", int(m.shared_classifier)))
        out.write(struct.pack("<i", gs))
        written = out.tell()
        assert written <= HEADER_SIZE
        out.write(b"\0" * (HEADER_SIZE - written))

        # --- fp32: the norms, in this order (same as runq.c) ---
        for label in ("rms_att", "rms_ffn", "rms_final"):
            off, n = m.offset(label)
            out.write(read_floats(m.raw, off, n).tobytes())

        # --- quantized ---
        plan = v2_plan(m, gs)
        worst = (0.0, "")
        for label, k, off, n in plan:
            vals = read_floats(m.raw, off, n)
            qb, sb = quantize(vals, gs)
            out.write(qb)
            out.write(sb)
            err = max_error(vals, qb, sb, gs)
            if err > worst[0]:
                worst = (err, f"{label}[{k}]")
            shown = label if k == 0 else f"{label}[{k}]"
            print(f"  {shown:18} n={n:>9}  max error={err:.6f}")

    # --- check against runq.c ---
    # (outside the `with`: the file must be closed/flushed to disk)
    worst_round_trip = verify(dst, m, gs, plan)

    size = os.path.getsize(dst)
    print()
    print(f"output : {dst}")
    print(f"  {size} bytes ({size / 1024 / 1024:.2f} MB)")
    print(f"  compression: {m.size / size:.2f}x")
    print(f"  worst quantization error: {worst[0]:.6f} ({worst[1]})")
    print(f"  round-trip (read back via the v2 layout): {worst_round_trip:.6f}")
    return size


def max_error(orig, qb, sb, gs):
    """Worst reconstruction error, as a sanity check (expected ~1e-3)."""
    n = len(orig)
    if NP is not None:
        q = NP.frombuffer(qb, dtype=NP.int8)
        s = NP.frombuffer(sb, dtype="<f4")
        recon = q.astype(NP.float32) * NP.repeat(s, gs)
        return float(NP.abs(recon - orig.astype(NP.float32)).max())
    q = array.array("b", qb)
    s = array.array("f", sb)
    worst = 0.0
    for i in range(n):
        d = abs(q[i] * s[i // gs] - orig[i])
        if d > worst:
            worst = d
    return worst


def main():
    args = list(sys.argv[1:])
    gs = 64
    if "--group-size" in args:
        i = args.index("--group-size")
        gs = int(args[i + 1])
        del args[i:i + 2]

    if len(args) != 2:
        print(__doc__)
        return 2

    src, dst = args
    if not os.path.exists(src):
        print(f"error: does not exist: {src}", file=sys.stderr)
        return 1

    convert(src, dst, gs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
