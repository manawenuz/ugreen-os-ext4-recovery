#!/usr/bin/env python3
"""
disasm_kernel_function.py — disassemble a named function out of an
unstripped Linux .ko module.

Usage:
  ./disasm_kernel_function.py <module.ko> <symbol> [--bytes N]
  ./disasm_kernel_function.py <module.ko> --list <pattern>

Used to compare UGOS's modified btrfs.ko against mainline btrfs source
without leaving the terminal.
"""
import argparse
import re
import sys

from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection
from capstone import Cs, CS_ARCH_X86, CS_MODE_64


def find_symbol(elf, name):
    for section in elf.iter_sections():
        if not isinstance(section, SymbolTableSection):
            continue
        for sym in section.iter_symbols():
            if sym.name == name:
                return sym
    return None


def list_symbols(elf, pattern):
    rx = re.compile(pattern)
    out = []
    for section in elf.iter_sections():
        if not isinstance(section, SymbolTableSection):
            continue
        for sym in section.iter_symbols():
            if sym.name and rx.search(sym.name):
                if sym.entry["st_info"]["type"] == "STT_FUNC":
                    size = sym.entry["st_size"]
                    out.append((sym.name, sym.entry["st_value"], size))
    return sorted(out)


def get_section_bytes(elf, shndx):
    section = elf.get_section(shndx)
    return section.data(), section["sh_addr"]


def disasm_function(path, name, max_bytes):
    with open(path, "rb") as fh:
        elf = ELFFile(fh)
        sym = find_symbol(elf, name)
        if sym is None:
            print(f"symbol not found: {name}", file=sys.stderr)
            return 2
        st_value = sym.entry["st_value"]
        st_size = sym.entry["st_size"]
        if max_bytes:
            st_size = min(st_size, max_bytes) if st_size else max_bytes
        shndx = sym.entry["st_shndx"]
        if shndx in ("SHN_UNDEF", "SHN_ABS", "SHN_COMMON"):
            print(f"symbol {name} has no section ({shndx})", file=sys.stderr)
            return 2
        section_bytes, section_addr = get_section_bytes(elf, shndx)
        func_offset = st_value - section_addr
        if func_offset < 0 or func_offset >= len(section_bytes):
            print(f"symbol offset out of section", file=sys.stderr)
            return 2
        if st_size == 0:
            # No size info; grab a reasonable chunk.
            st_size = min(0x400, len(section_bytes) - func_offset)
        func_bytes = section_bytes[func_offset:func_offset + st_size]

        md = Cs(CS_ARCH_X86, CS_MODE_64)
        md.detail = False
        print(f"# {name}  (size=0x{st_size:x}, section_offset=0x{func_offset:x})")
        for ins in md.disasm(func_bytes, st_value):
            print(f"  {ins.address:08x}  {ins.bytes.hex():<24} {ins.mnemonic:<8} {ins.op_str}")
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("module")
    ap.add_argument("target", nargs="?")
    ap.add_argument("--list", metavar="REGEX")
    ap.add_argument("--bytes", type=int, default=0,
                    help="Cap on bytes to disassemble (default: full symbol).")
    args = ap.parse_args()

    if args.list:
        with open(args.module, "rb") as fh:
            elf = ELFFile(fh)
            for name, addr, size in list_symbols(elf, args.list):
                print(f"{addr:016x}  size=0x{size:x}  {name}")
        return 0
    if not args.target:
        print("provide a symbol name, or use --list <regex>", file=sys.stderr)
        return 2
    return disasm_function(args.module, args.target, args.bytes)


if __name__ == "__main__":
    sys.exit(main())
