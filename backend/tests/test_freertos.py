"""Snapshots of changing target memory, including races and invalid pointers."""
import struct

import pytest

from take_a_look_backend.services.freertos import FreeRtosInspector, ReadBudget, SnapshotInvalid
from take_a_look_backend.services.freertos_layout import CType, CVariable, FreeRtosLayout


def scalar(size=4):
    return CType('unsigned', size=size)


def array(typ, count):
    return CType(kind='array', target=typ, count=count, size=typ.size*count)


def record(name, size, **members):
    return CType(name, 'record', size, members)


class KernelImage:
    BASE = 0x20000000
    A, B, OWNER = BASE + 0x1000, BASE + 0x1100, BASE + 0x1200
    QUEUE = BASE + 0x2000

    def __init__(self):
        u32, u8 = scalar(), scalar(1)
        ptr = CType(kind='pointer', size=4, target=u32)
        item = record('xLIST_ITEM',20,xItemValue=(0,u32),pxNext=(4,ptr),pxPrevious=(8,ptr),pvOwner=(12,ptr),pxContainer=(16,ptr))
        mini = record('xMINI_LIST_ITEM',12,xItemValue=(0,u32),pxNext=(4,ptr),pxPrevious=(8,ptr))
        lists = record('xLIST',20,uxNumberOfItems=(0,u32),pxIndex=(4,ptr),xListEnd=(8,mini))
        tcb = record('tskTaskControlBlock',92,pxTopOfStack=(0,ptr),xStateListItem=(4,item),xEventListItem=(24,item),
                     uxPriority=(44,u32),pxStack=(48,ptr),pcTaskName=(52,array(u8,16)),pxEndOfStack=(68,ptr),
                     uxBasePriority=(72,u32),ulRunTimeCounter=(76,u32),uxTCBNumber=(80,u32),
                     ulNotifiedValue=(84,array(u32,1)),ucNotifyState=(88,array(u8,1)))
        sem=record('SemaphoreData',8,xMutexHolder=(0,ptr),uxRecursiveCallCount=(4,u32))
        union=record('union',8,xSemaphore=(0,sem))
        queue=record('QueueDefinition',68,pcHead=(0,ptr),u=(4,union),xTasksWaitingToSend=(12,lists),
                     xTasksWaitingToReceive=(32,lists),uxMessagesWaiting=(52,u32),uxLength=(56,u32),uxItemSize=(60,u32),ucQueueType=(64,u8))
        registry=record('QueueRegistryItem',8,pcQueueName=(0,ptr),xHandle=(4,ptr))
        self.layout=FreeRtosLayout(types={'TCB_t':tcb,'List_t':lists,'ListItem_t':item,'Queue_t':queue},ranges=[(self.BASE,self.BASE+0x10000)])
        self.memory=bytearray(0x10000)
        def var(name, offset, typ):
            self.layout.variables[name]=CVariable(name,self.BASE+offset,typ,'tasks.c')
        var('pxCurrentTCB',0,ptr); var('uxCurrentNumberOfTasks',4,u32); var('xTickCount',8,u32)
        var('pxReadyTasksLists',0x100,array(lists,8)); var('xSuspendedTaskList',0x200,lists)
        var('xDelayedTaskList1',0x240,lists);var('xDelayedTaskList2',0x280,lists)
        var('xTasksWaitingTermination',0x2c0,lists);var('xQueueRegistry',0x300,array(registry,1))
        self.u32(self.BASE,self.A);self.u32(self.BASE+4,3);self.u32(self.BASE+8,1000)
        for i in range(8):self.linked_list(self.BASE+0x100+i*20,[])
        for offset in (0x200,0x240,0x280,0x2c0):self.linked_list(self.BASE+offset,[])
        self.linked_list(self.BASE+0x100+5*20,[(self.A+4,self.A)])
        self.linked_list(self.BASE+0x200,[(self.B+4,self.B)])
        self.linked_list(self.BASE+0x240,[(self.OWNER+4,self.OWNER)])
        for i,(handle,name,priority) in enumerate(((self.A,'Control',5),(self.B,'Telemetry',3),(self.OWNER,'Logger',3))):
            stack=self.BASE+0x4000+i*0x400
            self.u32(handle,stack+256);self.u32(handle+44,priority);self.u32(handle+48,stack)
            self.put(handle+52,name.encode()+b'\0')
            self.u32(handle+68,stack+508);self.u32(handle+72,2 if handle==self.OWNER else priority)
            self.u32(handle+76,100);self.u32(handle+80,i+1)
            self.put(stack,b'\xa5'*(64 if handle==self.B else 128))
        self.linked_list(self.QUEUE+12,[])
        self.linked_list(self.QUEUE+32,[(self.B+24,self.B)])
        self.u32(self.QUEUE+4,self.OWNER);self.u32(self.QUEUE+56,1)
        self.put(self.QUEUE+64,b'\x01')
        self.u32(self.BASE+0x300,self.BASE+0x380);self.u32(self.BASE+0x304,self.QUEUE)
        self.put(self.BASE+0x380,b'mutexLog\0')

    def put(self,address,data):
        offset=address-self.BASE
        self.memory[offset:offset+len(data)]=data

    def u32(self,address,value):
        self.put(address,struct.pack('<I',value))

    def read(self,address,size):
        return self.memory[address-self.BASE:address-self.BASE+size]

    def linked_list(self,address,nodes):
        sentinel=address+8
        self.u32(address,len(nodes));self.u32(address+4,sentinel)
        self.u32(sentinel+4,nodes[0][0] if nodes else sentinel)
        self.u32(sentinel+8,nodes[-1][0] if nodes else sentinel)
        for index,(node,owner) in enumerate(nodes):
            self.u32(node,100)
            self.u32(node+4,nodes[index+1][0] if index+1<len(nodes) else sentinel)
            self.u32(node+8,nodes[index-1][0] if index else sentinel)
            self.u32(node+12,owner);self.u32(node+16,address)


