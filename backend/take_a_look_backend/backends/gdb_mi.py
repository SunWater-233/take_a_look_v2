"""Remote target access through an installed GDB's machine interface."""
from __future__ import annotations

import os
import queue
import re
import shutil
import subprocess
import threading
import time
from typing import Any

from pygdbmi.gdbmiparser import parse_response


def normalize_host(value: str) -> str:
    host = value.strip()
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    if not re.fullmatch(r"[A-Za-z0-9._:%-]+", host):
        raise ValueError("请填写有效的 IP 或主机名，端口请单独填写。")
    return host


def find_gdb(configured: str = "") -> str:
    requested = configured.strip() or os.environ.get("TAKE_A_LOOK_GDB", "").strip()
    if requested:
        resolved = shutil.which(requested)
        if resolved:
            return resolved
        raise ValueError("找不到配置的 GDB 可执行文件。")
    for name in ("arm-none-eabi-gdb", "gdb-multiarch", "gdb"):
        if resolved := shutil.which(name):
            return resolved
    raise ValueError("请安装对应目标架构的 GDB，并填写 GDB 可执行文件路径。")


class GdbTarget:
    """MI commands are serialized by BackendService; async stops are queued."""

    def __init__(self, host: str, port: int, executable: str = "", *, timeout: float = 5.0) -> None:
        host = normalize_host(host)
        self.timeout = timeout
        self._token = 0
        self._state = "unknown"
        self._breakpoints: dict[int, str] = {}
        self._register_names: list[str] = []
        self._messages: queue.Queue[dict[str, Any] | None] = queue.Queue(maxsize=256)
        self._closed = threading.Event()
        self._process = subprocess.Popen(
            [find_gdb(executable), "--nx", "--quiet", "--interpreter=mi3"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        self._reader = threading.Thread(target=self._read, name="tal-gdb-mi", daemon=True)
        self._reader.start()
        try:
            self._request("-gdb-set pagination off")
            self._request("-gdb-set confirm off")
            self._request("-gdb-set mi-async on")
            self._request("-gdb-set remotetimeout 3")
            address = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
            self._request(f"-target-select remote {address}")
            info = self._request("-thread-info")
            threads = info.get("threads", [])
            self._state = "running" if any(t.get("state") == "running" for t in threads) else "halted"
        except Exception:
            self.abort()
            raise

    def _read(self) -> None:
        assert self._process.stdout is not None
        try:
            while not self._closed.is_set():
                line = self._process.stdout.readline(1024 * 1024 + 1)
                if not line or len(line) > 1024 * 1024:
                    break
                try:
                    record = parse_response(line.decode("utf-8", "replace").strip())
                except Exception:
                    continue
                if record.get("type") in {"result", "notify"}:
                    self._messages.put(record, timeout=1)
        except (OSError, ValueError, queue.Full):
            # A stalled consumer must not create an unbounded MI output queue.
            if self._process.poll() is None:
                self._process.kill()
        finally:
            try:
                self._messages.put_nowait(None)
            except queue.Full:
                pass

    def _consume(self, record: dict[str, Any] | None) -> None:
        if record is None:
            self._state = "unavailable"
            raise ConnectionError("GDB 进程已退出，请检查可执行文件和远程服务后重新连接。")
        message = record.get("message")
        if record.get("type") == "notify":
            if message == "running":
                self._state = "running"
            elif message == "stopped":
                reason = (record.get("payload") or {}).get("reason", "")
                self._state = "unavailable" if str(reason).startswith("exited") else "halted"
            elif message == "thread-group-exited":
                self._state = "unavailable"

    def _request(self, command: str) -> dict[str, Any]:
        if self._closed.is_set():
            raise ConnectionError("GDB 连接已关闭。")
        self._token += 1
        token = self._token
        assert self._process.stdin is not None
        try:
            self._process.stdin.write(f"{token}{command}\n".encode("utf-8"))
            self._process.stdin.flush()
            deadline = time.monotonic() + self.timeout
            while True:
                record = self._messages.get(timeout=max(0.001, deadline - time.monotonic()))
                self._consume(record)
                assert record is not None
                if record.get("type") == "result" and record.get("token") == token:
                    payload = record.get("payload") or {}
                    if record.get("message") == "error":
                        raise RuntimeError(f"GDB: {payload.get('msg', '命令失败')}")
                    return payload
                if time.monotonic() >= deadline:
                    raise queue.Empty
        except (queue.Empty, BrokenPipeError, OSError) as error:
            self.abort()
            raise ConnectionError("GDB 响应超时或连接中断；未自动重发操作，请重新连接。") from error

    def get_state(self) -> str:
        while True:
            try:
                self._consume(self._messages.get_nowait())
            except queue.Empty:
                break
        if self._process.poll() is not None or self._state == "unavailable":
            raise ConnectionError("GDB 进程或远程目标连接已退出。")
        return self._state

    def _require_halted(self) -> None:
        if self.get_state() != "halted":
            raise RuntimeError("此 GDB 连接使用全停模式，请先暂停目标；运行时采样请使用 RTT。")

    def _wait_halted(self) -> None:
        deadline = time.monotonic() + self.timeout
        while self.get_state() != "halted":
            try:
                record = self._messages.get(timeout=max(0.001, deadline - time.monotonic()))
            except queue.Empty as error:
                self.abort()
                raise TimeoutError("等待 GDB 停止通知超时，请重新连接。") from error
            self._consume(record)
            if time.monotonic() >= deadline:
                self.abort()
                raise TimeoutError("等待 GDB 停止通知超时，请重新连接。")

    def halt(self) -> None:
        if self.get_state() != "halted":
            self._request("-exec-interrupt --all")
            self._wait_halted()

    def resume(self) -> None:
        if self.get_state() == "running":
            return
        self._request("-exec-continue")
        self._state = "running"

    def step(self) -> None:
        self._require_halted()
        self._state = "running"
        try:
            self._request("-exec-step-instruction")
        except RuntimeError:
            self._state = "halted"
            raise
        self._wait_halted()

    def reset_and_halt(self) -> None:
        self.halt()
        self._request('-interpreter-exec console "monitor reset halt"')
        self._request('-interpreter-exec console "maintenance flush register-cache"')
        self._state = "halted"

    def reset(self) -> None:
        self.reset_and_halt()
        self.resume()

    def read_memory_block8(self, address: int, size: int) -> bytes:
        self._require_halted()
        result = self._request(f"-data-read-memory-bytes 0x{address:x} {size}")
        data = bytearray()
        for block in result.get("memory", []):
            if int(block["begin"], 16) != address + len(data):
                raise RuntimeError("GDB 返回了不连续的内存数据。")
            data.extend(bytes.fromhex(block["contents"]))
        if len(data) != size:
            raise RuntimeError("GDB 未返回完整的内存数据。")
        return bytes(data)

    def write_memory_block8(self, address: int, values: list[int]) -> None:
        self._require_halted()
        self._request(f"-data-write-memory-bytes 0x{address:x} {bytes(values).hex()}")

    def read_core_registers_raw(self, names: list[str]) -> list[int]:
        self._require_halted()
        if not self._register_names:
            self._register_names = self._request("-data-list-register-names")["register-names"]
        indices = []
        for name in names:
            aliases = {"sp": ("sp", "r13"), "lr": ("lr", "r14"), "pc": ("pc", "r15"),
                       "xpsr": ("xpsr", "cpsr")}.get(name, (name,))
            index = next((self._register_names.index(alias) for alias in aliases if alias in self._register_names), None)
            if index is None:
                raise RuntimeError(f"GDB 目标未提供寄存器 {name}，请使用适合目标架构的 GDB。")
            indices.append(index)
        values = self._request("-data-list-register-values x " + " ".join(map(str, indices)))
        mapped = {int(item["number"]): int(item["value"], 0) for item in values["register-values"]}
        return [mapped[index] for index in indices]

    def set_breakpoint(self, address: int) -> bool:
        if address not in self._breakpoints:
            result = self._request(f"-break-insert -h *0x{address:x}")
            self._breakpoints[address] = str(result["bkpt"]["number"])
        return True

    def remove_breakpoint(self, address: int) -> None:
        if number := self._breakpoints.get(address):
            self._request(f"-break-delete {number}")
            del self._breakpoints[address]

    def close(self) -> None:
        try:
            if not self._closed.is_set() and self._process.poll() is None:
                self.halt()
                self._request("-target-detach")
        finally:
            self.abort()

    def abort(self) -> None:
        self._closed.set()
        if self._process.poll() is None:
            self._process.kill()
        self._process.wait(timeout=2)
        if threading.current_thread() is not self._reader:
            self._reader.join(timeout=2)
        for handle in (self._process.stdin, self._process.stdout):
            if handle is not None:
                handle.close()
