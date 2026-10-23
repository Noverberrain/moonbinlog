# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Exercise the native CLI as a subprocess, including real binlogs and failures."""

import argparse
from collections import Counter
import hashlib
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures" / "mysql-8.0"
DEFAULT_EXE = ROOT / "_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe"


def main(executable):
    cases = 0

    def run(args, code=0, cwd=ROOT):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=cwd,
                                capture_output=True, text=True, encoding="utf-8", timeout=20)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        if code == 0:
            assert result.stderr == "", result.stderr
        else:
            assert result.stderr.startswith("moonbinlog:"), result.stderr
            assert "summary\t" not in result.stdout, result.stdout
        return result

    def verify_report(result, raw, offsets, summary_only=False, off=False):
        lines = result.stdout.splitlines()
        if not summary_only:
            assert lines[0] == "offset\ttype\tname\tbytes\tnext_position\ttimestamp\tserver_id\tflags\tchecksum"
            rows = [line.split("\t") for line in lines[1:1 + len(offsets)]]
            assert len(rows) == len(offsets)
            assert [int(row[0]) for row in rows] == offsets
            for row, offset in zip(rows, offsets):
                assert int(row[1]) == raw[offset + 4]
                assert int(row[3]) == struct.unpack_from("<I", raw, offset + 9)[0]
                assert int(row[4]) == struct.unpack_from("<I", raw, offset + 13)[0]
                assert row[8] == ("OFF" if off and int(row[1]) != 15 else "CRC32")
            lines = lines[1 + len(offsets):]
        assert lines[0] == f"summary\tevents={len(offsets)}\tevent_bytes={len(raw) - 4}\tfile_bytes={len(raw)}"
        counts = Counter(raw[offset + 4] for offset in offsets)
        assert [int(line.split("\t")[1]) for line in lines[1:]] == sorted(counts)
        assert {int(line.split("\t")[1]): int(line.split("\t")[3]) for line in lines[1:]} == counts

    assert "Usage: moonbinlog" in run(["--help"]).stdout
    assert "Usage: moonbinlog" in run(["-h"]).stdout
    for args in [[], ["--unknown"], ["a", "b"], ["--summary", "--summary", "file"],
                 ["--max-event-bytes", "18", "file"], ["--max-file-bytes", "0", "file"],
                 ["--max-event-bytes", "4294967296", "file"], ["--summary"],
                 ["--max-event-bytes"], ["--max-file-bytes", "2147483648", "file"]]:
        result = run(args, code=2)
        assert result.stdout == ""
        assert "Usage: moonbinlog" in result.stderr

    full = (FIXTURES / "crc32-full.binlog").read_bytes()
    originals = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in FIXTURES.glob("*.binlog")}
    for name in ("crc32-full", "crc32-minimal", "off-full"):
        path = FIXTURES / f"{name}.binlog"
        raw = path.read_bytes()
        dump = (FIXTURES / f"{name}.mysqlbinlog.txt").read_bytes()
        offsets = [int(n) for n in re.findall(rb"^# at (\d+)\r?$", dump, re.M)]
        verify_report(run([path]), raw, offsets, off=name == "off-full")
        verify_report(run(["--summary", path]), raw, offsets, summary_only=True)

    build = ROOT / "_build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cli-cases-", dir=build) as directory:
        work = Path(directory)
        run([work / "missing.binlog"], code=1)
        run([work], code=1)
        for name, raw, error in [
            ("empty", b"", "TruncatedInput"),
            ("bad-magic", b"nope", "InvalidMagic"),
            ("magic-only", b"\xfebin", "MissingFormatDescription"),
            ("truncated-rotation", full[:-1], "TruncatedEvent"),
        ]:
            path = work / name
            path.write_bytes(raw)
            result = run(["--summary", path], code=1)
            assert error in result.stderr, result.stderr
            assert result.stdout == ""
        offsets = [int(n) for n in re.findall(rb"^# at (\d+)\r?$", (FIXTURES / "crc32-full.mysqlbinlog.txt").read_bytes(), re.M)]
        corrupt = bytearray(full)
        corrupt[offsets[5] + 19] ^= 1
        path = work / "corrupt.binlog"
        path.write_bytes(corrupt)
        for extra in [[], ["--summary"]]:
            result = run([*extra, path], code=1)
            assert "ChecksumMismatch" in result.stderr
            if extra:
                assert result.stdout == ""
            else:
                assert "\tFORMAT_DESCRIPTION_EVENT\t" in result.stdout

        path = FIXTURES / "crc32-full.binlog"
        run(["--summary", "--max-file-bytes", len(full), path])
        result = run(["--max-file-bytes", len(full) - 1, path], code=1)
        assert result.stdout == "" and "exceeds limit" in result.stderr
        result = run(["--summary", "--max-event-bytes", "121", path], code=1)
        assert result.stdout == "" and "EventTooLarge" in result.stderr
        result = run(["--summary", "--max-event-bytes", "388", path], code=1)
        assert result.stdout == "" and "EventTooLarge" in result.stderr
        run(["--summary", "--max-event-bytes", "389", path])

        unicode_path = work / "中文 空格.binlog"
        unicode_path.write_bytes(full)
        verify_report(run([unicode_path]), full, offsets)
        dash_path = work / "--summary"
        dash_path.write_bytes(full)
        verify_report(run(["--", "--summary"], cwd=work), full, offsets)

        # Unknown code in an OFF event is framed and counted, without decoding.
        unknown = bytearray((FIXTURES / "off-full.binlog").read_bytes())
        off_offsets = [int(n) for n in re.findall(rb"^# at (\d+)\r?$", (FIXTURES / "off-full.mysqlbinlog.txt").read_bytes(), re.M)]
        unknown[off_offsets[-1] + 4] = 255
        path = work / "unknown.binlog"
        path.write_bytes(unknown)
        result = run([path])
        assert "\t255\tUNKNOWN\t" in result.stdout
        assert "type\t255\tUNKNOWN\t1" in result.stdout
        verify_report(result, unknown, off_offsets, off=True)

    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in originals.items())
    print(f"Verified {cases} native CLI scenarios; input fixtures unchanged")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=DEFAULT_EXE)
    main(parser.parse_args().executable.resolve())
