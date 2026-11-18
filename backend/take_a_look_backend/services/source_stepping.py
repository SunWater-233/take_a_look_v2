"""Cortex-M instruction and DWARF frame information for source stepping."""
from __future__ import annotations

from bisect import bisect_right

from elftools.dwarf.callframe import CFARule, FDE, RegisterRule
from elftools.dwarf.dwarfinfo import DWARFInfo

from take_a_look_backend.backends.target_backend import TargetBackend


class _AddressRanges:
    def __init__(self, ranges: list[tuple[int, int]]) -> None:
        self._starts: list[int] = []
        self._ends: list[int] = []
        for start, end in sorted(ranges):
            if end <= start:
                continue
            if self._ends and start <= self._ends[-1]:
                self._ends[-1] = max(self._ends[-1], end)
            else:
                self._starts.append(start)
                self._ends.append(end)

    def __contains__(self, address: int) -> bool:
        index = bisect_right(self._starts, address) - 1
        return index >= 0 and address < self._ends[index]


class SourceStepInfo:
    def __init__(self, dwarf: DWARFInfo, line_ranges: list[tuple[int, int]],
                 executable_ranges: list[tuple[int, int]]) -> None:
        self.lines = _AddressRanges(line_ranges)
        self.code = _AddressRanges(executable_ranges)
        self._frame_tables: list[tuple[list[int], list[FDE]]] = []
        for has_frames, load_frames in ((dwarf.has_CFI, dwarf.CFI_entries), (dwarf.has_EH_CFI, dwarf.EH_CFI_entries)):
            try:
                frames = sorted((frame for frame in load_frames() if isinstance(frame, FDE)),
                                key=lambda frame: frame['initial_location']) if has_frames() else []
            except Exception:
                # Malformed optional unwind data must leave line stepping usable.
                continue
            if frames:
                self._frame_tables.append(([frame['initial_location'] for frame in frames], frames))

    def frame_rules(self, pc: int) -> tuple[CFARule, RegisterRule | None] | None:
        for starts, frames in self._frame_tables:
            index = bisect_right(starts, pc) - 1
            if index < 0:
                continue
            frame = frames[index]
            if pc >= starts[index] + frame['address_range']:
                continue
            try:
                row = next((row for row in reversed(frame.get_decoded().table) if row['pc'] <= pc), None)
                if row is None:
                    continue
                cfa = row['cfa']
                return_register = frame.cie['return_address_register']
                rule = row.get(return_register)
                if (cfa.expr is None and cfa.reg is not None and cfa.offset is not None
                        and return_register == 14
                        and (rule is None or rule.type in {RegisterRule.SAME_VALUE, RegisterRule.REGISTER, RegisterRule.OFFSET})):
                    return cfa, rule
            except Exception:
                continue
        return None

    def caller(self, target: TargetBackend, registers: dict[str, int]) -> tuple[int, int] | None:
        rules = self.frame_rules(registers['pc'] & ~1)
        if rules is None:
            return None
        cfa, return_rule = rules

        def read_register(number: int) -> int:
            name = {13: 'sp', 14: 'lr', 15: 'pc'}.get(number, f'r{number}')
            if name in registers:
                return registers[name]
            if not 0 <= number <= 15:
                raise ValueError('调用帧使用了不支持的 ARM 寄存器。')
            return target.read_debug_registers([name])[name]

        caller_sp = read_register(cfa.reg) + cfa.offset
        if caller_sp < registers['sp'] or caller_sp & 3 or not 0 < caller_sp <= 0xFFFFFFFF:
            return None
        if return_rule is None or return_rule.type == RegisterRule.SAME_VALUE:
            # The ARM calling convention keeps an unsaved return address in LR.
            return_address = read_register(14)
        elif return_rule.type == RegisterRule.REGISTER:
            return_address = read_register(return_rule.arg)
        elif return_rule.type == RegisterRule.OFFSET:
            slot = caller_sp + return_rule.arg
            if slot & 3 or not 0 < slot <= 0xFFFFFFFC:
                return None
            return_address = int.from_bytes(target.read_debug_memory(slot, 4), 'little')
        else:
            return None
        return_pc = return_address & ~1
        # EXC_RETURN and invalid pointers do not identify a callable source frame.
        if not return_address & 1 or return_pc >= 0xFFFFFF00 or return_pc not in self.code:
            return None
        return return_pc, caller_sp


def thumb_call_return(target: TargetBackend, pc: int) -> int | None:
    """Return the fall-through address of Thumb BL or BLX (register)."""
    first = int.from_bytes(target.read_debug_memory(pc, 2), 'little')
    if first & 0xFF87 == 0x4780:
        return pc + 2
    if first & 0xF800 == 0xF000:
        second = int.from_bytes(target.read_debug_memory(pc + 2, 2), 'little')
        if second & 0xD000 == 0xD000:
            return pc + 4
    return None
