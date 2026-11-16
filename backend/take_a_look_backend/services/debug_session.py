"""Debug state and breakpoint lifecycle; callers serialize target access.

This object owns no worker or lock. BackendService keeps the shared probe lock
around these operations, so sampling, downloads and debug control stay ordered.
"""
from __future__ import annotations

from take_a_look_backend.backends.target_backend import TargetBackend, backend_capabilities
from take_a_look_backend.services.debug_info import DebugInfoIndex


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
            location = self.info.resolve_address(pc) if pc is not None else None
            self.stopped_location = {"address": pc} if pc is not None else None
            if location is not None:
                self.stopped_location.update({"path": location.path, "line": location.line})
        else:
            self.registers = {}
            self.stopped_location = None
        return True

    def continue_or_step(self, target: TargetBackend, *, resume: bool) -> None:
        if backend_capabilities(target).manages_breakpoint_step:
            if resume:
                target.resume()
            else:
                target.step()
            return
        if resume and target.debug_state() == "running":
            return
        registers = self.registers or target.read_core_registers()
        pc = registers.get("pc")
        current_breakpoint = next(
            (
                item
                for item in self.resolved_breakpoints
                if item.get("verified") is True
                and isinstance(item.get("address"), int)
                and pc is not None
                and (item["address"] & ~1) == (pc & ~1)
            ),
            None,
        )
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


    def snapshot(self, *, include_definitions: bool = False) -> dict[str, object]:
        return {
            "executionState": self.execution_state,
            "sourceFiles": self.info.source_files,
            "executableLines": self.info.executable_lines,
            "breakpoints": list(self.resolved_breakpoints),
            "registers": dict(self.registers),
            "stoppedLocation": self.stopped_location,
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


