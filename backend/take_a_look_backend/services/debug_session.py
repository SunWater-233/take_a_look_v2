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
        self.disabled_breakpoints: dict[str, set[int]] = {}
        self.breakpoints_paused = False
        self.breakpoint_revision = 0
        self.resolved_breakpoints: list[dict[str, object]] = []
        self.execution_state = "unavailable"
        self.stopped_location: dict[str, object] | None = None
        self.registers: dict[str, int] = {}

    def _breakpoint_path(self, path: str) -> str:
        return self.info.canonical_source_path(path) or path

    def _breakpoint_path_key(self, path: str) -> str:
        return self._breakpoint_path(path).replace("\\", "/").rstrip("/").casefold()

    def set_breakpoints(self, path: str, lines: set[int], target: TargetBackend, *,
                        connected: bool, pending_message: str | None = None) -> None:
        key = self._breakpoint_path_key(path)
        requested = {name: values for name, values in self.requested_breakpoints.items()
                     if self._breakpoint_path_key(name) != key}
        if lines:
            requested[path] = lines
        self.replace_breakpoints(requested, self.disabled_breakpoints, self.breakpoints_paused, target,
                                 connected=connected, pending_message=pending_message)

    def replace_breakpoints(self, requested: dict[str, set[int]], disabled: dict[str, set[int]],
                            paused: bool, target: TargetBackend, *, connected: bool,
                            pending_message: str | None = None) -> None:
        paths: dict[str, str] = {}
        normalized: dict[str, set[int]] = {}
        for path, lines in requested.items():
            if lines:
                canonical = paths.setdefault(self._breakpoint_path_key(path), self._breakpoint_path(path))
                normalized.setdefault(canonical, set()).update(lines)
        disabled_normalized: dict[str, set[int]] = {}
        for path, lines in disabled.items():
            canonical = paths.get(self._breakpoint_path_key(path))
            if canonical is not None and (matching := normalized[canonical] & lines):
                disabled_normalized.setdefault(canonical, set()).update(matching)

        previous = self.requested_breakpoints, self.disabled_breakpoints, self.breakpoints_paused
        self.requested_breakpoints, self.disabled_breakpoints, self.breakpoints_paused = normalized, disabled_normalized, paused
        try:
            self.apply_breakpoints(target, connected=connected, pending_message=pending_message)
        except Exception:
            self.requested_breakpoints, self.disabled_breakpoints, self.breakpoints_paused = previous
            # Reinstall any addresses already removed before the probe rejected a removal.
            self.apply_breakpoints(target, connected=connected, pending_message=pending_message)
            raise
        self.breakpoint_revision += 1

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
            restored = False
            try:
                restored = target.set_breakpoint(address)
            finally:
                if not restored:
                    for item in self.resolved_breakpoints:
                        if item.get("address") == address and item["verified"]:
                            item.update(verified=False, status="failed", message="跨过断点后无法重新设置该断点。")
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
            "breakpoints": [dict(item) for item in self.resolved_breakpoints],
            "requestedBreakpoints": {path: sorted(lines) for path, lines in self.requested_breakpoints.items()},
            "disabledBreakpoints": {path: sorted(lines) for path, lines in self.disabled_breakpoints.items()},
            "breakpointsPaused": self.breakpoints_paused,
            "breakpointRevision": self.breakpoint_revision,
            "registers": dict(self.registers),
            "stoppedLocation": self.stopped_location,
            "sourceStepAvailable": can_step and self.info.resolve_step_location(pc) is not None,
            "stepOutAvailable": can_step and steps.frame_rules(pc) is not None,
            **({
                "sourceFiles": self.info.source_files,
                "executableLines": self.info.executable_lines,
                "sourceDefinitions": self.info.source_definitions,
            } if include_definitions else {}),
        }


    def remove_breakpoints(self, target: TargetBackend, *, connected: bool) -> None:
        if connected:
            for address in {item["address"] for item in self.resolved_breakpoints if item["verified"]}:
                try:
                    target.remove_breakpoint(address)
                except Exception:
                    pass
        self.resolved_breakpoints = []


    def mark_breakpoints_pending(self, *, message="连接调试探针后设置断点。") -> None:
        self.resolved_breakpoints = self._resolve_breakpoints(message)

    def _resolve_breakpoints(self, pending_message: str | None) -> list[dict[str, object]]:
        resolved = []
        for path, lines in self.requested_breakpoints.items():
            for requested_line in sorted(lines):
                location = self.info.resolve_breakpoint(path, requested_line)
                item: dict[str, object] = {
                    "path": path,
                    "requestedLine": requested_line,
                    "actualLine": location.line if location is not None else requested_line,
                    "verified": False,
                }
                if location is not None:
                    item["address"] = location.address
                if requested_line in self.disabled_breakpoints.get(path, ()):
                    item["status"] = "disabled"
                elif self.breakpoints_paused:
                    item["status"] = "paused"
                elif pending_message is not None:
                    item.update(status="pending", message=pending_message)
                elif location is None:
                    item.update(status="failed", message="该行没有可执行指令，不能设置断点。")
                else:
                    item["status"] = "pending"
                resolved.append(item)
        return resolved

    def apply_breakpoints(self, target: TargetBackend, *, connected: bool,
                          pending_message: str | None = None) -> None:
        if not connected:
            self.mark_breakpoints_pending(message=pending_message or "连接调试探针后设置断点。")
            return
        if not target.capabilities.target_control:
            pending_message = pending_message or "当前连接不支持断点调试。"
        resolved = self._resolve_breakpoints(pending_message)
        wanted = {item["address"] for item in resolved
                  if item["status"] == "pending" and "message" not in item}
        installed = {item["address"] for item in self.resolved_breakpoints if item["verified"]}
        for address in sorted(installed - wanted):
            for previous in self.resolved_breakpoints:
                if previous.get("address") == address and previous["verified"]:
                    previous.update(verified=False, status="pending")
            # A failed probe write can leave this address in an unknown state.
            # The rollback re-applies it along with any completed removals.
            target.remove_breakpoint(address)

        results = dict.fromkeys(installed & wanted, None)
        for item in resolved:
            address = item.get("address")
            if item["status"] != "pending" or "message" in item:
                continue
            if address not in results:
                try:
                    results[address] = (None if target.set_breakpoint(address) else
                                        "目标拒绝了断点，可能已用完硬件断点资源。")
                except Exception as error:
                    results[address] = str(error) or "设置断点失败。"
            if (message := results[address]) is None:
                item.update(verified=True, status="installed")
            else:
                item.update(status="failed", message=message)
        self.resolved_breakpoints = resolved


