import Flutter
import UIKit
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var mdnsEventSink: FlutterEventSink?
  private let serviceType = "_baby-monitor._tcp."
  private var advertiser: NetService?
  private var browser: NetServiceBrowser?
  private var discovered: [NetService] = []
  private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "mdns")

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
        if let args = call.arguments as? [String: Any] {
          self.startAdvertise(args: args)
        }
        result(nil)
      case "stop":
        self.stopMdns()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    mdnsEvents.setStreamHandler(MdnsStreamHandler())

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func startAdvertise(args: [String: Any]) {
    stopMdns()
    let port = args["servicePort"] as? Int ?? 48080
    let name = "\(args["monitorName"] as? String ?? "monitor")-\(args["deviceId"] as? String ?? "id")"
    os_log(
      "Starting mDNS advertise name=%{public}@ port=%{public}d deviceId=%{public}@",
      log: log,
      type: .info,
      name,
      port,
      args["deviceId"] as? String ?? ""
    )
    advertiser = NetService(domain: "local.", type: serviceType, name: name, port: Int32(port))
    let txt: [String: Data] = [
      "deviceId": (args["deviceId"] as? String ?? "").data(using: .utf8) ?? Data(),
      "monitorName": (args["monitorName"] as? String ?? "").data(using: .utf8) ?? Data(),
      "certFingerprint": (args["certFingerprint"] as? String ?? "").data(using: .utf8) ?? Data(),
      "version": "\(args["version"] ?? "1")".data(using: .utf8) ?? Data(),
    ]
    advertiser?.setTXTRecord(NetService.data(fromTXTRecord: txt))
    advertiser?.publish()
  }

  private func startBrowse(eventSink: @escaping FlutterEventSink) {
    browser = NetServiceBrowser()
    browser?.delegate = self
    mdnsEventSink = eventSink
    os_log("Starting mDNS browse", log: log, type: .info)
    browser?.searchForServices(ofType: serviceType, inDomain: "local.")
  }

  private func stopMdns() {
    os_log("Stopping mDNS advertise/browse", log: log, type: .info)
    advertiser?.stop()
    advertiser = nil
    browser?.stop()
    browser = nil
    discovered.removeAll()
  }
}

class MdnsStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    if let delegate = UIApplication.shared.delegate as? AppDelegate {
      delegate.startBrowse(eventSink: events)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    if let delegate = UIApplication.shared.delegate as? AppDelegate {
      delegate.stopMdns()
    }
    return nil
  }
}

extension AppDelegate: NetServiceBrowserDelegate, NetServiceDelegate {
  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    discovered.append(service)
    service.delegate = self
    os_log(
      "Found service %{public}@ host=%{public}@",
      log: log,
      type: .info,
      service.name,
      service.hostName ?? "unknown"
    )
    service.resolve(withTimeout: 5.0)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard let txtData = sender.txtRecordData() else { return }
    let txtDict = NetService.dictionary(fromTXTRecord: txtData)
    func decode(_ key: String) -> String {
      if let data = txtDict[key], let str = String(data: data, encoding: .utf8) {
        return str
      }
      return ""
    }
    var ipString: String?
    for addrData in sender.addresses ?? [] {
      addrData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
        let sockaddr = pointer.bindMemory(to: sockaddr.self)
        if sockaddr.count > 0 {
          if sockaddr[0].sa_family == sa_family_t(AF_INET) {
            let data = pointer.bindMemory(to: sockaddr_in.self)
            var addr = data[0].sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            ipString = String(cString: buffer)
          }
        }
      }
      if ipString != nil { break }
    }
    let payload: [String: Any?] = [
      "remoteDeviceId": decode("deviceId"),
      "monitorName": decode("monitorName").isEmpty ? sender.name : decode("monitorName"),
      "certFingerprint": decode("certFingerprint"),
      "servicePort": sender.port,
      "version": Int(decode("version")) ?? 1,
      "ip": ipString,
    ]
    mdnsEventSink?(payload)
    os_log(
      "Resolved service remoteDeviceId=%{public}@ ip=%{public}@ port=%{public}d",
      log: log,
      type: .info,
      decode("deviceId"),
      ipString ?? "unknown",
      sender.port
    )
  }
}
