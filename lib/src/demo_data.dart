import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

const seriesColors = <Color>[
  TalColors.accent,
  TalColors.success,
  TalColors.blue,
  TalColors.amber,
  Color(0xFFC026D3),
  Color(0xFF0891B2),
  Color(0xFFDB2777),
];

const demoSymbols = <SymbolItem>[
  SymbolItem(
    source: 'control/foc_current.c',
    name: 'iq_ref',
    address: 0x20000010,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'control/foc_current.c',
    name: 'id_ref',
    address: 0x20000014,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'control/foc_speed.c',
    name: 'speed_rpm',
    address: 0x20000020,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'control/pid.c',
    name: 'speed_pid_kp',
    address: 0x20000030,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'driver/adc.c',
    name: 'bus_voltage',
    address: 0x20000100,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'driver/adc.c',
    name: 'phase_current_a',
    address: 0x20000104,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'driver/encoder.c',
    name: 'encoder_angle',
    address: 0x20000120,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'driver/pwm.c',
    name: 'pwm_duty_a',
    address: 0x20000140,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'safety/fault.c',
    name: 'fault_code',
    address: 0x20000200,
    type: 'uint32_t',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'safety/fault.c',
    name: 'fault_latched',
    address: 0x20000204,
    type: 'bool',
    size: 1,
    section: '.bss',
  ),
  SymbolItem(
    source: 'safety/thermal.c',
    name: 'mos_temp_c',
    address: 0x20000220,
    type: 'float',
    size: 4,
    section: '.bss',
  ),
  SymbolItem(
    source: 'comms/canopen.c',
    name: 'can_rx_count',
    address: 0x20000300,
    type: 'uint32_t',
    size: 4,
    section: '.bss',
  ),
];