def test_tasks_indefinite_wait_mutex_owner_stack_and_cpu():
    image=KernelImage();inspector=FreeRtosInspector(image.layout)
    first=inspector.inspect(image.read,halted=False)
    assert first['status']=='ready',first
    by_handle={t['handle']:t for t in first['tasks']}
    assert by_handle[image.A]['state']=='running'
    assert by_handle[image.B]['state']=='blocked'  # indefinite wait on suspended list
    assert by_handle[image.B]['waitingObject']==image.QUEUE
    assert by_handle[image.B]['minFreeStackBytes']==64
    assert first['objects'][0]['owner']==image.OWNER
    assert all(t['cpuPercent'] is None for t in first['tasks'])
    for handle,increment in ((image.A,150),(image.B,200),(image.OWNER,150)):
        image.u32(handle+76,100+increment)
    image.u32(image.BASE+8,1500)
    second=inspector.inspect(image.read,halted=False)
    assert [t['cpuPercent'] for t in second['tasks']]==[30,40,30]
    assert second['quality']=='runningApproximate'


def test_corrupt_list_preserves_last_good_snapshot_and_does_not_follow_mmio():
    image=KernelImage();inspector=FreeRtosInspector(image.layout)
    first=inspector.inspect(image.read,halted=True)
    image.u32(image.B+8,0x40000000)
    calls=[]
    def read(address,size):
        calls.append(address)
        return image.read(address,size)
    failed=inspector.inspect(read,halted=False)
    assert failed['status']=='inconsistent'
    assert failed['stale'] is True
    assert failed['sequence']==first['sequence']
    assert 0x40000000 not in calls


def test_mutation_during_read_rejects_the_whole_snapshot():
    image=KernelImage();inspector=FreeRtosInspector(image.layout)
    reads=0
    def read(address,size):
        nonlocal reads
        if address==image.A+4:
            reads+=1
            if reads>=2:image.u32(image.A+12,0)
        return image.read(address,size)
    result=inspector.inspect(read,halted=False)
    assert result['status']=='inconsistent'
    assert not result['stale']


def test_missing_runtime_counter_and_stack_end_are_unknown_not_zero():
    image=KernelImage()
    tcb=image.layout.types['TCB_t']
    del tcb.fields['ulRunTimeCounter'];del tcb.fields['pxEndOfStack']
    result=FreeRtosInspector(image.layout).inspect(image.read,halted=True)
    assert result['status']=='ready'
    assert all(t['cpuPercent'] is None and t['stackBytes'] is None and t['minFreeStackBytes'] is None for t in result['tasks'])
    assert next(d for d in result['diagnostics'] if d['key']=='cpu')['status']=='unavailable'


