import Flutter
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var bonjourBridge: BonjourDiscoveryBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      bonjourBridge = BonjourDiscoveryBridge(binaryMessenger: controller.binaryMessenger)
    }
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

private final class BonjourDiscoveryBridge: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private let channel: FlutterMethodChannel
  private let browser = NetServiceBrowser()
  private var pendingResult: FlutterResult?
  private var timeoutTimer: Timer?
  private var discovered: [String: [String: Any]] = [:]
  private var startedAt = Date()

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gscale/bonjour", binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler(handle)
    browser.delegate = self
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "discoverBonjourServices" else {
      result(FlutterMethodNotImplemented)
      return
    }

    if pendingResult != nil {
      finish()
    }

    let args = call.arguments as? [String: Any]
    let timeoutMs = max(200, args?["timeout_ms"] as? Int ?? 900)
    pendingResult = result
    discovered.removeAll()
    startedAt = Date()

    browser.stop()
    browser.searchForServices(ofType: "_gscale-mobileapi._tcp.", inDomain: "local.")

    timeoutTimer?.invalidate()
    timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeoutMs) / 1000.0, repeats: false) {
      [weak self] _ in
      self?.finish()
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    service.delegate = self
    service.resolve(withTimeout: 0.8)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    let txtData = sender.txtRecordData() ?? Data()
    let txt = NetService.dictionary(fromTXTRecord: txtData)
    let host = resolvedHost(for: sender)
    guard let host else {
      return
    }

    let serverName = stringValue(txt["server_name"]) ?? sender.name
    let serverRef = stringValue(txt["server_ref"]) ?? ""
    let displayName = stringValue(txt["display_name"]) ?? "Operator"
    let role = stringValue(txt["role"]) ?? "operator"
    let latencyMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
    let key = "\(serverRef)|\(serverName)|\(host)|\(sender.port)"

    discovered[key] = [
      "host": host,
      "http_port": sender.port,
      "server_name": serverName,
      "server_ref": serverRef,
      "display_name": displayName,
      "role": role,
      "latency_ms": latencyMs,
    ]
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    finish()
  }

  private func finish() {
    timeoutTimer?.invalidate()
    timeoutTimer = nil
    browser.stop()

    guard let result = pendingResult else {
      return
    }
    pendingResult = nil
    result(discovered.values.sorted {
      ($0["latency_ms"] as? Int ?? .max) < ($1["latency_ms"] as? Int ?? .max)
    })
  }

  private func stringValue(_ value: Data?) -> String? {
    guard let value, !value.isEmpty else {
      return nil
    }
    return String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func resolvedHost(for service: NetService) -> String? {
    if let addresses = service.addresses {
      for address in addresses {
        if let host = ipv4Host(from: address) {
          return host
        }
      }
    }

    guard let hostName = service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
          !hostName.isEmpty
    else {
      return nil
    }
    return hostName
  }

  private func ipv4Host(from data: Data) -> String? {
    return data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return nil
      }

      let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
      guard sockaddrPointer.pointee.sa_family == sa_family_t(AF_INET) else {
        return nil
      }

      let sockaddrInPointer = baseAddress.assumingMemoryBound(to: sockaddr_in.self)
      var address = sockaddrInPointer.pointee.sin_addr
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      let result = inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
      guard result != nil else {
        return nil
      }
      return String(cString: buffer)
    }
  }
}
