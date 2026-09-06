#!/usr/bin/env python3
"""Export the statically reviewed red-packet functions from the original 269624 sample."""
import argparse
import bisect
import hashlib
import json
from pathlib import Path
import struct

EXPECTED_SHA256 = "7cf3d4effabc96bdb23fd2da21486388cbcea5fa1f6dfd72a872e0deba60d601"
FUNCTIONS = {
    "message_network_constructor": 0x4949B84,
    "message_to_display": 0x494E760,
    "display_copy": 0x38AA58,
    "display_destroy": 0x38BC54,
    "app_context": 0x4316F84,
    "get_service": 0x421E59C,
    "request_registry": 0x40BD584,
    "receive_service": 0x40DD2CC,
    "open_service": 0x40DD2D4,
    "receive_factory": 0x40BDE00,
    "open_factory": 0x40BE1FC,
    "receive_body": 0x40C1594,
    "open_body": 0x40C7E2C,
    "subscribe": 0x4DDEA0,
    "subscribe_core": 0x4DECA0,
    "receive_callback": 0x4DFBB0,
    "open_callback": 0x1271970,
    "result_fields": 0x40D5DD8,
    "receive_result_fields": 0x40D65C8,
    "can_open_cover": 0x126FAE4,
}


def arm64(data):
    if data[:4] == b"\xca\xfe\xba\xbe":
        for i in range(struct.unpack_from(">I", data, 4)[0]):
            cpu, _, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + 20 * i)
            if cpu == 0x0100000C:
                data = data[offset:offset + size]
                break
    if hashlib.sha256(data).hexdigest() != EXPECTED_SHA256:
        raise ValueError("Expected the unmodified 269624 arm64 slice; sample hash does not match")
    return data


def function_starts(data):
    cursor = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, cursor)
        if command == 0x26:
            offset, length = struct.unpack_from("<II", data, cursor + 8)
            starts, value, shift, address = [], 0, 0, 0
            for byte in data[offset:offset + length]:
                value |= (byte & 127) << shift
                if byte & 128:
                    shift += 7
                    continue
                if not value:
                    return starts
                address += value
                starts.append(address)
                value = shift = 0
            return starts
        cursor += size
    raise ValueError("LC_FUNCTION_STARTS is missing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    data = arm64(args.binary.read_bytes())
    starts = function_starts(data)
    args.out.mkdir(parents=True, exist_ok=False)
    sample = args.out / "input-arm64.dylib"
    sample.write_bytes(data)

    import idapro
    import ida_auto
    import ida_bytes
    import ida_funcs
    import ida_hexrays
    import ida_lines
    import ida_ua
    import idc

    result = idapro.open_database(str(sample.resolve()), False, args="-c")
    if result:
        raise RuntimeError(f"IDA open_database failed: {result}")
    try:
        ida_auto.enable_auto(False)
        if not ida_hexrays.init_hexrays_plugin():
            raise RuntimeError("The arm64 Hex-Rays decompiler is unavailable")
        report = {"sha256": EXPECTED_SHA256, "ida_version": idapro.get_library_version(), "functions": {}}
        for name, start in FUNCTIONS.items():
            index = bisect.bisect_left(starts, start)
            if starts[index] != start:
                raise ValueError(f"Not a function start: {start:#x}")
            end = starts[index + 1]
            ida_funcs.del_func(start)
            ida_bytes.del_items(start, ida_bytes.DELIT_SIMPLE, end - start)
            for ea in range(start, end, 4):
                ida_ua.create_insn(ea)
            ida_funcs.add_func(start, end)
            ida_auto.enable_auto(True)
            ida_auto.plan_and_wait(start, end)
            ida_auto.enable_auto(False)
            assembly = "\n".join(f"{ea:#x}: {ida_lines.tag_remove(idc.generate_disasm_line(ea, 0) or '')}" for ea in range(start, end, 4))
            (args.out / f"{name}.asm").write_text(assembly)
            (args.out / f"{name}.c").write_text(str(ida_hexrays.decompile(start)))
            report["functions"][name] = {"start": hex(start), "end": hex(end), "entry": data[start:start + 12].hex()}
            print(f"Exported {name}: {start:#x}", flush=True)
        (args.out / "report.json").write_text(json.dumps(report, indent=2))
    finally:
        idapro.close_database(False)


if __name__ == "__main__":
    main()
