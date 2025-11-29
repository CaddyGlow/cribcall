import Flutter
import UIKit
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate {
  // MARK: - mDNS
  private var mdnsEventSink: FlutterEventSink?
  private let serviceType = "_baby-monitor._tcp."
  private var advertiser: NetService?
  private var browser: NetServiceBrowser?
  private var discovered: [NetService] = []
  private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "app_delegate")

  // MARK: - Monitor Server
  private var monitorEventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
    let messenger = controller.binaryMessenger

    // Setup all platform channels
    setupMdnsChannels(messenger: messenger)
    setupAudioChannels(messenger: messenger)
    setupMonitorServerChannels(messenger: messenger)

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - mDNS Channels

  private func setupMdnsChannels(messenger: FlutterBinaryMessenger) {
    let mdnsChannel = FlutterMethodChannel(name: "cribcall/mdns", binaryMessenger: messenger)
    let mdnsEvents = FlutterEventChannel(name: "cribcall/mdns_events", binaryMessenger: messenger)

    mdnsChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "startAdvertise":
        if let args = call.arguments as? [String: Any] {
          self?.startAdvertise(args: args)
        }
        result(nil)
      case "stop":
        self?.stopMdns()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    mdnsEvents.setStreamHandler(MdnsStreamHandler())
  }

  // MARK: - Audio Channels

  private func setupAudioChannels(messenger: FlutterBinaryMessenger) {
    let audioChannel = FlutterMethodChannel(name: "cribcall/audio", binaryMessenger: messenger)
    let audioEvents = FlutterEventChannel(name: "cribcall/audio_events", binaryMessenger: messenger)

    audioChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "hasPermission":
        result(AudioCaptureService.shared.hasPermission())

      case "requestPermission":
        AudioCaptureService.shared.requestPermission { granted in
          result(granted)
        }

      case "start":
        let mdnsParams = call.arguments as? [String: Any]
        AudioCaptureService.shared.start(mdnsParams: mdnsParams)
        result(nil)

      case "stop":
        AudioCaptureService.shared.stop()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    audioEvents.setStreamHandler(AudioCaptureStreamHandler())
  }

  // MARK: - Monitor Server Channels

  private func setupMonitorServerChannels(messenger: FlutterBinaryMessenger) {
    let serverChannel = FlutterMethodChannel(name: "cribcall/monitor_server", binaryMessenger: messenger)
    let serverEvents = FlutterEventChannel(name: "cribcall/monitor_events", binaryMessenger: messenger)

    // Setup callbacks from MonitorService to emit events
    MonitorService.shared.onServerStarted = { [weak self] port in
      DispatchQueue.main.async {
        self?.monitorEventSink?(["event": "serverStarted", "port": port])
      }
    }

    MonitorService.shared.onServerError = { [weak self] error in
      DispatchQueue.main.async {
        self?.monitorEventSink?(["event": "serverError", "error": error])
      }
    }

    MonitorService.shared.onClientConnected = { [weak self] connectionId, fingerprint, remoteAddress in
      DispatchQueue.main.async {
        self?.monitorEventSink?([
          "event": "clientConnected",
          "connectionId": connectionId,
          "fingerprint": fingerprint,
          "remoteAddress": remoteAddress
        ])
      }
    }

    MonitorService.shared.onClientDisconnected = { [weak self] connectionId, reason in
      DispatchQueue.main.async {
        self?.monitorEventSink?([
          "event": "clientDisconnected",
          "connectionId": connectionId,
          "reason": reason as Any
        ])
      }
    }

    MonitorService.shared.onWsMessage = { [weak self] connectionId, message in
      DispatchQueue.main.async {
        self?.monitorEventSink?([
          "event": "wsMessage",
          "connectionId": connectionId,
          "message": message
        ])
      }
    }

    MonitorService.shared.onHttpRequest = { [weak self] requestId, method, path, fingerprint, body in
      DispatchQueue.main.async {
        self?.monitorEventSink?([
          "event": "httpRequest",
          "requestId": requestId,
          "method": method,
          "path": path,
          "fingerprint": fingerprint as Any,
          "body": body as Any
        ])
      }
    }

    serverChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        guard let args = call.arguments as? [String: Any],
              let port = args["port"] as? Int,
              let identityJson = args["identityJson"] as? String,
              let trustedPeersJson = args["trustedPeersJson"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing required arguments", details: nil))
          return
        }
        MonitorService.shared.start(port: port, identityJson: identityJson, trustedPeersJson: trustedPeersJson)
        result(nil)

      case "stop":
        MonitorService.shared.stop()
        result(nil)

      case "isRunning":
        result(MonitorService.shared.isRunning)

      case "addTrustedPeer":
        guard let args = call.arguments as? [String: Any],
              let peerJson = args["peerJson"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing peerJson", details: nil))
          return
        }
        MonitorService.shared.addTrustedPeer(peerJson: peerJson)
        result(nil)

      case "removeTrustedPeer":
        guard let args = call.arguments as? [String: Any],
              let fingerprint = args["fingerprint"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing fingerprint", details: nil))
          return
        }
        MonitorService.shared.removeTrustedPeer(fingerprint: fingerprint)
        result(nil)

      case "broadcast":
        guard let args = call.arguments as? [String: Any],
              let messageJson = args["messageJson"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing messageJson", details: nil))
          return
        }
        MonitorService.shared.broadcast(messageJson: messageJson)
        result(nil)

      case "sendTo":
        guard let args = call.arguments as? [String: Any],
              let connectionId = args["connectionId"] as? String,
              let messageJson = args["messageJson"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing connectionId or messageJson", details: nil))
          return
        }
        MonitorService.shared.sendTo(connectionId: connectionId, messageJson: messageJson)
        result(nil)

      case "respondHttp":
        guard let args = call.arguments as? [String: Any],
              let requestId = args["requestId"] as? String,
              let statusCode = args["statusCode"] as? Int else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing requestId or statusCode", details: nil))
          return
        }
        let bodyJson = args["bodyJson"] as? String
        MonitorService.shared.respondHttp(requestId: requestId, statusCode: statusCode, bodyJson: bodyJson)
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    serverEvents.setStreamHandler(MonitorServerStreamHandler { [weak self] sink in
      self?.monitorEventSink = sink
    } onCancel: { [weak self] in
      self?.monitorEventSink = nil
    })
  }

  // MARK: - mDNS Implementation

  private func startAdvertise(args: [String: Any]) {
    stopMdns()
    let controlPort = args["servicePort"] as? Int ?? 48080
    let pairingPort = args["pairingPort"] as? Int ?? 48081
    let remoteDeviceId = args["deviceId"] as? String ?? ""
    let monitorName = args["monitorName"] as? String ?? "monitor"
    let name = "\(monitorName)-\(remoteDeviceId)"
    os_log(
      "Starting mDNS advertise name=%{public}@ controlPort=%{public}d remoteDeviceId=%{public}@",
      log: log,
      type: .info,
      name,
      controlPort,
      remoteDeviceId
    )
    advertiser = NetService(domain: "local.", type: serviceType, name: name, port: Int32(controlPort))
    // TXT record keys aligned with Android: remoteDeviceId, monitorName, monitorCertFingerprint,
    // controlPort, pairingPort, version, transport
    let txt: [String: Data] = [
      "remoteDeviceId": remoteDeviceId.data(using: .utf8) ?? Data(),
      "monitorName": monitorName.data(using: .utf8) ?? Data(),
      "monitorCertFingerprint": (args["certFingerprint"] as? String ?? "").data(using: .utf8) ?? Data(),
      "controlPort": "\(controlPort)".data(using: .utf8) ?? Data(),
      "pairingPort": "\(pairingPort)".data(using: .utf8) ?? Data(),
      "version": "\(args["version"] ?? 1)".data(using: .utf8) ?? Data(),
      "transport": "http-ws".data(using: .utf8) ?? Data(),
    ]
    advertiser?.setTXTRecord(NetService.data(fromTXTRecord: txt))
    advertiser?.publish()
  }

  func startBrowse(eventSink: @escaping FlutterEventSink) {
    browser = NetServiceBrowser()
    browser?.delegate = self
    mdnsEventSink = eventSink
    os_log("Starting mDNS browse", log: log, type: .info)
    browser?.searchForServices(ofType: serviceType, inDomain: "local.")
  }

  func stopMdns() {
    os_log("Stopping mDNS advertise/browse", log: log, type: .info)
    advertiser?.stop()
    advertiser = nil
    browser?.stop()
    browser = nil
    discovered.removeAll()
  }
}

