"""Writes a classic BPF seccomp program that stops the sandboxed command from
creating user namespaces. bwrap loads it with --add-seccomp-fd after its own
setup, so only the untrusted command and its children are filtered.

clone and unshare with CLONE_NEWUSER fail with EPERM, clone3 fails with
ENOSYS (its flags live in memory seccomp cannot read; libc falls back to
clone), and other architectures or the x32 ABI fail with ENOSYS.

Usage: python3 deny-userns-filter.py OUTPUT
"""
import struct
import sys

LD_W_ABS, JEQ_K, JSET_K, RET_K = 0x20, 0x15, 0x45, 0x06
ALLOW = 0x7FFF0000
EPERM = 0x00050000 | 1
ENOSYS = 0x00050000 | 38
CLONE_NEWUSER = 0x10000000
X32_BIT = 0x40000000
ARCHES = {
    0xC000003E: {"clone": 56, "unshare": 272, "clone3": 435, "x32": True},
    0xC00000B7: {"clone": 220, "unshare": 97, "clone3": 435, "x32": False},
}


def program():
    code = [("ld", 4)]
    for arch in ARCHES:
        code.append(("jeq", arch, f"arch_{arch:x}"))
    code.append(("ret", ENOSYS))
    for arch, nrs in ARCHES.items():
        code.append(("label", f"arch_{arch:x}"))
        code.append(("ld", 0))
        if nrs["x32"]:
            code.append(("jset", X32_BIT, "nosys"))
        code.append(("jeq", nrs["clone3"], "nosys"))
        code.append(("jeq", nrs["clone"], "flags"))
        code.append(("jeq", nrs["unshare"], "flags"))
        code.append(("ret", ALLOW))
    code += [("label", "flags"), ("ld", 16), ("jset", CLONE_NEWUSER, "eperm"), ("ret", ALLOW),
             ("label", "eperm"), ("ret", EPERM), ("label", "nosys"), ("ret", ENOSYS)]

    labels, pc = {}, 0
    for op in code:
        if op[0] == "label":
            labels[op[1]] = pc
        else:
            pc += 1
    out, pc = [], 0
    for op in code:
        if op[0] == "label":
            continue
        if op[0] == "ld":
            out.append((LD_W_ABS, 0, 0, op[1]))
        elif op[0] == "ret":
            out.append((RET_K, 0, 0, op[1]))
        else:
            jump = labels[op[2]] - pc - 1
            if not 0 <= jump < 256:
                raise ValueError("jump out of range")
            out.append((JEQ_K if op[0] == "jeq" else JSET_K, jump, 0, op[1]))
        pc += 1
    return b"".join(struct.pack("<HBBI", *insn) for insn in out)


with open(sys.argv[1], "wb") as f:
    f.write(program())
