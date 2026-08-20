import Cocoa
import FlutterMacOS

public class TalDragPreviewPlugin: NSObject, FlutterPlugin {
  private var registrar: FlutterPluginRegistrar?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "take_a_look/drag_preview_window",
      binaryMessenger: registrar.messenger)
    let instance = TalDragPreviewPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
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
