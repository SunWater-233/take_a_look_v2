#ifndef TAL_FREERTOS_H
#define TAL_FREERTOS_H

#include <stddef.h>
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"

/* Optional telemetry helper. Call Update from one low-priority task, 1-2 Hz.
 * The workstation also inspects FreeRTOS directly without this module.
 * Keep this buffer coherent with the debug access port on cached targets.
 */
#ifndef TAL_FREERTOS_MAX_TASKS
#define TAL_FREERTOS_MAX_TASKS 32
#endif
#if TAL_FREERTOS_MAX_TASKS > 64
#error "TAL_FREERTOS_MAX_TASKS must be <= 64"
#endif
#if configUSE_TRACE_FACILITY != 1
#error "TalFreeRtos requires configUSE_TRACE_FACILITY=1"
#endif

typedef struct {
  uintptr_t handle;
  uint32_t taskNumber;
  uint32_t minFreeStackBytes;
  uint32_t stackBytes;
  uintptr_t entry;
} TalFreeRtosTask;

typedef struct {
  uint32_t magic;
  uint32_t abi;
  uint32_t sequence;
  uint32_t tickHz;
  uint32_t runtimeHz;
  char version[24];
  uint32_t taskCount;
  uint32_t truncated;
  TalFreeRtosTask tasks[TAL_FREERTOS_MAX_TASKS];
} TalFreeRtosInfo;

#ifdef __cplusplus
extern "C" {
#endif
extern volatile TalFreeRtosInfo tal_freertos_info;
/* runtimeHz is descriptive; use 0 when run-time statistics are disabled. */
void TalFreeRtos_Init(uint32_t runtimeHz);
void TalFreeRtos_Update(void);
/* Register just after creating a task when its entry / stack budget is known.
 * Use one registration per task handle. Re-register if a handle is reused. */
BaseType_t TalFreeRtos_RegisterTask(TaskHandle_t task, TaskFunction_t entry,
                                  size_t stackBytes);
void TalFreeRtos_UnregisterTask(TaskHandle_t task);
#ifdef __cplusplus
}
#endif
#endif
