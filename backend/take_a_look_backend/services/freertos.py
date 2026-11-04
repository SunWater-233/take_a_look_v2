"""Read-only FreeRTOS inspection. No target function calls, halt, or writes.

Layouts are obtained from the exact firmware. Every linked list is bounded and
validated twice; invalid snapshots never replace a previously validated one.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable

from .freertos_layout import CType, FreeRtosLayout


class SnapshotInvalid(RuntimeError):
    pass


@dataclass
class ReadBudget:
    read: Callable[[int, int], bytes]
    ranges: list[tuple[int, int]]
    byteorder: str
    bytes_left: int = 128 * 1024
    calls_left: int = 512
    deadline: float = 0

    def __post_init__(self):
        self.deadline = time.monotonic() + .15

    def block(self, address: int, size: int) -> bytes:
        if (size < 0 or size > 4096 or not address or self.calls_left <= 0
                or size > self.bytes_left or time.monotonic() > self.deadline):
            raise SnapshotInvalid("快照读取超过预算或地址无效。")
        if not any(start <= address and address + size <= end for start, end in self.ranges):
            raise SnapshotInvalid(f"地址 0x{address:X} 不在已知 RAM / ELF 区域中。")
        self.calls_left -= 1
        self.bytes_left -= size
        data = bytes(self.read(address, size))
        if len(data) != size:
            raise SnapshotInvalid("目标返回不完整内存数据。")
        return data

    def uint(self, address: int, size: int = 4) -> int:
        if size not in {1, 2, 4, 8}:
            raise SnapshotInvalid("不支持的内核字段宽度。")
        return int.from_bytes(self.block(address, size), self.byteorder)

    def string(self, address: int, maximum: int = 64) -> str:
        if not address:
            return ""
        end = next((end for start, end in self.ranges if start <= address < end), address)
        data = self.block(address, min(maximum, end - address))
        return data.split(b'\0', 1)[0].decode('utf-8', 'replace')


class FreeRtosInspector:
    MAX_TASKS = 256
    MAX_OBJECTS = 256

    def __init__(self, layout: FreeRtosLayout | None = None):
        self.layout = layout
        self.sequence = 0
        self.previous: tuple | None = None
        self.last: dict | None = None
        self._stack_cache: dict[int, tuple] = {}

    def invalidate(self, *, clear: bool = False) -> None:
        self.previous = None
        self._stack_cache.clear()
        if clear:
            self.last = None

    def unavailable(self, status: str, message: str) -> dict:
        return {**(self.last or {"tasks": [], "objects": [], "timers": [], "heap": {}}),
                "status": status, "message": message, "stale": self.last is not None}

    def inspect(self, read, *, halted: bool, ranges=(), tick_hz: int | None = None) -> dict:
        layout = self.layout
        if layout is None or layout.problem:
            return self.unavailable("symbolsRequired", layout.problem if layout else "请加载包含 DWARF 的 ELF / AXF。")
        if layout.pointer_size not in {4, 8}:
            return self.unavailable("unsupported", "当前固件指针宽度尚不支持。")
        if "pxCurrentTCBs" in layout.variables:
            return self.unavailable("unsupported", "已识别 SMP 内核；当前检查器支持单核 FreeRTOS。")
        memory = ReadBudget(read, list(ranges) + layout.ranges, layout.byteorder)
        self._m = memory
        self._checks: list[tuple[int, bytes]] = []
        self._diagnostics: list[dict] = []
        self._list_cache: dict[int, list[tuple[int, int]]] = {}
        try:
            result = self._inspect(halted, tick_hz)
            for address, old in self._checks:
                if memory.block(address, len(old)) != old:
                    raise SnapshotInvalid("读取期间任务或对象链表发生变化，请等待下一次刷新。")
        except (SnapshotInvalid, KeyError, ValueError, OverflowError) as error:
            self.previous = None
            return self.unavailable("inconsistent", str(error))
        self.sequence += 1
        result.update(sequence=self.sequence, capturedAtMs=time.time_ns() // 1_000_000,
                      status="ready", stale=False, quality="haltedValidated" if halted else "runningApproximate")
        self.last = result
        return result

    def _var(self, name: str, default=None):
        var = self.layout.variables.get(name)
        if var is None:
            return default
        return self._m.uint(var.address, var.type.size)

    def _field(self, data: bytes, typ: CType, path: str, default=None):
        field = typ.member(path)
        if field is None:
            return default
        offset, member = field
        if member.size not in {1, 2, 4, 8} or offset + member.size > len(data):
            raise SnapshotInvalid(f"内核字段 {path} 布局无效。")
        return int.from_bytes(data[offset:offset + member.size], self.layout.byteorder)

    def _list(self, address: int) -> list[tuple[int, int]]:
        if address in self._list_cache:
            return self._list_cache[address]
        typ = self.layout.type("List_t", "xLIST")
        item_type = self.layout.type("ListItem_t", "xLIST_ITEM")
        if typ is None or item_type is None:
            raise SnapshotInvalid("缺少 FreeRTOS List_t / ListItem_t 类型。")
        raw = self._m.block(address, typ.size)
        count = self._field(raw, typ, "uxNumberOfItems")
        end = typ.member("xListEnd")
        if count is None or count > self.MAX_TASKS or end is None:
            raise SnapshotInvalid("内核链表长度无效。")
        sentinel = address + end[0]
        pointer = self._field(raw, typ, "xListEnd.pxNext")
        previous = sentinel
        result, visited = [], set()
        for _ in range(count):
            if not pointer or pointer == sentinel or pointer in visited:
                raise SnapshotInvalid("内核链表提前结束或形成环。")
            visited.add(pointer)
            item = self._m.block(pointer, item_type.size)
            if (self._field(item, item_type, "pxPrevious") != previous
                    or self._field(item, item_type, "pxContainer") != address):
                raise SnapshotInvalid("内核链表正在更新或已损坏。")
            owner = self._field(item, item_type, "pvOwner")
            result.append((owner, self._field(item, item_type, "xItemValue", 0)))
            self._checks.append((pointer, item))
            previous, pointer = pointer, self._field(item, item_type, "pxNext")
        if pointer != sentinel or self._field(raw, typ, "xListEnd.pxPrevious") != previous:
            raise SnapshotInvalid("内核链表尾指针不一致。")
        # pxIndex is the scheduler's rotating cursor, not a structural link.
        for path in ('uxNumberOfItems', 'xListEnd.pxNext', 'xListEnd.pxPrevious'):
            offset, member = typ.member(path)
            self._checks.append((address + offset, raw[offset:offset + member.size]))
        self._list_cache[address] = result
        return result

    def _inspect(self, halted: bool, tick_hz: int | None) -> dict:
        typ = self.layout.type("TCB_t", "tskTaskControlBlock")
        if typ.size <= 0 or typ.size > 4096:
            raise SnapshotInvalid("TCB 布局大小无效。")
        current = self._var("pxCurrentTCB")
        count = self._var("uxCurrentNumberOfTasks")
        tick = self._var("xTickCount")
        idle = self._var('xIdleTaskHandle')
        idle_array = self.layout.variables.get('xIdleTaskHandles')
        if idle is None and idle_array is not None:
            idle = self._m.uint(idle_array.address, self.layout.pointer_size)
        if self.previous and tick is not None and self.previous[1] is not None and tick < self.previous[1] and self.previous[1]-tick < 0x80000000:
            self.invalidate()
        if current is None or count is None:
            raise SnapshotInvalid("缺少 pxCurrentTCB / uxCurrentNumberOfTasks 符号。")
        if count > self.MAX_TASKS:
            raise SnapshotInvalid("任务数量超出支持范围。")
        tcb_var = self.layout.variables["pxCurrentTCB"]
        current_raw = self._m.block(tcb_var.address, tcb_var.type.size)
        if int.from_bytes(current_raw, self.layout.byteorder) != current:
            raise SnapshotInvalid('读取期间当前任务发生变化。')
        self._checks.append((tcb_var.address, current_raw))
        count_var = self.layout.variables['uxCurrentNumberOfTasks']
        self._checks.append((count_var.address, int(count).to_bytes(count_var.type.size, self.layout.byteorder)))
        task_states: dict[int, str] = {}
        for name, state in (("pxReadyTasksLists", "ready"), ("xDelayedTaskList1", "blocked"),
                            ("xDelayedTaskList2", "blocked"), ("xSuspendedTaskList", "suspended"),
                            ("xTasksWaitingTermination", "deleted")):
            var = self.layout.variables.get(name)
            if var is None:
                continue
            entries = var.type.count if var.type.kind == "array" else 1
            stride = var.type.target.size if var.type.kind == "array" else var.type.size
            if entries > 128 or not stride:
                raise SnapshotInvalid("任务列表数组布局无效。")
            for index in range(entries):
                for owner, _ in self._list(var.address + index * stride):
                    if owner in task_states:
                        raise SnapshotInvalid("任务同时出现在多个状态列表中。")
                    task_states[owner] = state
        pending = self.layout.variables.get('xPendingReadyList')
        if pending is not None:
            for owner, _ in self._list(pending.address):
                if owner not in task_states:
                    raise SnapshotInvalid('待就绪列表包含未知任务。')
                task_states[owner] = 'ready'
        if len(task_states) != count:
            raise SnapshotInvalid("任务数量与链表内容不一致，可能缺少内核符号。")
        if current and current not in task_states:
            raise SnapshotInvalid("当前任务不在任务列表中。")
        tasks = []
        for handle, state in task_states.items():
            raw = self._m.block(handle, typ.size)
            name_field = typ.member("pcTaskName")
            if name_field is None:
                raise SnapshotInvalid("TCB 缺少任务名字段。")
            offset, name_type = name_field
            name = raw[offset:offset + min(name_type.size, 256)].split(b'\0', 1)[0].decode('utf-8', 'replace')
            stack = self._field(raw, typ, "pxStack")
            end = self._field(raw, typ, "pxEndOfStack")
            sp = self._field(raw, typ, "pxTopOfStack")
            stack_member = typ.member("pxStack")
            word = stack_member[1].target.size if stack_member and stack_member[1].target else 0
            total = end - stack + word if end and stack and end >= stack and word else None
            if total is not None and total > 16 * 1024 * 1024:
                raise SnapshotInvalid("任务栈边界无效。")
            event_container = self._field(raw, typ, "xEventListItem.pxContainer", 0)
            # Indefinite event waits live on the suspended list in FreeRTOS.
            if state == "suspended" and event_container:
                state = "blocked"
            task = {"handle": handle, "name": name or f"Task@{handle:X}",
                    "isIdle": handle == idle if idle else name == 'IDLE',
                    "state": "running" if handle == current else state,
                    "priority": self._field(raw, typ, "uxPriority"),
                    "basePriority": self._field(raw, typ, "uxBasePriority"),
                    "taskNumber": self._field(raw, typ, "uxTCBNumber"),
                    "runtimeCounter": self._field(raw, typ, "ulRunTimeCounter"),
                    "cpuPercent": None, "stackBase": stack, "stackEnd": end,
                    "savedSp": sp, "stackBytes": total, "minFreeStackBytes": None,
                    "waitingObject": None, "notifications": [], "fields": [],
                    "_eventContainer": event_container}
            notify = typ.member("ulNotifiedValue")
            states = typ.member("ucNotifyState")
            if notify:
                base, nt = notify
                size, length = (nt.target.size, nt.count) if nt.kind == "array" else (nt.size, 1)
                for i in range(min(length, 32)):
                    state_offset = states[0] + i if states else None
                    task["notifications"].append({"index": i, "value": int.from_bytes(raw[base+i*size:base+(i+1)*size], self.layout.byteorder),
                                                  "state": raw[state_offset] if state_offset is not None else None})
            if task['state'] == 'suspended' and any(n['state'] == 1 for n in task['notifications']):
                task['state'] = 'blocked'
            for field_name in ("uxPriority", "uxBasePriority", "ulRunTimeCounter"):
                member = typ.member(field_name)
                if member and member[1].size in {1, 2, 4, 8}:
                    task["fields"].append({"name": f"{task['name']}.{field_name}", "address": handle + member[0],
                                           "size": member[1].size, "kind": f"uint{member[1].size*8}_t"})
            if stack and word == 4 and self.layout.machine == 'EM_ARM':
                self._stack_water(task, halted)
            tasks.append(task)
        tasks.sort(key=lambda task: (task['taskNumber'] if task['taskNumber'] is not None else task['handle']))
        for address, old in self._checks:
            if self._m.block(address, len(old)) != old:
                raise SnapshotInvalid('任务在读取期间发生变化，请等待下一次刷新。')
        self._checks.clear()
        metadata = self._optional('metadata', '固件辅助快照', lambda: self._metadata(tasks), {})
        tick_hz = metadata.get("tickHz") or tick_hz
        objects = self._optional('objects', '内核对象', lambda: self._objects(tasks), None)
        if objects is None:
            objects = []
            for task in tasks:
                task['waitingObject'] = None
        timers = self._optional('timers', '软件定时器', lambda: self._timers(tick_hz), [])
        heap = self._optional('heap', '堆内存', self._heap, {})
        self._cpu(tasks, tick, tick_hz, metadata, halted)
        for task in tasks:
            task.pop("_eventContainer", None)
        self._diag("tasks", "任务与状态", "available", "ELF / DWARF 布局；任务链表已校验。")
        self._diag("stack", "任务栈", "available" if any(t['minFreeStackBytes'] is not None for t in tasks) else "unavailable",
                   "A5 填充扫描为估算；固件辅助快照可提供 API 水位。缺少边界时不计算占比。")
        self._diag("context", "保存上下文", "available" if halted else "targetRunning",
                   "显示保存的 SP 与原始栈字；调用栈展开需要匹配的 CPU 端口适配。")
        return {"kernel": "FreeRTOS", "version": metadata.get("version"), "tick": tick, "tickHz": tick_hz,
                "tasks": tasks, "objects": objects, "timers": timers, "heap": heap,
                "diagnostics": self._diagnostics, "halted": halted,
                "nonIdlePercent": max(0.0, min(100.0, 100 - sum(t['cpuPercent'] for t in tasks if t['isIdle'])))
                    if tasks and any(t['isIdle'] for t in tasks) and all(t['cpuPercent'] is not None for t in tasks) else None}

    def _diag(self, key, label, status, message):
        self._diagnostics.append({"key": key, "label": label, "status": status, "message": message})

    def _optional(self, key, label, read, empty):
        """An unavailable resource domain must not hide a valid task snapshot."""
        first_check, first_diag = len(self._checks), len(self._diagnostics)
        old_lists = set(self._list_cache)
        try:
            result = read()
            for address, old in self._checks[first_check:]:
                if self._m.block(address, len(old)) != old:
                    raise SnapshotInvalid('资源在读取期间发生变化。')
            return result
        except (SnapshotInvalid, KeyError, ValueError, OverflowError) as error:
            del self._diagnostics[first_diag:]
            self._diag(key, label, 'unavailable', f'本次未读取到完整资源快照：{error}')
            for address in set(self._list_cache) - old_lists:
                self._list_cache.pop(address, None)
            return empty
        finally:
            del self._checks[first_check:]

    def _stack_water(self, task: dict, halted: bool):
        key = task['handle']
        signature = (task['taskNumber'], task['stackBase'], task['stackBytes'])
        cached = self._stack_cache.get(key)
        if cached and cached[0] == signature and time.monotonic() - cached[1] < 5:
            task.update(cached[2])
            return
        # Only scan known bounds, from the lower end (the supported Cortex-M port).
        total = task['stackBytes']
        if not total or total <= 0:
            return
        maximum = min(total, 4096)
        data = self._m.block(task['stackBase'], maximum)
        free = next((i for i, byte in enumerate(data) if byte != 0xA5), len(data))
        free -= free % 4
        values = {"minFreeStackBytes": free, "stackWatermarkSource": "patternEstimate",
                  "stackWatermarkAtLeast": free == maximum and maximum < total,
                  "stackScannedAtMs": time.time_ns() // 1_000_000}
        # Zero is ambiguous when firmware never initialized the fill pattern.
        if free == 0:
            values["minFreeStackBytes"] = None
        task.update(values)
        self._stack_cache[key] = (signature, time.monotonic(), values)

    def _metadata(self, tasks) -> dict:
        var = self.layout.variables.get("tal_freertos_info")
        if not var:
            return {}
        typ = var.type
        if typ.size > 4096:
            return {}
        raw = self._m.block(var.address, typ.size)
        if self._field(raw, typ, "magic") != 0x54414C46 or self._field(raw, typ, "abi") != 1:
            return {}
        seq = self._field(raw, typ, "sequence", 1)
        if seq & 1:
            return {}
        if self._m.block(var.address, typ.size) != raw:
            raise SnapshotInvalid('固件辅助快照正在更新。')
        result = {name: self._field(raw, typ, name) for name in ("tickHz", "runtimeHz", "totalRuntime")}
        version_field = typ.member("version")
        if version_field:
            start, field = version_field
            result['version'] = raw[start:start+field.size].split(b'\0',1)[0].decode('ascii','replace')
        count = self._field(raw, typ, "taskCount", 0)
        records = typ.member("tasks")
        if records and records[1].kind == "array" and count <= records[1].count:
            records_offset, array = records
            by_handle = {t['handle']:t for t in tasks}
            for i in range(count):
                record = raw[records_offset+i*array.target.size:records_offset+(i+1)*array.target.size]
                task = by_handle.get(self._field(record, array.target, "handle"))
                if task is not None:
                    task_number = self._field(record, array.target, 'taskNumber')
                    if task_number is not None and task_number != task.get('taskNumber'):
                        continue
                    free = self._field(record, array.target, "minFreeStackBytes")
                    if free is not None:
                        task.update(minFreeStackBytes=free, stackWatermarkSource="kernelApi", stackWatermarkAtLeast=False)
                    size = self._field(record, array.target, 'stackBytes')
                    if size and size <= 16 * 1024 * 1024:
                        task['stackBytes'] = size
                    entry = self._field(record, array.target, 'entry')
                    if entry:
                        task['entry'] = entry
        result['sequence'] = seq
        return result

    def _cpu(self, tasks, tick, tick_hz, metadata, halted):
        counters = {t['handle']:(t['taskNumber'],t['runtimeCounter']) for t in tasks}
        valid = bool(tasks) and all(v[1] is not None for v in counters.values())
        previous = self.previous
        runtime = metadata.get('totalRuntime')
        now = time.monotonic()
        self.previous = (now, tick, runtime, counters) if valid and not halted else None
        if not valid:
            self._diag("cpu", "运行时间统计", "unavailable", "TCB 未包含运行计数，请启用 configGENERATE_RUN_TIME_STATS。")
            return
        if halted or not previous:
            self._diag("cpu", "运行时间统计", "pending", "等待两个运行中的有效快照；暂停时保留计数，CPU 占用不计算。")
            return
        old_time, old_tick, old_runtime, old_counters = previous
        if set(counters) != set(old_counters) or any(counters[h][0] != old_counters[h][0] for h in counters):
            self._diag("cpu", "运行时间统计", "pending", "任务集合已变化，正在建立新的统计窗口。")
            return
        counter_type = self.layout.type("TCB_t", "tskTaskControlBlock").member("ulRunTimeCounter")[1]
        modulus = 1 << (counter_type.size * 8)
        deltas = {h:(v[1]-old_counters[h][1]) % modulus for h,v in counters.items()}
        if any(delta >= modulus // 2 for delta in deltas.values()) or (tick is not None and old_tick is not None and tick < old_tick and old_tick-tick < 0x80000000):
            self.previous = None
            self._diag("cpu", "运行时间统计", "pending", "目标计数已复位，正在重新同步。")
            return
        # Public API total includes the currently running task's unfinished slice.
        denominator = ((runtime-old_runtime) % modulus if runtime is not None and old_runtime is not None else sum(deltas.values()))
        if denominator <= 0 or sum(deltas.values()) > denominator * 1.15:
            self._diag("cpu", "运行时间统计", "pending", "运行计数窗口尚不完整。")
            return
        for task in tasks:
            task['cpuPercent'] = min(100.0, deltas[task['handle']]*100.0/denominator)
            task['cpuWindowSeconds'] = now-old_time
        self._diag("cpu", "运行时间统计", "available", "相邻快照计数差；统计可能包含归属到当前任务的中断时间。")

    def _objects(self, tasks) -> list[dict]:
        types = {"queue":self.layout.type("Queue_t", "QueueDefinition"),
                 "eventGroup":self.layout.type("EventGroup_t", "EventGroupDef_t"),
                 "streamBuffer":self.layout.type("StreamBuffer_t", "StreamBufferDef_t")}
        candidates: dict[int, tuple[str,str]] = {}
        registry = self.layout.variables.get("xQueueRegistry")
        if registry and registry.type.kind == 'array':
            array = registry.type
            for i in range(min(array.count,self.MAX_OBJECTS)):
                raw = self._m.block(registry.address + i*array.target.size,array.target.size)
                handle = self._field(raw,array.target,'xHandle')
                name = self._field(raw,array.target,'pcQueueName')
                if handle:
                    candidates[handle] = ('queue',self._m.string(name) if name else f'Queue@{handle:X}')
        # Public typed global handles also cover event groups and stream/message buffers.
        for var in self.layout.variables.values():
            if var.type.kind != 'pointer' or not var.type.target:
                continue
            kind = next((kind for kind, typ in types.items() if typ and var.type.target is typ),None)
            if kind and len(candidates)<self.MAX_OBJECTS:
                handle = self._m.uint(var.address,var.type.size)
                if handle:
                    candidates.setdefault(handle,(kind,var.name))
        result=[]
        by_handle={t['handle']:t for t in tasks}
        for handle,(kind,name) in candidates.items():
            typ=types[kind]
            if typ is None:
                continue
            raw=self._m.block(handle,typ.size)
            item={"handle":handle,"name":name,"kind":kind,"owner":None,"waiters":[],"fields":[]}
            if kind=='queue':
                code=self._field(raw,typ,'ucQueueType')
                item['kind']={0:'queue',1:'mutex',2:'countingSemaphore',3:'binarySemaphore',4:'recursiveMutex'}.get(code,'queue')
                if code is None and self._field(raw,typ,'pcHead',-1)==0:
                    item['kind']='mutex'
                item.update(count=self._field(raw,typ,'uxMessagesWaiting'),capacity=self._field(raw,typ,'uxLength'),itemBytes=self._field(raw,typ,'uxItemSize'))
                item['owner']=self._field(raw,typ,'u.xSemaphore.xMutexHolder') if item['kind'] in {'mutex','recursiveMutex'} else None
                lists=['xTasksWaitingToSend','xTasksWaitingToReceive']
            elif kind=='eventGroup':
                item['bits']=self._field(raw,typ,'uxEventBits')
                lists=['xTasksWaitingForBits']
            else:
                flags=self._field(raw,typ,'ucFlags',0)
                item['kind']='messageBuffer' if flags & 1 else 'streamBuffer'
                length=self._field(raw,typ,'xLength')
                head,tail=self._field(raw,typ,'xHead'),self._field(raw,typ,'xTail')
                if not length or head is None or tail is None or head>=length or tail>=length:
                    raise SnapshotInvalid("流缓冲区指针无效。")
                item.update(count=(head-tail)%length,capacity=length-1,triggerBytes=self._field(raw,typ,'xTriggerLevelBytes'))
                item['waiters']=[h for h in (self._field(raw,typ,'xTaskWaitingToReceive'),self._field(raw,typ,'xTaskWaitingToSend')) if h in by_handle]
                lists=[]
            for path in lists:
                member=typ.member(path)
                if member:
                    for owner,_ in self._list(handle+member[0]):
                        if owner not in by_handle:
                            raise SnapshotInvalid("对象等待列表包含未知任务。")
                        item['waiters'].append(owner)
            for owner in set(item['waiters']):
                by_handle[owner]['waitingObject']=handle
            item['waiters']=sorted(set(item['waiters']))
            result.append(item)
        self._diag("objects","内核对象","available" if result else "unavailable",
                   "读取已登记或有类型的全局句柄；未登记的局部对象不保证枚举。队列可使用 vQueueAddToRegistry()。")
        return result

    def _timers(self,tick_hz) -> list[dict]:
        typ=self.layout.type('Timer_t','tmrTimerControl')
        if typ is None:
            self._diag('timers','软件定时器','unavailable','未发现定时器类型或内核未启用软件定时器。')
            return []
        active=set()
        for name in ('xActiveTimerList1','xActiveTimerList2'):
            var=self.layout.variables.get(name)
            if var:
                active.update(h for h,_ in self._list(var.address))
        candidates=set(active)
        names={}
        for var in self.layout.variables.values():
            if var.type.kind=='pointer' and var.type.target is typ:
                handle=self._m.uint(var.address,var.type.size)
                if handle:
                    candidates.add(handle)
                    names[handle]=var.name
        if len(candidates)>self.MAX_OBJECTS:
            raise SnapshotInvalid('软件定时器数量超出限制。')
        result=[]
        for handle in sorted(candidates):
            raw=self._m.block(handle,typ.size)
            name=self._field(raw,typ,'pcTimerName')
            status=self._field(raw,typ,'ucStatus')
            period=self._field(raw,typ,'xTimerPeriodInTicks')
            result.append({'handle':handle,'name':self._m.string(name) if name else names.get(handle,f'Timer@{handle:X}'),
                           'active':handle in active,'autoReload':bool(status&4) if status is not None else self._field(raw,typ,'uxAutoReload'),
                           'periodTicks':period,'periodMs':period*1000/tick_hz if period is not None and tick_hz else None,
                           'expiryTick':self._field(raw,typ,'xTimerListItem.xItemValue') if handle in active else None,
                           'callback':self._field(raw,typ,'pxCallbackFunction'),'id':self._field(raw,typ,'pvTimerID')})
        self._diag('timers','软件定时器','available','活动定时器来自内核列表；未启动的定时器通过全局有类型句柄发现。')
        return result

    def _heap(self) -> dict:
        free=self._var('xFreeBytesRemaining')
        minimum=self._var('xMinimumEverFreeBytesRemaining')
        region=self.layout.variables.get('ucHeap')
        result={'freeBytes':free,'minimumEverFreeBytes':minimum,'totalBytes':region.type.size if region else None,'base':region.address if region else None,'blocks':[]}
        typ=self.layout.type('BlockLink_t','A_BLOCK_LINK')
        start=self.layout.variables.get('xStart')
        end=self._var('pxEnd')
        if typ and start and free is not None:
            canary=self._var('xHeapCanary',0)
            start_raw=self._m.block(start.address,typ.size)
            self._checks.append((start.address,start_raw))
            free_var=self.layout.variables['xFreeBytesRemaining']
            self._checks.append((free_var.address,int(free).to_bytes(free_var.type.size,self.layout.byteorder)))
            current=self._field(start_raw,typ,'pxNextFreeBlock') ^ canary
            visited=set()
            while current and current!=end:
                if current in visited or len(visited)>=256:
                    raise SnapshotInvalid('堆空闲链表形成环或超过限制。')
                visited.add(current)
                raw=self._m.block(current,typ.size)
                size=self._field(raw,typ,'xBlockSize')
                if not size or size >= 1 << (self.layout.pointer_size*8-1):
                    raise SnapshotInvalid('堆空闲块大小无效。')
                if not any(begin <= current and current+size <= limit for begin,limit in self._m.ranges):
                    raise SnapshotInvalid('堆空闲块越过已知内存边界。')
                result['blocks'].append({'address':current,'size':size})
                self._checks.append((current,raw))
                current=self._field(raw,typ,'pxNextFreeBlock') ^ canary
            if sum(b['size'] for b in result['blocks'])!=free:
                raise SnapshotInvalid('堆统计与空闲链表不一致。')
            sizes=[b['size'] for b in result['blocks']]
            result.update(largestFreeBlockBytes=max(sizes,default=0),smallestFreeBlockBytes=min(sizes,default=0),freeBlockCount=len(sizes))
        self._diag('heap','堆内存','available' if free is not None else 'unavailable','统计仅覆盖 FreeRTOS 分配器；不包含其他 malloc / 内存池。')
        return result