// MARK: - Stream Handlers

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

class MonitorServerStreamHandler: NSObject, FlutterStreamHandler {
  private let onListen: (FlutterEventSink?) -> Void
  private let onCancelHandler: () -> Void

  init(onListen: @escaping (FlutterEventSink?) -> Void, onCancel: @escaping () -> Void) {
    self.onListen = onListen
    self.onCancelHandler = onCancel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListen(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelHandler()
    return nil
  }
}

// MARK: - NetService Delegates

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
    // Read TXT keys aligned with Android: remoteDeviceId, monitorName, monitorCertFingerprint,
    // controlPort, pairingPort, version, transport
    let remoteDeviceId = decode("remoteDeviceId")
    let monitorName = decode("monitorName").isEmpty ? sender.name : decode("monitorName")
    let controlPort = Int(decode("controlPort")) ?? sender.port
    let pairingPort = Int(decode("pairingPort")) ?? 48081
    let version = Int(decode("version")) ?? 1
    let transport = decode("transport").isEmpty ? "http-ws" : decode("transport")
    let certFingerprint = decode("monitorCertFingerprint")

    let payload: [String: Any?] = [
      "remoteDeviceId": remoteDeviceId,
      "monitorName": monitorName,
      "certFingerprint": certFingerprint,
      "controlPort": controlPort,
      "pairingPort": pairingPort,
      "version": version,
      "transport": transport,
      "ip": ipString,
    ]
    mdnsEventSink?(payload)
    os_log(
      "Resolved service remoteDeviceId=%{public}@ ip=%{public}@ controlPort=%{public}d pairingPort=%{public}d transport=%{public}@",
      log: log,
      type: .info,
      remoteDeviceId,
      ipString ?? "unknown",
      controlPort,
      pairingPort,
      transport
    )
  }
}
