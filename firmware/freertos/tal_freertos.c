#include "tal_freertos.h"
#include <string.h>
#include <limits.h>

volatile TalFreeRtosInfo tal_freertos_info = {
  .magic = 0x54414C46u,
  .abi = 1u,
  .tickHz = configTICK_RATE_HZ,
  .version = tskKERNEL_VERSION_NUMBER
};

static TaskStatus_t taskStatus[TAL_FREERTOS_MAX_TASKS];
static TalFreeRtosTask registrations[TAL_FREERTOS_MAX_TASKS];

static void barrier(void) {
#if (defined(__GNUC__) || defined(__clang__)) && \
    ((defined(__ARM_ARCH) && (__ARM_ARCH >= 7)) || defined(__ARM_ARCH_6M__))
  __asm volatile("dmb" ::: "memory");
#elif defined(__GNUC__) || defined(__clang__)
  __asm volatile("" ::: "memory");
#elif defined(portMEMORY_BARRIER)
  portMEMORY_BARRIER();
#endif
}

void TalFreeRtos_Init(uint32_t runtimeHz) {
  tal_freertos_info.runtimeHz = runtimeHz;
}

BaseType_t TalFreeRtos_RegisterTask(TaskHandle_t task, TaskFunction_t entry,
                                  size_t stackBytes) {
  UBaseType_t i;
  BaseType_t result = pdFAIL;
  TaskStatus_t status;
  if (task == NULL || stackBytes > UINT32_MAX) return pdFAIL;
  vTaskGetInfo(task, &status, pdFALSE, eInvalid);
  taskENTER_CRITICAL();
  for (i = 0; i < TAL_FREERTOS_MAX_TASKS; ++i) {
    if (registrations[i].handle == (uintptr_t)task) break;
  }
  if (i == TAL_FREERTOS_MAX_TASKS) {
    for (i = 0; i < TAL_FREERTOS_MAX_TASKS; ++i) {
      if (registrations[i].handle == 0) break;
    }
  }
  if (i < TAL_FREERTOS_MAX_TASKS) {
    registrations[i].handle = (uintptr_t)task;
    registrations[i].taskNumber = status.xTaskNumber;
    registrations[i].entry = (uintptr_t)entry;
    registrations[i].stackBytes = (uint32_t)stackBytes;
    result = pdPASS;
  }
  taskEXIT_CRITICAL();
  return result;
}

void TalFreeRtos_UnregisterTask(TaskHandle_t task) {
  UBaseType_t i;
  taskENTER_CRITICAL();
  for (i = 0; i < TAL_FREERTOS_MAX_TASKS; ++i) {
    if (registrations[i].handle == (uintptr_t)task) {
      memset(&registrations[i], 0, sizeof(registrations[i]));
    }
  }
  taskEXIT_CRITICAL();
}

void TalFreeRtos_Update(void) {
  UBaseType_t i, j, count;
  count = uxTaskGetSystemState(taskStatus, TAL_FREERTOS_MAX_TASKS, NULL);
  ++tal_freertos_info.sequence;
  barrier();
  tal_freertos_info.taskCount = count;
  tal_freertos_info.truncated = (count == 0 && uxTaskGetNumberOfTasks() != 0);
  for (i = 0; i < count; ++i) {
    uint64_t bytes = (uint64_t)taskStatus[i].usStackHighWaterMark * sizeof(StackType_t);
    tal_freertos_info.tasks[i].handle = (uintptr_t)taskStatus[i].xHandle;
    tal_freertos_info.tasks[i].taskNumber = taskStatus[i].xTaskNumber;
    tal_freertos_info.tasks[i].minFreeStackBytes = bytes > UINT32_MAX ? UINT32_MAX : (uint32_t)bytes;
    tal_freertos_info.tasks[i].stackBytes = 0;
    tal_freertos_info.tasks[i].entry = 0;
    taskENTER_CRITICAL();
    for (j = 0; j < TAL_FREERTOS_MAX_TASKS; ++j) {
      if (registrations[j].handle == (uintptr_t)taskStatus[i].xHandle &&
          registrations[j].taskNumber == taskStatus[i].xTaskNumber) {
        tal_freertos_info.tasks[i].stackBytes = registrations[j].stackBytes;
        tal_freertos_info.tasks[i].entry = registrations[j].entry;
        break;
      }
    }
    taskEXIT_CRITICAL();
  }
  barrier();
  ++tal_freertos_info.sequence;
}
