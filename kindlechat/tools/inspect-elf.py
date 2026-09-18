#!/usr/bin/env python3
"""Inspect the generated ELF to confirm it will run on the Kindle (ARMv7, hard-float, static)."""
import struct
import sys

# ARM EABI flags
EABIMASK = 0xFF000000
EABI_VER5 = 0x05000000
ABI_FLOAT_HARD = 0x00000400
ABI_FLOAT_SOFT = 0x00000200

PT_NAMES = {1: "LOAD", 2: "DYNAMIC", 3: "INTERP", 4: "NOTE", 6: "PHDR",
            7: "TLS", 0x6474e550: "GNU_EH_FRAME", 0x6474e551: "GNU_STACK",
            0x6474e552: "GNU_RELRO"}

MACHINES = {40: "ARM", 183: "AArch64", 62: "x86-64", 3: "x86"}


def check(path, expect_machine=40):
    d = open(path, "rb").read()
    ok = True

    def line(label, value, good=None):
        nonlocal ok
        mark = ""
        if good is True:
            mark = "  OK"
        elif good is False:
            mark = "  <-- PROBLEM"
            ok = False
        print(f"  {label:<26}{value}{mark}")

    print(f"=== {path} ===")
    print(f"  size: {len(d)} bytes ({len(d)/1024/1024:.2f} MB)")
    print()

    if d[:4] != b"\x7fELF":
        print("  not an ELF file")
        return False

    ei_class, ei_data = d[4], d[5]
    line("class", "32-bit" if ei_class == 1 else f"{32*(2**ei_class)}-bit", ei_class == 1)
    line("endianness", "little" if ei_data == 1 else "big", ei_data == 1)

    (e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags,
     e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx) = \
        struct.unpack_from("<HHIIIIIHHHHHH", d, 16)

    line("machine", f"{e_machine} ({MACHINES.get(e_machine, '?')})", e_machine == expect_machine)
    line("type", {1: "REL (object)", 2: "EXEC", 3: "DYN (PIE)"}.get(e_type, e_type))

    eabi = e_flags & EABIMASK
    abi = e_flags & 0xFF00
    line("e_flags", f"0x{e_flags:08x}")
    line("EABI", {EABI_VER5: "VER5"}.get(eabi, f"0x{eabi:08x}"), eabi == EABI_VER5)
    if abi == ABI_FLOAT_HARD:
        line("float ABI", "hard-float", True)
    elif abi == ABI_FLOAT_SOFT:
        line("float ABI", "soft-float (a hard-float Kindle will NOT run this)", False)
    else:
        line("float ABI", f"0x{abi:04x} (unspecified)", None)

    # program headers
    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, _, _, _, _, _, p_flags, _ = struct.unpack_from("<IIIIIIII", d, off)
        phdrs.append((p_type, p_flags))

    types = [p[0] for p in phdrs]
    names = [PT_NAMES.get(t, hex(t)) for t in types]
    line("program headers", ", ".join(names))

    has_interp = 3 in types
    line("needs a loader?", "n/a" if not has_interp else "it will look for one", not has_interp)
    # a static binary has no PT_INTERP
    line("self-contained", "yes (no PT_INTERP)" if not has_interp else "NO", not has_interp)

    if 4 in types:
        line("NOTE", "present (build-id/ABI tag)")

    print()
    print("  RESULT:", "runs on the Kindle" if ok else "will NOT run")
    return ok


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "llama"
    sys.exit(0 if check(target) else 1)
