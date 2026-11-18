"""Debug state and breakpoint lifecycle; callers serialize target access.

This object owns no worker or lock. BackendService keeps the shared probe lock
around these operations, so sampling, downloads and debug control stay ordered.
"""
from __future__ import annotations

from time import monotonic, sleep

from take_a_look_backend.backends.target_backend import TargetBackend
from take_a_look_backend.services.debug_info import DebugInfoIndex
from take_a_look_backend.services.source_stepping import thumb_call_return


SOURCE_STEP_ACTIONS = frozenset({'stepIn', 'stepOver', 'stepOut'})
_SOURCE_STEP_TIMEOUT = 3.0
_SOURCE_STEP_LIMIT = 256


class DebugSession:
    def __init__(self) -> None:
        self.info = DebugInfoIndex()
        self.requested_breakpoints: dict[str, set[int]] = {}
        self.resolved_breakpoints: list[dict[str, object]] = []
        self.execution_state = "unavailable"
        self.stopped_location: dict[str, object] | None = None
        self.registers: dict[str, int] = {}

    def set_breakpoints(self, path: str, lines: list[int], target: TargetBackend, *, connected: bool) -> None:
        canonical_path = self.info.canonical_source_path(path) or path
        canonical_key = canonical_path.replace("\\", "/").rstrip("/").casefold()
        # DWARF paths and source-root mappings can identify the same file.
        for existing_path in list(self.requested_breakpoints):
            existing = self.info.canonical_source_path(existing_path) or existing_path
            if existing.replace("\\", "/").rstrip("/").casefold() == canonical_key:
                del self.requested_breakpoints[existing_path]
        if lines:
            self.requested_breakpoints[canonical_path] = set(lines)
        self.apply_breakpoints(target, connected=connected)

    def refresh(self, target: TargetBackend, *, force: bool) -> bool:
        next_state = target.debug_state()
        if not force and next_state == self.execution_state:
            return False
        self.execution_state = next_state
        if next_state == "halted":
            self.registers = target.read_core_registers()
            pc = self.registers.get("pc")
            location = None
            if pc is not None:
                location = (self.info.resolve_step_location(pc & ~1) if self.info.source_steps is not None
                            else self.info.resolve_address(pc))
            self.stopped_location = {"address": pc} if pc is not None else None
            if location is not None:
                self.stopped_location.update({"path": location.path, "line": location.line})
        else:
            self.registers = {}
            self.stopped_location = None
        return True

    def _verified_breakpoint(self, pc: int | None) -> dict[str, object] | None:
        return next((item for item in self.resolved_breakpoints
                     if item.get('verified') is True and isinstance(item.get('address'), int)
                     and pc is not None and (item['address'] & ~1) == (pc & ~1)), None)

    def continue_or_step(self, target: TargetBackend, *, resume: bool,
                         registers: dict[str, int] | None = None) -> None:
        if target.capabilities.manages_breakpoint_step:
            if resume:
                target.resume()
            else:
                target.step()
            return
        if resume and target.debug_state() == "running":
            return
        registers = registers or self.registers or target.read_core_registers()
        current_breakpoint = self._verified_breakpoint(registers.get('pc'))
        if current_breakpoint is None:
            if resume:
                target.resume()
            else:
                target.step()
            return

        address = int(current_breakpoint["address"])
        target.remove_breakpoint(address)
        try:
            target.step()
        finally:
            restored = target.set_breakpoint(address)
            if not restored:
                current_breakpoint["verified"] = False
                current_breakpoint["message"] = "跨过断点后无法重新设置该断点。"
        if resume:
            target.resume()

    def step_source(self, target: TargetBackend, action: str) -> None:
        if target.debug_state() != 'halted':
            raise RuntimeError('请先暂停目标。')
        registers = target.read_core_registers()
        steps = self.info.source_steps
        if steps is None or not self._thumb_context(registers):
            raise RuntimeError('源码步进需要带 DWARF 调试信息的 Cortex-M 固件。')
        deadline = monotonic() + _SOURCE_STEP_TIMEOUT
        if action == 'stepOut':
            caller = steps.caller(target, registers)
            if caller is None:
                raise RuntimeError('无法从 DWARF 调用帧确定返回位置。请在具有调用帧信息的函数内重试。')
            self._run_to_return(target, registers, *caller, deadline)
            return

        origin_pc = registers['pc'] & ~1
        origin = self.info.resolve_step_location(origin_pc)
        if origin is None:
            raise RuntimeError('当前位置没有源码行信息，请先单步执行指令或运行到源码断点。')
        for _ in range(_SOURCE_STEP_LIMIT):
            if monotonic() >= deadline:
                break
            pc = registers['pc'] & ~1
            return_pc = thumb_call_return(target, pc)
            if action == 'stepOver' and return_pc is not None:
                if return_pc not in steps.code:
                    raise RuntimeError('调用指令的返回位置不在固件的代码区。')
                stopped = self._run_to_return(target, registers, return_pc, registers['sp'], deadline)
            else:
                self.continue_or_step(target, resume=False, registers=registers)
                stopped = target.read_core_registers()

            stopped_pc = stopped['pc'] & ~1
            if (self._verified_breakpoint(stopped_pc) is not None
                    or (stopped['xpsr'] ^ registers['xpsr']) & 0x1FF
                    or stopped_pc == pc and stopped['sp'] == registers['sp']):
                return
            if return_pc is not None:
                # Stop at a called function on step-in, or at an unrelated stop on step-over.
                if stopped_pc != return_pc:
                    return
            location = self.info.resolve_step_location(stopped_pc)
            if location is None or (location.path, location.line) != (origin.path, origin.line):
                return
            registers = stopped
        raise RuntimeError('在步进限制内未到达新的源码行，目标已暂停。')

    @staticmethod
    def _thumb_context(registers: dict[str, int]) -> bool:
        return 'pc' in registers and 'sp' in registers and bool(registers.get('xpsr', 0) & (1 << 24))

    def _run_to_return(self, target: TargetBackend, registers: dict[str, int],
                       address: int, caller_sp: int, deadline: float) -> dict[str, int]:
        owns_breakpoint = self._verified_breakpoint(address) is None
        initial_exception = registers['xpsr'] & 0x1FF
        while monotonic() < deadline:
            pc = registers['pc'] & ~1
            # A paused instruction can already have a user breakpoint, or be
            # the same return address reached by a deeper recursive call.
            if pc == address or self._verified_breakpoint(pc) is not None:
                self.continue_or_step(target, resume=False, registers=registers)
                registers = target.read_core_registers()
                pc = registers['pc'] & ~1
                if (self._verified_breakpoint(pc) is not None
                        or pc == address and registers['sp'] == caller_sp
                        or registers['xpsr'] & 0x1FF != initial_exception):
                    return registers
                if pc == address:
                    raise RuntimeError('目标停在同一地址，无法继续越过调用。')

            if monotonic() >= deadline:
                break
            if owns_breakpoint and not target.set_breakpoint(address):
                raise RuntimeError('无法设置临时返回断点，请检查硬件断点资源。')
            try:
                try:
                    target.resume()
                    while target.debug_state() != 'halted':
                        if monotonic() >= deadline:
                            raise RuntimeError('等待函数返回超时，已请求暂停目标。')
                        sleep(0.01)
                except Exception:
                    target.halt()
                    raise
                registers = target.read_core_registers()
            finally:
                if owns_breakpoint:
                    target.remove_breakpoint(address)

            if ((registers['pc'] & ~1) != address or not owns_breakpoint
                    or registers['sp'] == caller_sp or registers['xpsr'] & 0x1FF != initial_exception):
                return registers
        raise RuntimeError('等待函数返回超时，目标已暂停。')


    def snapshot(self, *, include_definitions: bool = False) -> dict[str, object]:
        steps = self.info.source_steps
        can_step = self.execution_state == 'halted' and steps is not None and self._thumb_context(self.registers)
        pc = self.registers.get('pc', 0) & ~1
        return {
            "executionState": self.execution_state,
            "sourceFiles": self.info.source_files,
            "executableLines": self.info.executable_lines,
            "breakpoints": list(self.resolved_breakpoints),
            "registers": dict(self.registers),
            "stoppedLocation": self.stopped_location,
            "sourceStepAvailable": can_step and self.info.resolve_step_location(pc) is not None,
            "stepOutAvailable": can_step and steps.frame_rules(pc) is not None,
            **({"sourceDefinitions": self.info.source_definitions} if include_definitions else {}),
        }


    def remove_breakpoints(self, target: TargetBackend, *, connected: bool) -> None:
        if connected:
            for item in self.resolved_breakpoints:
                if item.get("verified") is True and isinstance(item.get("address"), int):
                    try:
                        target.remove_breakpoint(item["address"])
                    except Exception:
                        pass
        self.resolved_breakpoints = []


    def mark_breakpoints_pending(self, *, message="连接调试探针后设置断点。") -> None:
        self.resolved_breakpoints = [
            {
                "path": path,
                "requestedLine": line,
                "actualLine": line,
                "verified": False,
                "message": message,
            }
            for path, lines in self.requested_breakpoints.items()
            for line in sorted(lines)
        ]


    def apply_breakpoints(self, target: TargetBackend, *, connected: bool) -> None:
        self.remove_breakpoints(target, connected=connected)
        resolved: list[dict[str, object]] = []
        for path, lines in self.requested_breakpoints.items():
            for requested_line in sorted(lines):
                location = self.info.resolve_breakpoint(path, requested_line)
                item: dict[str, object] = {
                    "path": path,
                    "requestedLine": requested_line,
                    "actualLine": location.line if location is not None else requested_line,
                    "verified": False,
                }
                if location is None:
                    item["message"] = "该行没有可执行指令，不能设置断点。"
                else:
                    item["path"] = location.path
                    item["address"] = location.address
                    if not connected:
                        item["message"] = "连接调试探针后设置断点。"
                    else:
                        try:
                            item["verified"] = target.set_breakpoint(location.address)
                            if not item["verified"]:
                                item["message"] = "目标拒绝了断点，可能已用完硬件断点资源。"
                        except Exception as error:
                            item["message"] = str(error)
                resolved.append(item)
        self.resolved_breakpoints = resolved


