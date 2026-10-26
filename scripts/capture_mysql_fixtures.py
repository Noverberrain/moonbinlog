# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Capture real binlogs using a disposable MySQL 8.0 instance, never a service."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "fixtures" / "mysql-8.0"


def run(command, **kwargs):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=120, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def capture(mysql_bin, destination=DEST):
    dest = destination.resolve()
    suffix = ".exe" if os.name == "nt" else ""
    tools = {name: str(mysql_bin / (name + suffix))
             for name in ("mysqld", "mysql", "mysqlbinlog", "mysqladmin")}
    version = run([tools["mysqld"], "--no-defaults", "--version"]).decode().strip()
    if "Ver 8.0." not in version:
        raise ValueError("This fixture suite requires MySQL 8.0.x")
    # Never inherit the installed service's datadir, options, port or credentials.
    # MySQL's Windows launcher can misparse non-ASCII datadir paths.
    build = Path(tempfile.gettempdir()) / "moonbinlog-integration"
    build.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="mysql-capture-", dir=build)).resolve()
    data = work / "data"
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    client = ["--no-defaults", "--protocol=TCP", "--host=127.0.0.1",
              f"--port={port}", "--user=root", "--connect-timeout=2"]
    server = None
    stopped = False
    try:
        run([tools["mysqld"], "--no-defaults", "--initialize-insecure",
             f"--basedir={mysql_bin.parent}", f"--datadir={data}", "--console"])
        with (work / "server.log").open("wb") as log:
            flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
            server = subprocess.Popen([
                tools["mysqld"], "--no-defaults", f"--basedir={mysql_bin.parent}",
                f"--datadir={data}", "--bind-address=127.0.0.1", f"--port={port}",
                "--mysqlx=OFF", "--server-id=810043", f"--log-bin={data / 'capture'}",
                "--binlog-format=ROW", "--binlog-row-metadata=FULL",
                "--binlog-transaction-compression=OFF", "--gtid-mode=OFF",
                "--innodb-buffer-pool-size=32M", "--console",
                *(["--no-monitor"] if os.name == "nt" else []),
            ], stdout=log, stderr=subprocess.STDOUT, creationflags=flags)
            deadline = time.monotonic() + 60
            while True:
                if server.poll() is not None:
                    raise RuntimeError((work / "server.log").read_text(errors="replace"))
                try:
                    run([tools["mysqladmin"], *client, "ping"])
                    break
                except RuntimeError:
                    if time.monotonic() > deadline:
                        raise TimeoutError(f"MySQL startup timed out; see {work / 'server.log'}")
                    time.sleep(0.25)

            def sql(statement):
                return run([tools["mysql"], *client, "--batch", "--skip-column-names",
                            "--default-character-set=utf8mb4"],
                           input=statement.encode("utf-8")).decode("utf-8")

            setup = (dest / "schema.sql").read_text(encoding="utf-8")
            workload = (dest / "workload.sql").read_text(encoding="utf-8")
            sql("SET SESSION sql_log_bin=0;" + setup)
            dest.mkdir(parents=True, exist_ok=True)
            manifest = {"server_version": version,
                        "mysqlbinlog_version": run([tools["mysqlbinlog"], "--version"]).decode().strip(),
                        "schema_sha256": hashlib.sha256(setup.encode()).hexdigest(),
                        "workload_sha256": hashlib.sha256(workload.encode()).hexdigest(),
                        "gtid_mode": "OFF", "binlog_format": "ROW",
                        "binlog_row_metadata": "FULL", "profiles": {}}
            for name, checksum, image in [("crc32-full", "CRC32", "FULL"),
                                          ("crc32-minimal", "CRC32", "MINIMAL"),
                                          ("off-full", "NONE", "FULL")]:
                # Restore only this isolated table, without logging setup/deletes.
                sql("SET SESSION sql_log_bin=0; DELETE FROM moonbinlog_fixture.sample;")
                sql(f"SET GLOBAL binlog_checksum='{checksum}'; FLUSH BINARY LOGS;")
                filename = sql("SHOW MASTER STATUS;").split("\t")[0]
                sql(f"SET SESSION binlog_row_image='{image}';" + workload)
                final_rows = sql("SELECT id, text_value IS NULL FROM moonbinlog_fixture.sample ORDER BY id;")
                if final_rows.strip() != "2\t1":
                    raise AssertionError(f"unexpected committed database state: {final_rows!r}")
                sql("FLUSH BINARY LOGS;")
                raw = (data / filename).read_bytes()
                dump = run([tools["mysqlbinlog"], "--no-defaults", "--verify-binlog-checksum",
                            "--base64-output=DECODE-ROWS", "--verbose", "--verbose",
                            str(data / filename)])
                # mysqlbinlog output is evidence, not executable input to this harness.
                (dest / f"{name}.binlog").write_bytes(raw)
                (dest / f"{name}.mysqlbinlog.txt").write_bytes(dump)
                manifest["profiles"][name] = {
                    "checksum": checksum, "row_image": image, "bytes": len(raw),
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "oracle_sha256": hashlib.sha256(dump).hexdigest(),
                    "final_rows": final_rows.strip(),
                }
            (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            run([tools["mysqladmin"], *client, "shutdown"])
            server.wait(timeout=30)
            stopped = True
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            server.wait(timeout=30)
        # Only remove our own generated instance after an orderly successful run.
        if stopped and work.parent == build.resolve() and work.name.startswith("mysql-capture-"):
            shutil.rmtree(work)
        else:
            print(f"Retained diagnostic directory: {work}")
    print(f"Captured three profiles from {version}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mysql-bin", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=DEST)
    args = parser.parse_args()
    capture(args.mysql_bin.resolve(), args.output_dir)