def test_counter_wrap_reset_and_task_lifetime_do_not_generate_spikes():
    image=KernelImage();inspector=FreeRtosInspector(image.layout)
    for h in (image.A,image.B,image.OWNER):image.u32(h+76,0xfffffff0)
    inspector.inspect(image.read,halted=False)
    for h in (image.A,image.B,image.OWNER):image.u32(h+76,16)
    wrapped=inspector.inspect(image.read,halted=False)
    assert all(abs(t['cpuPercent']-100/3)<.001 for t in wrapped['tasks'])
    image.u32(image.B+80,999)  # allocator reused a handle for another task
    replaced=inspector.inspect(image.read,halted=False)
    assert all(t['cpuPercent'] is None for t in replaced['tasks'])
    inspector.invalidate(clear=True)
    assert inspector.last is None


def test_smp_and_empty_symbols_are_explicitly_unsupported():
    image=KernelImage();image.layout.variables['pxCurrentTCBs']=CVariable('pxCurrentTCBs',image.BASE,scalar())
    assert FreeRtosInspector(image.layout).inspect(image.read,halted=True)['status']=='unsupported'
    assert FreeRtosInspector().inspect(lambda *_:pytest.fail('must not read'),halted=False)['status']=='symbolsRequired'


def test_indefinite_notification_wait_is_blocked_not_explicitly_suspended():
    image=KernelImage()
    image.u32(image.BASE+0x304,0)  # do not enumerate the synthetic mutex
    image.u32(image.B+40,0)       # no event-list container for notification waits
    image.put(image.B+88,b'\x01')
    snapshot=FreeRtosInspector(image.layout).inspect(image.read,halted=True)
    assert snapshot['tasks'][1]['state']=='blocked'


def test_pending_ready_event_list_overrides_old_delayed_or_suspended_membership():
    image=KernelImage()
    image.u32(image.BASE+0x304,0)
    address=image.BASE+0x400
    image.layout.variables['xPendingReadyList']=CVariable('xPendingReadyList',address,image.layout.types['List_t'])
    image.linked_list(address,[(image.B+24,image.B)])
    snapshot=FreeRtosInspector(image.layout).inspect(image.read,halted=True)
    assert snapshot['status']=='ready'
    assert snapshot['tasks'][1]['state']=='ready'


def test_budget_rejects_large_or_out_of_range_reads_before_transport():
    calls=[]
    budget=ReadBudget(lambda a,n:calls.append(a) or bytes(n),[(0x20000000,0x20001000)],'little')
    for address,size in ((0x40000000,4),(0x20000000,8192)):
        with pytest.raises(SnapshotInvalid):budget.block(address,size)
    assert not calls


def test_unavailable_resource_domain_does_not_hide_valid_tasks():
    image=KernelImage()
    image.u32(image.B+28,0x40000000)  # corrupt only the object's waiting list
    snapshot=FreeRtosInspector(image.layout).inspect(image.read,halted=True)
    assert snapshot['status']=='ready'
    assert len(snapshot['tasks'])==3
    assert snapshot['objects']==[]
    assert all(t['waitingObject'] is None for t in snapshot['tasks'])
    assert next(d for d in snapshot['diagnostics'] if d['key']=='objects')['status']=='unavailable'


def test_optional_public_api_snapshot_can_report_zero_stack_margin():
    image=KernelImage();u32=scalar()
    task=record('TalFreeRtosTask',16,handle=(0,u32),minFreeStackBytes=(4,u32),stackBytes=(8,u32),entry=(12,u32))
    info=record('TalFreeRtosInfo',100,magic=(0,u32),abi=(4,u32),sequence=(8,u32),tickHz=(12,u32),runtimeHz=(16,u32),
                version=(20,array(scalar(1),24)),taskCount=(44,u32),truncated=(48,u32),tasks=(52,array(task,3)))
    address=image.BASE+0x700
    image.layout.variables['tal_freertos_info']=CVariable('tal_freertos_info',address,info)
    for offset,value in ((0,0x54414c46),(4,1),(8,2),(12,1000),(44,3)):
        image.u32(address+offset,value)
    image.put(address+20,b'10.4.6\0')
    for i,handle in enumerate((image.A,image.B,image.OWNER)):
        image.u32(address+52+i*16,handle)
        image.u32(address+56+i*16,0 if i==0 else 96)
        image.u32(address+60+i*16,512)
    snapshot=FreeRtosInspector(image.layout).inspect(image.read,halted=True)
    assert snapshot['status']=='ready'
    assert snapshot['version']=='10.4.6'
    assert snapshot['tickHz']==1000
    assert snapshot['tasks'][0]['minFreeStackBytes']==0
    assert snapshot['tasks'][0]['stackWatermarkSource']=='kernelApi'
