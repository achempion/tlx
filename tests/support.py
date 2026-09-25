"""Isolated Docker relay and daemon processes shared by integration tests."""

import os
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TIMEOUT = 30


def rows(database, sql, parameters=()):
    with closing(sqlite3.connect(database, timeout=5)) as connection:
        return connection.execute(sql, parameters).fetchall()


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def make_key(path):
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path))
    return path.with_suffix(".pub").read_text().split()[1]


class LocalTlx:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tlx-test-")
        self.directory = Path(self.temp.name)
        self.container = "tlx-test-" + uuid.uuid4().hex[:12]
        self.processes, self.keys, self.public_keys, self.databases = {}, {}, {}, {}
        self.last_claimed_at = 0

    def __enter__(self):
        try:
            self.start()
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, error_type, *_):
        if error_type is not None:
            for log in self.directory.glob("*.log"):
                print(f"{log.name}:\n{log.read_text(errors='replace')[-4000:]}", file=sys.stderr)
        self.close()

    def close(self):
        for name in list(self.processes):
            self.stop_daemon(name)
        if shutil.which("docker"):
            subprocess.run(["docker", "rm", "-f", self.container], capture_output=True, timeout=15)
        self.temp.cleanup()

    def start(self):
        for program in ("docker", "ssh", "ssh-keygen", "ssh-keyscan", "age"):
            if shutil.which(program) is None:
                raise RuntimeError(f"missing required program: {program}")
        for name in ("alice", "bobx"):
            directory = self.directory / name
            directory.mkdir()
            self.keys[name] = directory / "key"
            self.public_keys[name] = make_key(self.keys[name])
            self.databases[name] = directory / "tlxd.db"

        run("docker", "build", "-q", "-t", "tlx-relay:test", str(ROOT))
        run("docker", "run", "--rm", "-d", "--name", self.container,
            "-p", "127.0.0.1::22", "-e", "TLX_MEMBERS=" + " ".join(self.public_keys.values()), "tlx-relay:test")
        self.port = int(run("docker", "port", self.container, "22/tcp").stdout.strip().rsplit(":", 1)[1])
        known_hosts = self.directory / "known_hosts"

        def host_key():
            return subprocess.run(["ssh-keyscan", "-T", "2", "-p", str(self.port), "127.0.0.1"],
                                  capture_output=True, timeout=5).stdout

        known_hosts.write_bytes(self.wait(host_key, "relay host key"))
        bin_dir = self.directory / "bin"
        bin_dir.mkdir()
        self.ssh_offline = self.directory / "ssh-offline"
        self.ssh_attempts = self.directory / "ssh-attempts"
        wrapper = bin_dir / "ssh"
        wrapper.write_text("#!/bin/sh\n"
                           f"if [ -e {shlex.quote(str(self.ssh_offline))} ]; then\n"
                           f"  printf '%s\\n' \"$*\" >> {shlex.quote(str(self.ssh_attempts))}\n"
                           "  exit 255\nfi\n"
                           "exec /usr/bin/ssh -F /dev/null "
                           f"-o UserKnownHostsFile={shlex.quote(str(known_hosts))} "
                           "-o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes \"$@\"\n")
        wrapper.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
        for name in self.keys:
            self.start_daemon(name)

    def start_daemon(self, name):
        with (self.directory / f"{name}.log").open("ab") as log:
            self.processes[name] = subprocess.Popen(
                [sys.executable, "-u", str(ROOT / "tlxd.py"), "--host", "127.0.0.1",
                 "--port", str(self.port), "--dir", str(self.directory / name)],
                env=self.environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)

        def ready():
            try:
                rows(self.databases[name], "select count(*) from outbox")
                return True
            except sqlite3.OperationalError:
                return False

        self.wait(ready, f"{name} database initialization")

    def stop_daemon(self, name):
        process = self.processes.pop(name)
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)

    def wait(self, condition, description):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            for name, process in self.processes.items():
                if process.poll() is not None:
                    raise AssertionError(f"{name} exited with {process.returncode} while waiting for {description}")
            result = condition()
            if result:
                return result
            time.sleep(0.05)
        raise TimeoutError(f"waiting for {description}")

    def enqueue(self, sender, chat_id, body, recipients=None):
        self.last_claimed_at = stamp = max(time.time_ns(), self.last_claimed_at + 1)
        with closing(sqlite3.connect(self.databases[sender], timeout=5)) as connection, connection:
            connection.execute("insert into outbox (claimed_at, chat_id, recipient_public_keys, body) values (?, ?, ?, ?)",
                               (stamp, chat_id, " ".join(recipients) if recipients is not None else None, body))
        return stamp

    def ssh(self, key, *command, data=b""):
        return subprocess.run(
            ["ssh", "-o", "User=tlx", "-o", f"Port={self.port}", "-o", f"IdentityFile={key}",
             "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "127.0.0.1", *command],
            input=data, capture_output=True, env=self.environment, timeout=10)
