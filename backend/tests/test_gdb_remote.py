"""Exercise the real MI process against a deterministic Cortex-M RSP server.

Set TAKE_A_LOOK_TEST_GDB to an installed ARM GDB to enable these integration tests.
The fake target never touches a physical MCU or probe.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import struct
import socket
import threading
import time
from contextlib import contextmanager

import pytest

from take_a_look_backend.backends.gdb_mi import GdbTarget, find_gdb, normalize_host
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import EventName, RpcMethod, ProtocolError
from take_a_look_backend.service import BackendService
from test_ember_remote import Phone, phone_server


class CortexMServer:
    def __init__(self, *, flash=False, fail_flash=False, corrupt=False) -> None:
        self.flash = flash
        self.fail_flash = fail_flash
        self.corrupt = corrupt
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.listener.settimeout(0.1)
        self.stop = threading.Event()
        self.socket: socket.socket | None = None
        self.commands: list[str] = []
        self.registers = [0] * 17
        self.registers[13] = 0x20010000
        self.registers[15] = 0x08000100
        self.registers[16] = 0x01000000
        self.memory = {0x20000000: 42}
        self.breakpoints: set[int] = set()
        self.worker = threading.Thread(target=self.run, daemon=True)
        self.worker.start()

    def xml(self) -> str:
        registers = "".join(f'<reg name="r{i}" bitsize="32" type="uint32"/>' for i in range(13))
        return ('<?xml version="1.0"?><!DOCTYPE target SYSTEM "gdb-target.dtd">'
                '<target><architecture>arm</architecture><feature name="org.gnu.gdb.arm.m-profile">'
                + registers + '<reg name="sp" bitsize="32" type="data_ptr"/>'
                '<reg name="lr" bitsize="32"/><reg name="pc" bitsize="32" type="code_ptr"/>'
                '<reg name="xpsr" bitsize="32" regnum="25"/></feature></target>')

    def reply(self, data: str) -> None:
        assert self.socket is not None
        payload = data.encode()
        checksum = sum(payload) & 255
        self.socket.sendall(b"$" + payload + f"#{checksum:02x}".encode())

    def dispatch(self, command: str) -> str | None:
        self.commands.append(command)
        if command.startswith("qSupported"):
            return "PacketSize=4000;qXfer:features:read+;hwbreak+" + (";qXfer:memory-map:read+" if self.flash else "")
        if self.flash and command.startswith("qXfer:memory-map:read::"):
            offset, length = (int(v, 16) for v in command.rsplit(":", 1)[1].split(","))
            xml = ('<?xml version="1.0"?><!DOCTYPE memory-map SYSTEM "memory-map.dtd"><memory-map>'
                '<memory type="flash" start="0x08000000" length="0x10000"><property name="blocksize">0x100</property></memory>'
                '<memory type="ram" start="0x20000000" length="0x1000"/></memory-map>')
            return ("l" if offset + length >= len(xml) else "m") + xml[offset:offset + length]
        if command.startswith("vFlashErase:"):
            address, size = (int(v, 16) for v in command.split(":")[1].split(","))
            self.memory.update({address + i: 255 for i in range(size)})
            return "OK"
        if command.startswith("vFlashWrite:"):
            _, address, data = command.split(":", 2)
            self.memory.update({int(address, 16) + i: value for i, value in enumerate(data.encode('latin1'))})
            return "OK"
        if command == "vFlashDone":
            if self.corrupt:
                self.memory[0x08000000] ^= 255
            return "E01" if self.fail_flash else "OK"
        if command.startswith("qXfer:features:read:target.xml:"):
            offset, length = (int(v, 16) for v in command.rsplit(":", 1)[1].split(","))
            xml = self.xml()
            return ("l" if offset + length >= len(xml) else "m") + xml[offset:offset + length]
        if command == "?":
            return "T05thread:1;"
        if command == "qfThreadInfo":
            return "m1"
        if command == "qsThreadInfo":
            return "l"
        if command == "qC":
            return "QC1"
        if command.startswith("qAttached"):
            return "1"
        if command.startswith(("H", "T", "qSymbol")):
            return "OK"
        if command == "g":
            return b"".join(v.to_bytes(4, "little") for v in self.registers).hex()
        if command.startswith("p"):
            number = int(command[1:], 16)
            return self.registers[16 if number == 25 else number].to_bytes(4, "little").hex()
        if command.startswith("m"):
            address, size = (int(v, 16) for v in command[1:].split(","))
            return bytes(self.memory.get(address + i, 0) for i in range(size)).hex()
        if command.startswith("M"):
            header, data = command[1:].split(":")
            address, count = (int(v, 16) for v in header.split(","))
            decoded = bytes.fromhex(data)
            assert len(decoded) == count
            self.memory.update({address + i: value for i, value in enumerate(decoded)})
            return "OK"
        if command.startswith("X"):
            header, data = command[1:].split(":", 1)
            address, count = (int(v, 16) for v in header.split(","))
            decoded = data.encode('latin1')
            assert len(decoded) == count
            self.memory.update({address + i: value for i, value in enumerate(decoded)})
            return "OK"
        if command.startswith("P"):
            number, value = command[1:].split("=")
            self.registers[int(number, 16)] = int.from_bytes(bytes.fromhex(value), 'little')
            return "OK"
        if command.startswith(("Z1,", "z1,")):
            address = int(command.split(",")[1], 16)
            if command[0] == "Z":
                self.breakpoints.add(address)
            else:
                self.breakpoints.discard(address)
            return "OK"
        if command.startswith("qRcmd,"):
            monitor = bytes.fromhex(command.split(",")[1]).decode()
            if monitor == "reset halt":
                self.registers[15] = 0x08000000
                return "OK"
            return "E01"
        if command.startswith("s") or command == "vCont;s:1;c":
            self.registers[15] += 2
            return "T05thread:1;"
        if command.startswith("c"):
            return None
        if command.startswith("D"):
            return "OK"
        return ""

    def run(self) -> None:
        try:
            while not self.stop.is_set():
                try:
                    self.socket, _ = self.listener.accept()
                    break
                except socket.timeout:
                    pass
            if self.socket is None:
                return
            self.socket.settimeout(0.1)
            buffer = bytearray()
            while not self.stop.is_set():
                try:
                    data = self.socket.recv(65536)
                except socket.timeout:
                    continue
                if not data:
                    return
                buffer.extend(data)
                while buffer:
                    if buffer[0] in b"+-":
                        del buffer[0]
                    elif buffer[0] == 3:
                        del buffer[0]
                        self.reply("T02thread:1;")
                    elif buffer[0] == ord("$"):
                        end = buffer.find(b"#")
                        if end < 0 or len(buffer) < end + 3:
                            break
                        packet = bytes(buffer[1:end])
                        decoded, cursor = bytearray(), 0
                        while cursor < len(packet):
                            value = packet[cursor]
                            if value == ord('}'):
                                cursor += 1
                                value = packet[cursor] ^ 0x20
                            decoded.append(value)
                            cursor += 1
                        command = decoded.decode("latin1")
                        del buffer[:end + 3]
                        self.socket.sendall(b"+")
                        response = self.dispatch(command)
                        if response is not None:
                            self.reply(response)
                    else:
                        raise AssertionError(bytes(buffer))
        except OSError:
            if not self.stop.is_set():
                raise

    def close(self) -> None:
        self.stop.set()
        if self.socket is not None:
            self.socket.close()
        self.listener.close()
        self.worker.join(timeout=2)


@contextmanager
def arm_remote():
    executable = os.environ.get("TAKE_A_LOOK_TEST_GDB")
    if not executable:
        pytest.skip("Set TAKE_A_LOOK_TEST_GDB to run against a real ARM GDB process")
    server = CortexMServer()
    try:
        yield executable, server
    finally:
        server.close()


def test_gdb_path_error_is_actionable():
    with pytest.raises(ValueError, match="GDB"):
        find_gdb("this-gdb-program-does-not-exist")


def test_host_rejects_gdb_pipe_transport_and_embedded_commands():
    for value in ("|command", "host\n-exec-run", 'host"', "localhost 3333"):
        with pytest.raises(ValueError):
            normalize_host(value)
    assert normalize_host("[::1]") == "::1"


def test_real_gdb_reports_a_lost_remote_target():
    with arm_remote() as (executable, server):
        target = GdbTarget("127.0.0.1", server.port, executable)
        try:
            target.resume()
            assert server.socket is not None
            server.stop.set()
            server.socket.shutdown(socket.SHUT_RDWR)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    target.get_state()
                except ConnectionError:
                    break
                time.sleep(0.01)
            else:
                pytest.fail("GDB did not report the lost remote connection")
        finally:
            target.abort()


def test_real_arm_gdb_memory_registers_breakpoint_run_step_reset_and_detach():
    with arm_remote() as (executable, server):
        backend = RemoteMemoryBackend("gdb", {"host": "127.0.0.1", "gdbPort": str(server.port), "gdbPath": executable})
        backend.connect()
        target: GdbTarget = backend.target
        try:
            assert backend.debug_state() == "halted"
            assert backend.read_core_registers()["pc"] == 0x08000100
            symbol = SymbolInfo("counter", 0x20000000, 4, "uint32_t", ".data")
            assert backend.read_symbol(symbol) == 42
            assert backend.write_symbol(symbol, "100") == 100
            assert backend.set_breakpoint(0x08000200)
            backend.resume()
            with pytest.raises(RuntimeError, match="暂停"):
                backend.read_symbol(symbol)
            backend.halt()
            assert backend.debug_state() == "halted"
            backend.remove_breakpoint(0x08000200)
            pc = backend.read_core_registers()["pc"]
            backend.step()
            assert backend.read_core_registers()["pc"] == pc + 2
            backend.reset(halt=True)
            assert backend.read_core_registers()["pc"] == 0x08000000
        finally:
            backend.disconnect()
        assert target._process.poll() is not None
        assert not target._reader.is_alive()
        assert any(command.startswith("D") for command in server.commands)
        assert any(command.startswith("Z1,") for command in server.commands)
        assert not server.breakpoints


def test_ember_private_rtt_and_real_gdb_run_together(tmp_path):
    with arm_remote() as (executable, server):
        phone = Phone()
        events = []
        with phone_server(phone) as options:
            options.update(gdbPort=str(server.port), gdbPath=executable)
            symbol = SymbolInfo("counter", 0x20000000, 4, "uint32_t", ".data")
            service = BackendService(lambda event, payload: events.append((event, payload)),
                                     symbol_loader=lambda _, **_kwargs: [symbol])
            try:
                path = tmp_path / "test.axf"
                path.write_bytes(b"fake elf; symbol loader is injected")
                service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(path)})
                service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": symbol.key}]})
                state = service.handle(RpcMethod.CONNECT, {
                    "connectionKind": "emberGdb", "remoteConfig": options,
                })["state"]
                assert state["debug"]["executionState"] == "halted"
                assert service.state_snapshot()["watches"][0]["value"] == 42
                service.handle(RpcMethod.DEBUG_CONTROL, {"action": "resume"})
                service.handle(RpcMethod.SET_RTT, {"enabled": True, "protocol": "normal"})
                deadline = time.monotonic() + 3
                while not service._normal_rtt.is_started and time.monotonic() < deadline:
                    time.sleep(.01)
                assert service._normal_rtt.symbols
                service.handle(RpcMethod.SET_WATCHES, {'watches': [
                    {'key': item.key, 'readMode': 'capture'} for item in service._normal_rtt.symbols]})
                phone.data += struct.pack('<If', 2000, 2.5)
                deadline = time.monotonic() + 3
                while not any(event == EventName.SAMPLES for event, _ in events) and time.monotonic() < deadline:
                    time.sleep(0.01)
                frames = [payload["frames"] for event, payload in events if event == EventName.SAMPLES]
                assert frames and list(frames[0][0]["values"].values()) == [2.5]
                assert not any(method in {"read_memory", "debug_status", "read_registers"} for method, _ in phone.calls)
                service.handle(RpcMethod.DEBUG_CONTROL, {"action": "halt"})
                assert service.state_snapshot()["debug"]["executionState"] == "halted"
                service.handle(RpcMethod.DISCONNECT, {})
                assert not phone.gdb["running"]
                assert not phone.rtt_running
            finally:
                service.close()


@pytest.fixture(scope='module')
def arm_firmware(tmp_path_factory):
    executable = os.environ.get('TAKE_A_LOOK_TEST_GDB')
    if not executable:
        pytest.skip('Set TAKE_A_LOOK_TEST_GDB for real GDB download tests')
    compiler = Path(executable).with_name('arm-none-eabi-gcc.exe' if os.name == 'nt' else 'arm-none-eabi-gcc')
    if not compiler.is_file():
        pytest.skip('ARM GCC next to the selected GDB is needed to create the fixture')
    root = tmp_path_factory.mktemp('gdb firmware')
    source, script, output = root / 'app.c', root / 'app.ld', root / '固件 app.axf'
    source.write_text('volatile unsigned counter = 0x7d23242a; void Reset_Handler(void) { for (;;) { counter++; } }')
    script.write_text('''ENTRY(Reset_Handler)
MEMORY { FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 64K
RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 4K }
SECTIONS { .text : { *(.text*) *(.rodata*) } > FLASH
.data : { *(.data*) } > RAM AT> FLASH
.bss (NOLOAD) : { *(.bss*) *(COMMON) } > RAM }
''')
    subprocess.run([str(compiler), '-nostdlib', '-mcpu=cortex-m3', '-mthumb', '-g', '-Wl,--build-id=none',
                    '-T', str(script), str(source), '-o', str(output)], check=True, capture_output=True)
    return executable, output


@pytest.mark.parametrize('failure', ['', 'commit', 'readback'])
def test_real_ember_gdb_downloads_flash_and_verifies_lma_sections(arm_firmware, failure):
    from take_a_look_backend.backends.remote_firmware import firmware_image
    executable, path = arm_firmware
    server = CortexMServer(flash=True, fail_flash=failure == 'commit', corrupt=failure == 'readback')
    backend = RemoteMemoryBackend('emberGdb', {})
    target = GdbTarget('127.0.0.1', server.port, executable)
    backend.target = target
    try:
        progress = []
        if failure:
            with pytest.raises((RuntimeError, ProtocolError)):
                backend.program_firmware(str(path), progress.append)
            assert 1 not in progress
        else:
            backend.program_firmware(str(path), progress.append)
            assert progress[-1] == 1
            _, sections = firmware_image(str(path))
            assert len(sections) >= 2  # Includes initialized RAM at its flash LMA.
            for address, content in sections:
                assert bytes(server.memory.get(address + i, 0) for i in range(len(content))) == content
        assert 'vFlashDone' in server.commands
        assert not any(command.startswith('c') for command in server.commands)
    finally:
        target.close()
        server.close()
