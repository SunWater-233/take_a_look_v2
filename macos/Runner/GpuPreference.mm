#import <FlutterMacOS/FlutterMacOS.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

// Flutter's macOS embedder currently selects a unified-memory device and has
// no public GPU preference API. This compatibility adapter runs before loadView
// creates any surfaces. Guard every internal dependency and keep the original
// renderer intact if the embedder changes or a preferred device is unusable.
@protocol TALMetalContextInitializer
- (instancetype)initWithMTLDevice:(id<MTLDevice>)device
                    commandQueue:(id<MTLCommandQueue>)commandQueue;
@end

static BOOL TALHasObjectIvar(Class type, const char* name) {
  Ivar ivar = class_getInstanceVariable(type, name);
  const char* encoding = ivar ? ivar_getTypeEncoding(ivar) : nullptr;
  return encoding && encoding[0] == '@';
}

static void TALPreferHighPerformanceGpu(FlutterEngine* engine) {
  if ([NSProcessInfo.processInfo.environment[@"TAKE_A_LOOK_GPU"]
          isEqualToString:@"system"]) return;

  // Never change the device of an engine that has already started rendering.
  if (![engine respondsToSelector:NSSelectorFromString(@"running")] ||
      !TALHasObjectIvar(engine.class, "_renderer")) return;

  @try {
    if ([[engine valueForKey:@"running"] boolValue]) return;
    NSObject* renderer = [engine valueForKey:@"renderer"];
    Class type = renderer.class;
    Class contextClass = NSClassFromString(@"FlutterDarwinContextMetalSkia");
    SEL initializer = @selector(initWithMTLDevice:commandQueue:);
    if (!renderer || !contextClass ||
        ![NSStringFromClass(type) isEqualToString:@"FlutterRenderer"] ||
        !TALHasObjectIvar(type, "_device") ||
        !TALHasObjectIvar(type, "_commandQueue") ||
        !TALHasObjectIvar(type, "_darwinMetalContext") ||
        ![contextClass instancesRespondToSelector:initializer] ||
        ![type accessInstanceVariablesDirectly]) {
      NSLog(@"Take A Look: GPU preference is unsupported by this Flutter engine; keeping its default device.");
      return;
    }

    id<MTLDevice> originalDevice = [renderer valueForKey:@"device"];
    id originalQueue = [renderer valueForKey:@"commandQueue"];
    id originalContext = [renderer valueForKey:@"darwinMetalContext"];
    // Apple silicon and systems already using a discrete GPU need no change.
    if (!originalDevice || !originalDevice.isLowPower) return;

    for (id<MTLDevice> device in MTLCopyAllDevices()) {
      if (device.isLowPower || device.registryID == originalDevice.registryID) continue;
      id<MTLCommandQueue> queue = [device newCommandQueue];
      if (!queue) continue;
      id context = [(id<TALMetalContextInitializer>)[contextClass alloc]
          initWithMTLDevice:device commandQueue:queue];
      if (!context) continue;

      // Prepare all resources first; commit a coherent device/queue/context
      // together, before Flutter creates its view or starts its engine.
      @try {
        [renderer setValue:device forKey:@"device"];
        [renderer setValue:queue forKey:@"commandQueue"];
        [renderer setValue:context forKey:@"darwinMetalContext"];
      } @catch (NSException* exception) {
        [renderer setValue:originalDevice forKey:@"device"];
        [renderer setValue:originalQueue forKey:@"commandQueue"];
        [renderer setValue:originalContext forKey:@"darwinMetalContext"];
        NSLog(@"Take A Look: GPU selection failed; keeping the default device (%@).", exception.name);
        return;
      }
      NSLog(@"Take A Look: rendering on %@.", device.name);
      return;
    }
    NSLog(@"Take A Look: no usable high-performance GPU; rendering on %@.", originalDevice.name);
  } @catch (NSException* exception) {
    NSLog(@"Take A Look: Flutter GPU compatibility check failed (%@).", exception.name);
  }
}

@interface FlutterViewController (TALGpuPreference)
- (void)tal_loadViewWithGpuPreference;
@end

@implementation FlutterViewController (TALGpuPreference)

+ (void)load {
  // This also covers controllers created internally by desktop_multi_window,
  // whose public window-created callback is too late to change the GPU.
  Method original = class_getInstanceMethod(self, @selector(loadView));
  Method replacement =
      class_getInstanceMethod(self, @selector(tal_loadViewWithGpuPreference));
  Method inherited = class_getInstanceMethod(class_getSuperclass(self), @selector(loadView));
  if (original && replacement && original != inherited) {
    method_exchangeImplementations(original, replacement);
  }
}

- (void)tal_loadViewWithGpuPreference {
  TALPreferHighPerformanceGpu(self.engine);
  [self tal_loadViewWithGpuPreference];
}

@end
