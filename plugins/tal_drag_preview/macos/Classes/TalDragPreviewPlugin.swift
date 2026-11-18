import Cocoa
import FlutterMacOS

private final class PlotTrackpadDirection: NSGestureRecognizer {
  private let channel: FlutterMethodChannel
  private var separation: NSPoint?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "take_a_look/plot_trackpad", binaryMessenger: messenger)
    super.init(target: nil, action: nil)
    allowedTouchTypes = .indirect
  }

  required init?(coder: NSCoder) {
    fatalError("PlotTrackpadDirection is installed programmatically")
  }

  // AppKit's magnify events supply scale but don't reliably carry the touches.
  // Observe the contacts without claiming the gesture from Flutter's view.
  private func updateDirection(from event: NSEvent) {
    let touches = Array(event.touches(matching: .touching, in: view).filter { !$0.isResting })
    guard touches.count == 2,
          (touches[0].device as AnyObject?) === (touches[1].device as AnyObject?) else {
      report(nil)
      return
    }
    let first = touches[0].normalizedPosition
    let second = touches[1].normalizedPosition
    let size = touches[0].deviceSize
    report(NSPoint(x: abs(second.x - first.x) * size.width,
                   y: abs(second.y - first.y) * size.height))
  }

  private func report(_ span: NSPoint?) {
    guard separation != span else { return }
    separation = span
    channel.invokeMethod("direction", arguments: span.map { [Double($0.x), Double($0.y)] })
  }

  override func touchesBegan(with event: NSEvent) { updateDirection(from: event) }
  override func touchesMoved(with event: NSEvent) { updateDirection(from: event) }
  override func touchesEnded(with event: NSEvent) { updateDirection(from: event) }
  override func touchesCancelled(with event: NSEvent) { report(nil) }
  override func reset() {
    super.reset()
    report(nil)
  }
}

public class TalDragPreviewPlugin: NSObject, FlutterPlugin {
  private var registrar: FlutterPluginRegistrar?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "take_a_look/drag_preview_window",
      binaryMessenger: registrar.messenger)
    let instance = TalDragPreviewPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.view?.superview?.addGestureRecognizer(PlotTrackpadDirection(messenger: registrar.messenger))
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setClickThrough",
          let arguments = call.arguments as? [String: Any],
          let enabled = arguments["enabled"] as? Bool else {
      result(FlutterMethodNotImplemented)
      return
    }
    registrar?.view?.window?.ignoresMouseEvents = enabled
    result(nil)
  }
}
