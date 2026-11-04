"""Exercise real DWARF, relocations and memory reads with an ARM cross compiler."""
import shutil
import subprocess
from pathlib import Path

import pytest

from take_a_look_backend.services.elf_context import ElfLoadContext
from take_a_look_backend.services.freertos_layout import FreeRtosLayout
from take_a_look_backend.services.freertos import FreeRtosInspector


@pytest.mark.parametrize('alter_layout',[False,True])
@pytest.mark.parametrize('dwarf_version',[4,5])
def test_arm_elf_drives_all_offsets_and_typed_global_handles(tmp_path,alter_layout,dwarf_version):
    compiler=shutil.which('arm-none-eabi-gcc')
    if compiler is None:
        pytest.skip('ARM cross compiler not installed')
    source=Path(__file__).parent/'fixtures'/'freertos_kernel.c'
    elf_path=tmp_path/'kernel.elf'
    command=[compiler,'-g3',f'-gdwarf-{dwarf_version}','-O0','-mcpu=cortex-m4','-mthumb','-nostdlib',
             '-fno-eliminate-unused-debug-types','-Wl,--entry=_start','-Wl,-Ttext=0x08000000',
             '-Wl,-Tdata=0x20000000',str(source),'-o',str(elf_path)]
    if alter_layout:command.insert(1,'-DALTER_LAYOUT=1')
    subprocess.run(command,check=True,capture_output=True,timeout=30)
    with ElfLoadContext(elf_path) as context:
        layout=FreeRtosLayout.from_context(context)
        segments=[(int(s['sh_addr']),bytearray(int(s['sh_size'])) if s['sh_type']=='SHT_NOBITS' else bytearray(s.data()))
                  for s in context.elf.iter_sections() if s['sh_flags']&2 and s['sh_size'] and s['sh_addr']]
    assert not layout.problem
    assert layout.pointer_size==4
    assert layout.types['TCB_t'].member('uxPriority')[0]==(72 if alter_layout else 44)
    def read(address,size):
        for start,data in segments:
            if start<=address and address+size<=start+len(data):
                return data[address-start:address-start+size]
        raise AssertionError(f'unmapped {address:X}+{size}')
    snapshot=FreeRtosInspector(layout).inspect(read,halted=True,tick_hz=1000)
    assert snapshot['status']=='ready',snapshot
    assert [t['name'] for t in snapshot['tasks']]==['Control','Telemetry']
    assert snapshot['tasks'][1]['minFreeStackBytes']==64
    assert len(snapshot['tasks'][0]['notifications'])==2
    objects={o['name']:o for o in snapshot['objects']}
    assert objects['mutexLog']['kind']=='mutex'
    assert objects['mutexLog']['waiters']==[snapshot['tasks'][1]['handle']]
    assert objects['evNetwork']['bits']==5
    assert objects['streamUart']['count']==128
    assert snapshot['timers'][0]['name']=='Heartbeat'
    assert snapshot['timers'][0]['periodMs']==1000
    assert snapshot['timers'][0]['autoReload'] is True
