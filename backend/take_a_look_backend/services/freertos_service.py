"""FreeRTOS orchestration in the existing serialized target-operation domain."""
from __future__ import annotations

import math

from ..models import SymbolInfo
from ..protocol import EventName, ProtocolError
from ..backends.target_backend import backend_capabilities
from .freertos import ReadBudget


class FreeRtosServiceMixin:
    def _invalidate_freertos_locked(self):
        had_snapshot = bool(self._freertos_snapshot)
        self._freertos.invalidate(clear=True)
        self._freertos_snapshot = {}
        self._next_freertos_at = 0.0
        self._remove_freertos_watches_locked(set(self._freertos_watch_identity))
        if had_snapshot:
            self._emit(EventName.FREERTOS, self._freertos_snapshot)

    def _remove_freertos_watches_locked(self, keys):
        if not keys:
            return
        for key in keys:
            self._watches.pop(key, None)
            self._symbols.pop(key, None)
            self._freertos_watch_identity.pop(key, None)
        self._capture_source = None
        self._monitor_schedule_revision += 1
        self._emit(EventName.STATE, {'symbols': [self._symbol_json(s) for s in self._symbols.values()],
                                    'watches': [self._watch_json(w) for w in self._watches.values()]})

    def _configure_freertos(self, params):
        with self._lock:
            if 'enabled' in params and not isinstance(params['enabled'], bool):
                raise ProtocolError('invalid_request', 'enabled 必须是布尔值。')
            rate = params.get('rateHz', self._freertos_rate)
            if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate) or not 1 <= rate <= 5:
                raise ProtocolError('invalid_request', 'FreeRTOS 刷新频率须为 1–5 Hz。')
            tick = params.get('tickHz', self._freertos_tick_hz)
            if tick is not None and (isinstance(tick, bool) or not isinstance(tick, int) or not 1 <= tick <= 1_000_000):
                raise ProtocolError('invalid_request', 'Tick 频率须为 1–1000000 Hz，或留空。')
            self._freertos_enabled = params.get('enabled', self._freertos_enabled)
            self._freertos_rate, self._freertos_tick_hz = float(rate), tick
            self._next_freertos_at = 0.0
        self._wake.set()
        return {}

    def _poll_freertos_locked(self, now, connected):
        if not self._freertos_enabled or now < self._next_freertos_at:
            return
        self._next_freertos_at = now + 1 / self._freertos_rate
        if self._firmware_busy:
            snapshot = self._freertos.unavailable('busy', '固件下载中，暂不读取内核；保留最后一份快照。')
        elif self._firmware.get('requiresDownload'):
            snapshot = self._freertos.unavailable('firmwareChanged', '固件已变化，请重新下载后读取内核。')
        elif not connected:
            snapshot = self._freertos.unavailable('disconnected', '连接已断开；保留最后一份快照。')
        elif not backend_capabilities(self._memory).memory_sampling and self._debug.execution_state != 'halted':
            snapshot = self._freertos.unavailable('targetRunning', '当前连接需要暂停目标后读取内核快照。')
        else:
            try:
                ranges = []
                target = getattr(self._memory, 'target', None)
                for region in getattr(target, 'memory_map', ()) or ():
                    if getattr(region, 'is_ram', False):
                        ranges.append((region.start, region.start + region.length))
                reader = getattr(self._memory, '_read_block', None)
                if reader is None:
                    raise RuntimeError('当前目标适配器没有原始内存读取接口。')
                snapshot = self._freertos.inspect(reader, halted=self._debug.execution_state == 'halted',
                                                  ranges=ranges, tick_hz=self._freertos_tick_hz)
                if snapshot.get('status') == 'ready':
                    for task in snapshot.get('tasks', []):
                        entry = task.get('entry')
                        location = self._debug.info.resolve_address(entry & ~1) if entry else None
                        if location and abs(location.address - (entry & ~1)) <= 8:
                            task.update(entryFile=location.path, entryLine=location.line)
            except Exception as error:
                self._handle_connection_failure_locked(error)
                snapshot = self._freertos.unavailable('readError', f'内核读取失败：{error}')
        snapshot = {**snapshot, 'firmwarePath': self._source_project['firmwarePath'], 'targetName': self._target_name}
        if snapshot.get('status') == 'ready':
            identities = {task['handle']: task.get('taskNumber') for task in snapshot.get('tasks', [])}
            removed = {key for key,(handle,number) in self._freertos_watch_identity.items()
                       if handle not in identities or identities[handle] != number}
            self._remove_freertos_watches_locked(removed)
        if snapshot != self._freertos_snapshot:
            self._freertos_snapshot = snapshot
            self._emit(EventName.FREERTOS, snapshot)

    def _add_freertos_watch(self, params):
        with self._lock:
            if self._firmware_busy:
                raise ProtocolError('source_task_busy', '固件下载中，请等待完成后加入监视。')
            if (self._connection_status != 'connected' or self._freertos_snapshot.get('stale')
                    or self._freertos_snapshot.get('status') != 'ready'):
                raise ProtocolError('not_connected', '请在连接有效且快照完整时加入监视。')
            handle, field_name = params.get('handle'), params.get('field')
            task = next((row for row in self._freertos_snapshot.get('tasks', []) if row['handle'] == handle), None)
            field = next((field for field in (task or {}).get('fields', []) if field['name'].rsplit('.', 1)[-1] == field_name), None)
            if field is None:
                raise ProtocolError('unknown_symbol', '当前快照没有此任务字段，请刷新后重试。')
            if task.get('taskNumber') is None:
                raise ProtocolError('unavailable', '内核未提供任务身份编号，请启用 configUSE_TRACE_FACILITY 后加入临时监视。')
            symbol = SymbolInfo(field['name'], field['address'], field['size'], field['kind'], '.rodata.freertos', 'FreeRTOS')
            self._symbols[symbol.key] = symbol
            self._freertos_watch_identity[symbol.key] = (handle, task.get('taskNumber'))
            watches = [self._watch_json(watch) for watch in self._watches.values()]
            if symbol.key not in self._watches:
                watches.append({'key': symbol.key, 'color': '#80ABC8', 'readMode': 'monitor', 'sampling': False, 'plotted': False})
            self._emit(EventName.STATE, {'symbols': [self._symbol_json(s) for s in self._symbols.values()]})
            return self._set_watches({'watches': watches})

    def _freertos_stack(self, params):
        with self._lock:
            if self._firmware_busy:
                raise ProtocolError('source_task_busy', '固件下载中，请等待完成后读取上下文。')
            if self._connection_status != 'connected' or self._debug.execution_state != 'halted':
                raise ProtocolError('target_running', '请先暂停目标，再查看保存的栈上下文。')
            task = next((t for t in self._freertos_snapshot.get('tasks', []) if t['handle'] == params.get('handle')), None)
            if (task is None or self._freertos_snapshot.get('stale')
                    or not self._freertos_snapshot.get('halted')):
                raise ProtocolError('stale_snapshot', '请先读取目标暂停后的有效快照。')
            sp, start, end = task.get('savedSp'), task.get('stackBase'), task.get('stackEnd')
            if self._freertos.layout.pointer_size != 4:
                raise ProtocolError('unavailable', '保存栈字查看当前支持 32 位目标。')
            if not sp or not start or not end or not start <= sp <= end:
                raise ProtocolError('unavailable', '缺少可验证的栈边界。')
            count = min(32, (end + 4 - sp) // 4)
            memory = ReadBudget(self._memory._read_block, self._freertos._m.ranges, self._freertos.layout.byteorder)
            data = memory.block(sp, count * 4)
            if len(data) != count * 4:
                raise ProtocolError('read_failed', '保存栈读取不完整。')
            return {'address': sp, 'words': [int.from_bytes(data[i:i+4], self._freertos.layout.byteorder) for i in range(0,len(data),4)],
                    'message': '原始保存栈；尚未进行 CPU 端口解码或调用栈展开。'}
