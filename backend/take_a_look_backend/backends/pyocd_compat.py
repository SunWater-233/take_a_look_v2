"""Session-local workarounds for the pinned pyOCD runtime."""
from __future__ import annotations

from functools import wraps
from typing import Any


def guard_dap_error_recovery(target: Any) -> None:
    """Keep pyOCD 0.46 error paths bounded and their SELECT locks balanced."""
    from pyocd.core.exceptions import Error
    from pyocd.coresight.dap import DebugPort

    dp = getattr(target, "dp", None)
    if not isinstance(dp, DebugPort) or getattr(dp, "_tal_recovery_guarded", False):
        return

    _guard_dp_select_locking(dp)
    original = dp._handle_error
    recovering = False

    @wraps(original)
    def handle_error(error: Exception, num: int) -> None:
        nonlocal recovering
        if recovering:
            return
        recovering = True
        try:
            original(error, num)
        except Error as recovery_error:
            # pyOCD's callers release their probe locks and re-raise the original
            # transfer error AFTER _handle_error returns. Preserve that path,
            # including the MEM-AP's fault address annotation.
            error.add_note(f"调试链路错误恢复失败：{recovery_error}")
        finally:
            recovering = False

    dp._handle_error = handle_error
    dp._tal_recovery_guarded = True


def _guard_dp_select_locking(dp: Any) -> None:
    from pyocd.core.exceptions import ProbeError
    from pyocd.coresight.dap import (
        ADIVersion, DP_ABORT, DP_SELECT, DP_RDBUFF, DPADDR_MASK,
        DPADDR_DPBANKSEL_MASK, DPADDR_DPBANKSEL_SHIFT,
        SELECT_AP_MASK, SELECT_APADDR_MASK, SELECT_DPBANKSEL_MASK,
    )

    def write_select_locked(mask: int, value: int) -> bool:
        dp.lock()
        try:
            dp._write_dp_select(mask, value)
        except BaseException:
            dp.unlock()
            raise
        return True

    @wraps(dp._select_ap)
    def select_ap(addr: int) -> bool:
        if dp._probe_managed_ap_select:
            return False
        if dp.adi_version == ADIVersion.ADIv5:
            mask = SELECT_AP_MASK
        elif dp.adi_version == ADIVersion.ADIv6:
            mask = SELECT_APADDR_MASK
        else:
            raise AssertionError("invalid ADI version")
        return write_select_locked(mask, addr & mask)

    @wraps(dp._set_dpbanksel)
    def set_dpbanksel(addr: int, is_write: bool) -> bool:
        ignored = ((DP_SELECT, DP_RDBUFF) if dp._is_dpv3 and not is_write
                   else (DP_ABORT, DP_SELECT, DP_RDBUFF))
        if (addr & DPADDR_MASK) in ignored:
            return False
        bank = (addr & DPADDR_DPBANKSEL_MASK) >> DPADDR_DPBANKSEL_SHIFT
        if dp._probe_managed_dpbanksel:
            if bank and not dp._probe_supports_dpbanksel:
                raise ProbeError("probe does not support banked DP registers")
            return False
        return write_select_locked(SELECT_DPBANKSEL_MASK, bank)

    # Upstream acquires these locks before the caller can set did_lock. A
    # failed SELECT write must release its own lock, including during recovery.
    dp._select_ap = select_ap
    dp._set_dpbanksel = set_dpbanksel
