import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
    let mdnsChannel = FlutterMethodChannel(name: "cribcall/mdns", binaryMessenger: controller.binaryMessenger)
    let mdnsEvents = FlutterEventChannel(name: "cribcall/mdns_events", binaryMessenger: controller.binaryMessenger)

    mdnsChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "startAdvertise":
        // TODO: implement mDNS advertising.
        result(nil)
      case "stop":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    mdnsEvents.setStreamHandler(MdnsStreamHandler())

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

class MdnsStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    // TODO: emit mDNS browse events when available.
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return nil
  }
}
