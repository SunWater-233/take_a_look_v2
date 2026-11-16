/* Synthetic ARM memory image. Tests deliberately vary the TCB's layout.
 * This is a fixture, not an RTOS implementation or a runnable application. */
typedef unsigned int U32;
typedef unsigned char U8;
typedef struct tskTaskControlBlock *TaskHandle_t;
typedef struct xLIST_ITEM {
  U32 xItemValue;
  struct xLIST_ITEM *pxNext, *pxPrevious;
  void *pvOwner;
#ifdef LEGACY_LIST_CONTAINER
  void *pvContainer;
#else
  void *pxContainer;
#endif
} ListItem_t;
typedef struct {U32 xItemValue; ListItem_t *pxNext, *pxPrevious;} MiniListItem_t;
typedef struct xLIST {U32 uxNumberOfItems; ListItem_t *pxIndex; MiniListItem_t xListEnd;} List_t;
typedef struct tskTaskControlBlock {
  U32 *pxTopOfStack;
  ListItem_t xStateListItem, xEventListItem;
#ifdef ALTER_LAYOUT
  U32 unrelatedVendorFields[7];
#endif
  U32 uxPriority;
  U32 *pxStack;
  char pcTaskName[16];
  U32 *pxEndOfStack;
  U32 uxBasePriority, ulRunTimeCounter, uxTCBNumber;
  U32 ulNotifiedValue[2];
  U8 ucNotifyState[2];
} TCB_t;
typedef struct QueueDefinition {
  void *pcHead;
  union {struct {TaskHandle_t xMutexHolder; U32 uxRecursiveCallCount;} xSemaphore;} u;
  List_t xTasksWaitingToSend, xTasksWaitingToReceive;
  U32 uxMessagesWaiting, uxLength, uxItemSize;
  U8 ucQueueType;
} Queue_t;
typedef struct EventGroupDef_t {U32 uxEventBits; List_t xTasksWaitingForBits;} EventGroup_t;
typedef struct StreamBufferDef_t {
  U32 xHead,xTail,xLength,xTriggerLevelBytes;
  TaskHandle_t xTaskWaitingToReceive,xTaskWaitingToSend;
  U8 ucFlags;
} StreamBuffer_t;
typedef struct tmrTimerControl {
  const char *pcTimerName;
  ListItem_t xTimerListItem;
  U32 xTimerPeriodInTicks;
  void *pvTimerID;
  void (*pxCallbackFunction)(void *);
  U8 ucStatus;
} Timer_t;
#include "freertos_exports.h"

#define SENT(list) ((ListItem_t *)&(list).xListEnd)
#define EMPTY(list) {0,SENT(list),{~0u,SENT(list),SENT(list)}}
#define ONE(list,item) {1,SENT(list),{~0u,&(item),&(item)}}
#define ITEM(list,owner) {0,SENT(list),SENT(list),&(owner),&(list)}

static TCB_t controlTask, telemetryTask;
static Queue_t logMutexBody;
static Timer_t heartbeatBody;
List_t pxReadyTasksLists[4] = {
  EMPTY(pxReadyTasksLists[0]),EMPTY(pxReadyTasksLists[1]),
  ONE(pxReadyTasksLists[2],controlTask.xStateListItem),EMPTY(pxReadyTasksLists[3])
};
List_t xSuspendedTaskList=ONE(xSuspendedTaskList,telemetryTask.xStateListItem);
List_t xDelayedTaskList1=EMPTY(xDelayedTaskList1);
List_t xDelayedTaskList2=EMPTY(xDelayedTaskList2);
List_t xTasksWaitingTermination=EMPTY(xTasksWaitingTermination);
List_t xActiveTimerList1=ONE(xActiveTimerList1,heartbeatBody.xTimerListItem);
List_t xActiveTimerList2=EMPTY(xActiveTimerList2);
static U32 controlStack[128]={[0 ... 31]=0xA5A5A5A5u};
static U32 telemetryStack[128]={[0 ... 15]=0xA5A5A5A5u};
static TCB_t controlTask={
  .pxTopOfStack=controlStack+100,.xStateListItem=ITEM(pxReadyTasksLists[2],controlTask),
  .uxPriority=2,.uxBasePriority=2,.pxStack=controlStack,.pxEndOfStack=controlStack+127,
  .pcTaskName="Control",.ulRunTimeCounter=1234,.uxTCBNumber=1
};
static TCB_t telemetryTask={
  .pxTopOfStack=telemetryStack+100,.xStateListItem=ITEM(xSuspendedTaskList,telemetryTask),
  .xEventListItem=ITEM(logMutexBody.xTasksWaitingToReceive,telemetryTask),
  .uxPriority=1,.uxBasePriority=1,.pxStack=telemetryStack,.pxEndOfStack=telemetryStack+127,
  .pcTaskName="Telemetry",.ulRunTimeCounter=456,.uxTCBNumber=2
};
TCB_t *pxCurrentTCB=&controlTask;
U32 uxCurrentNumberOfTasks=2,xTickCount=1000,uxTaskNumber=2;
static Queue_t logMutexBody={.pcHead=0,.u.xSemaphore={&controlTask,0},
  .xTasksWaitingToSend=EMPTY(logMutexBody.xTasksWaitingToSend),
  .xTasksWaitingToReceive=ONE(logMutexBody.xTasksWaitingToReceive,telemetryTask.xEventListItem),
  .uxLength=1,.ucQueueType=1
};
Queue_t *mutexLog=&logMutexBody;
static EventGroup_t networkBody={.uxEventBits=5,.xTasksWaitingForBits=EMPTY(networkBody.xTasksWaitingForBits)};
EventGroup_t *evNetwork=&networkBody;
static StreamBuffer_t uartBody={.xHead=128,.xTail=0,.xLength=256,.xTriggerLevelBytes=16};
StreamBuffer_t *streamUart=&uartBody;
static void timerCallback(void *timer){(void)timer;}
static Timer_t heartbeatBody={.pcTimerName="Heartbeat",
  .xTimerListItem={2000,SENT(xActiveTimerList1),SENT(xActiveTimerList1),&heartbeatBody,&xActiveTimerList1},
  .xTimerPeriodInTicks=1000,.pxCallbackFunction=timerCallback,.ucStatus=5};
Timer_t *heartbeat=&heartbeatBody;
void _start(void){for(;;){}}
