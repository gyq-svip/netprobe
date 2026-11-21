//
//  AppDelegate.swift
//  网络工具箱 NetProbe
//
//  说明：iOS 侧全部原生代码集中在本文件。
//  原因：新增 .swift 文件必须手动登记到 Runner.xcodeproj/project.pbxproj 才会参与编译，
//  集中在已注册的 AppDelegate.swift 里可以避免工程文件出错导致打包失败。
//
//  能力边界（来自 Apple TN3111）：
//  - iOS 不提供通用 WiFi 扫描 API，无法列出附近 AP；
//  - NEHotspotNetwork.signalStrength 对普通 App 返回占位值，不是真实 dBm；
//  所以信号强度改用"ping 网关往返时延"作为链路质量代理，由 Dart 侧映射成 0-100 曲线。
//

import AVFoundation
import CoreLocation
import Flutter
import Foundation
import NetworkExtension
import UIKit

// MARK: - App 入口

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      NetProbeChannels.register(with: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// MARK: - 通道注册

enum NetProbeChannels {
  static let wifi = "com.gyq.netprobe/wifi"
  static let wifiRssi = "com.gyq.netprobe/wifi_rssi"
  static let probe = "com.gyq.netprobe/probe"
  static let ping = "com.gyq.netprobe/ping"
  static let trace = "com.gyq.netprobe/trace"

  private static var wifiBridge: NetProbeWifi?
  private static var toolsBridge: NetProbeTools?

  static func register(with messenger: FlutterBinaryMessenger) {
    let wifi = NetProbeWifi()
    let tools = NetProbeTools()
    wifiBridge = wifi
    toolsBridge = tools

    let wifiChannel = FlutterMethodChannel(name: self.wifi, binaryMessenger: messenger)
    wifiChannel.setMethodCallHandler { call, result in
      wifi.handle(call, result: result)
    }

    let rssiChannel = FlutterEventChannel(name: wifiRssi, binaryMessenger: messenger)
    rssiChannel.setStreamHandler(wifi.rssiStreamHandler)

    let probeChannel = FlutterMethodChannel(name: probe, binaryMessenger: messenger)
    probeChannel.setMethodCallHandler { call, result in
      tools.handle(call, result: result)
    }

    let pingChannel = FlutterEventChannel(name: ping, binaryMessenger: messenger)
    pingChannel.setStreamHandler(tools.pingStreamHandler)

    let traceChannel = FlutterEventChannel(name: trace, binaryMessenger: messenger)
    traceChannel.setStreamHandler(tools.traceStreamHandler)
  }
}

// MARK: - 通用事件流处理器

final class SimpleStreamHandler: NSObject, FlutterStreamHandler {
  private let onListenBlock: (FlutterEventSink) -> Void
  private let onCancelBlock: () -> Void

  init(onListen: @escaping (FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
    self.onListenBlock = onListen
    self.onCancelBlock = onCancel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListenBlock(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelBlock()
    return nil
  }
}

// MARK: - 底层 socket 工具

struct ICMPResponse {
  let type: Int
  let ip: String
  let ttl: Int?
  let bytes: Int
}

enum SocketHelper {

  static func resolveIPv4(_ host: String) -> in_addr? {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let list = res else { return nil }
    defer { freeaddrinfo(res) }
    guard let sa = list.pointee.ai_addr else { return nil }
    var addr = in_addr()
    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
      addr = sin.pointee.sin_addr
    }
    return addr
  }

  static func makeICMP(type: UInt8, id: UInt16, seq: UInt16) -> [UInt8] {
    let payloadSize = 32
    var p = [UInt8](repeating: 0, count: 8 + payloadSize)
    p[0] = type
    p[1] = 0
    p[2] = 0
    p[3] = 0
    p[4] = UInt8(id >> 8)
    p[5] = UInt8(id & 0xFF)
    p[6] = UInt8(seq >> 8)
    p[7] = UInt8(seq & 0xFF)
    for i in 0..<payloadSize {
      p[8 + i] = UInt8((i &* 37) & 0xFF)
    }
    let cs = checksum(p)
    p[2] = UInt8(cs >> 8)
    p[3] = UInt8(cs & 0xFF)
    return p
  }

  static func checksum(_ data: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < data.count {
      sum &+= (UInt32(data[i]) << 8) | UInt32(data[i + 1])
      i += 2
    }
    if i < data.count {
      sum &+= UInt32(data[i]) << 8
    }
    while (sum >> 16) != 0 {
      sum = (sum & 0xFFFF) + (sum >> 16)
    }
    return ~UInt16(sum & 0xFFFF)
  }

  @discardableResult
  static func send(fd: Int32, packet: [UInt8], to addr: in_addr) -> Int {
    var dst = sockaddr_in()
    dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    dst.sin_family = sa_family_t(AF_INET)
    dst.sin_port = 0
    dst.sin_addr = addr

    return withUnsafePointer(to: &dst) { dstPtr in
      dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        packet.withUnsafeBytes { raw in
          sendto(fd, raw.baseAddress, packet.count, 0, sa,
                 socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  static func recv(fd: Int32, timeoutMs: Int) -> ICMPResponse? {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, Int32(timeoutMs))
    guard ready > 0 else { return nil }

    var buf = [UInt8](repeating: 0, count: 1500)
    var from = sockaddr_in()
    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

    let n = withUnsafeMutablePointer(to: &from) { fp in
      fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
        recvfrom(fd, &buf, buf.count, 0, sap, &fromLen)
      }
    }
    guard n > 0 else { return nil }

    var offset = 0
    var ttl: Int? = nil

    // 部分情况下内核不剥离 IP 头：首字节高 4 位为版本号
    if (buf[0] >> 4) == 4 {
      let ihl = Int(buf[0] & 0x0F) * 4
      if ihl >= 20 && ihl < n {
        ttl = Int(buf[8])
        offset = ihl
      }
    }
    guard offset < n else { return nil }

    let type = Int(buf[offset])
    var ip = ""
    if let ipPtr = inet_ntoa(from.sin_addr) {
      ip = String(cString: ipPtr)
    }
    return ICMPResponse(type: type, ip: ip, ttl: ttl, bytes: n - offset)
  }

  /// 非阻塞 connect，返回连通性与耗时
  static func tcpProbe(host: String, port: UInt16, timeoutMs: Int) -> (ok: Bool, rttMs: Double) {
    guard let addr = resolveIPv4(host) else { return (false, -1) }

    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { return (false, -1) }
    defer { close(fd) }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var dst = sockaddr_in()
    dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    dst.sin_family = sa_family_t(AF_INET)
    dst.sin_port = port.bigEndian
    dst.sin_addr = addr

    let start = Date()
    let rc = withUnsafePointer(to: &dst) { dstPtr in
      dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    if rc == 0 {
      return (true, Date().timeIntervalSince(start) * 1000)
    }
    if errno != EINPROGRESS {
      return (false, -1)
    }

    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&pfd, 1, Int32(timeoutMs))
    guard ready > 0 else { return (false, -1) }

    var soError: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
    let elapsed = Date().timeIntervalSince(start) * 1000
    return (soError == 0, soError == 0 ? elapsed : -1)
  }
}

// MARK: - 提示音引擎

/// 信号强 -> 频率高、音量大；信号弱 -> 频率低、音量小。
final class ToneEngine {

  private let engine = AVAudioEngine()
  private var sourceNode: AVAudioSourceNode?
  private var running = false
  private let sampleRate: Double = 44100

  private var volumeTarget: Double = 0
  private var volumeLive: Double = 0
  private var frequency: Double = 440
  private var phase: Double = 0
  private var sampleIndex: Int64 = 0

  func setVolume(_ v: Double) {
    volumeTarget = max(0, min(1, v))
  }

  func setFrequency(_ f: Double) {
    frequency = max(120, min(2400, f))
  }

  func start() {
    guard !running else { return }
    guard #available(iOS 13.0, *) else { return }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      // 音频会话失败不阻断主流程
    }

    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      return
    }

    let sr = sampleRate
    let node = AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
      let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
      let frames = Int(frameCount)

      let periodSamples = Int(sr * 0.8)
      let beepSamples = Int(sr * 0.25)
      let attackSamples = max(1, Int(sr * 0.005))
      let releaseSamples = max(1, Int(sr * 0.03))

      for frame in 0..<frames {
        self.volumeLive += (self.volumeTarget - self.volumeLive) * 0.0006

        let pos = Int(self.sampleIndex % Int64(periodSamples))
        var gate: Double = 0
        if pos < beepSamples {
          let up = Double(pos) / Double(attackSamples)
          let down = Double(beepSamples - pos) / Double(releaseSamples)
          gate = max(0, min(1, min(up, down)))
        }

        let wave = sin(self.phase) * 0.8 + sin(self.phase * 2) * 0.2
        let sample = Float(wave * gate * self.volumeLive * 0.9)

        for buffer in ablPointer {
          if let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) {
            ptr[frame] = sample
          }
        }

        self.phase += 2 * Double.pi * self.frequency / sr
        if self.phase > 2 * Double.pi { self.phase -= 2 * Double.pi }
        self.sampleIndex += 1
      }
      return noErr
    }

    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)

    do {
      try engine.start()
      running = true
      sourceNode = node
    } catch {
      engine.detach(node)
    }
  }

  func stop() {
    guard running else { return }
    running = false
    volumeTarget = 0
    volumeLive = 0
    engine.stop()
    if let node = sourceNode {
      engine.detach(node)
      sourceNode = nil
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }
}

// MARK: - WiFi 信息

final class NetProbeWifi: NSObject, CLLocationManagerDelegate {

  private let locationManager = CLLocationManager()
  private var pendingPerm: FlutterResult?

  private var cachedIp: String = ""
  private var cachedPrefix: Int = 24
  private var cachedGateway: String = ""
  private var lastGatewayCheck: Date = .distantPast

  lazy var rssiStreamHandler = WifiRssiHandler(owner: self)

  override init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilities())
    case "current":
      current { map in result(map) }
    case "scan":
      result([
        "ok": false,
        "accepted": false,
        "throttled": false,
        "reason": "iOS 系统未开放附近 WiFi 扫描接口（Apple TN3111）",
        "list": []
      ] as [String: Any])
    case "requestPermissions":
      requestPermission(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func capabilities() -> [String: Any] {
    let auth = locationAuthorized()
    return [
      "platform": "ios",
      "sdkInt": 0,
      "hasWifi": true,
      "locationPermission": auth,
      "nearbyPermission": true,
      "locationEnabled": CLLocationManager.locationServicesEnabled(),
      "canScan": false,
      "realRssi": false,
      "canReadArp": false,
      "scanNote": "iOS 不允许第三方 App 扫描附近 WiFi，信号强度以延迟代理呈现"
    ]
  }

  private func locationAuthorized() -> Bool {
    let status = locationManager.authorizationStatus
    return status == .authorizedWhenInUse || status == .authorizedAlways
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    if locationAuthorized() {
      result(["location": true])
      return
    }
    DispatchQueue.main.async {
      self.pendingPerm = result
      self.locationManager.requestWhenInUseAuthorization()
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    guard status != .notDetermined, let pending = pendingPerm else { return }
    pendingPerm = nil
    pending(["location": status == .authorizedWhenInUse || status == .authorizedAlways])
  }

  func current(_ completion: @escaping ([String: Any]) -> Void) {
    let iface = ipv4Info()
    cachedIp = iface.ip
    cachedPrefix = iface.prefix
    if cachedGateway.isEmpty && !cachedIp.isEmpty && Date().timeIntervalSince(lastGatewayCheck) > 60 {
      lastGatewayCheck = Date()
      cachedGateway = guessGateway(ip: cachedIp)
    }

    let base: [String: Any] = [
      "connected": !cachedIp.isEmpty,
      "ip": cachedIp,
      "prefix": cachedPrefix,
      "gateway": cachedGateway,
      "dns": [String](),
      "rssi": 0,
      "rssiAvailable": false,
      "linkSpeed": 0,
      "frequency": 0,
      "channel": 0,
      "band": "",
      "mac": "",
      "bssid": "",
      "wifiStandard": 0
    ]

    if #available(iOS 14.0, *) {
      NEHotspotNetwork.fetchCurrent { net in
        var map = base
        let ssid = net?.ssid ?? ""
        map["ssid"] = ssid
        map["bssid"] = net?.bssid ?? ""
        map["isSecure"] = net?.isSecure ?? false
        map["autoJoined"] = net?.didAutoJoin ?? false
        if ssid.isEmpty { map["ssidUnavailable"] = true }
        DispatchQueue.main.async { completion(map) }
      }
    } else {
      completion(base)
    }
  }

  private func ipv4Info() -> (ip: String, prefix: Int) {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return ("", 24) }
    defer { freeifaddrs(ifaddrPtr) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    var result: (String, Int) = ("", 24)

    while let p = cursor {
      let ifa = p.pointee
      let name = String(cString: ifa.ifa_name)
      if let sa = ifa.ifa_addr,
         sa.pointee.sa_family == UInt8(AF_INET),
         name.hasPrefix("en") {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_len)
        if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
          let ip = String(cString: host)
          if !ip.isEmpty && ip != "127.0.0.1" {
            var prefix = 24
            if let mask = ifa.ifa_netmask {
              mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { m in
                let raw = UInt32(bigEndian: m.pointee.sin_addr.s_addr)
                if raw != 0 { prefix = raw.nonzeroBitCount }
              }
            }
            result = (ip, prefix)
            if name == "en0" { break }
          }
        }
      }
      cursor = ifa.ifa_next
    }
    return result
  }

  /// iOS 读不到路由表，用 TCP 探测常见网关地址推断
  func guessGateway(ip: String) -> String {
    let parts = ip.split(separator: ".")
    guard parts.count == 4 else { return "" }
    let base = "\(parts[0]).\(parts[1]).\(parts[2])"
    for octet in ["1", "254", "2"] {
      let candidate = "\(base).\(octet)"
      for port in [80, 443, 53] as [UInt16] {
        if SocketHelper.tcpProbe(host: candidate, port: port, timeoutMs: 220).ok {
          return candidate
        }
      }
    }
    return ""
  }

  func currentSync() -> (ip: String, prefix: Int, gateway: String) {
    let iface = ipv4Info()
    cachedIp = iface.ip
    cachedPrefix = iface.prefix
    if cachedGateway.isEmpty && !iface.ip.isEmpty && Date().timeIntervalSince(lastGatewayCheck) > 60 {
      lastGatewayCheck = Date()
      let g = guessGateway(ip: iface.ip)
      if !g.isEmpty { cachedGateway = g }
    }
    return (iface.ip, iface.prefix, cachedGateway)
  }
}

// MARK: - 实时链路质量流

/// 每秒推一次：网关 ICMP 往返时延。Dart 侧映射为 0-100 的质量分。
final class WifiRssiHandler: NSObject, FlutterStreamHandler {

  private weak var owner: NetProbeWifi?
  private var sink: FlutterEventSink?
  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "com.gyq.netprobe.rssi", qos: .utility)

  init(owner: NetProbeWifi) {
    self.owner = owner
    super.init()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: 1.0)
    t.setEventHandler { [weak self] in
      self?.tick()
    }
    timer = t
    t.resume()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.cancel()
    timer = nil
    sink = nil
    return nil
  }

  private func tick() {
    guard let owner = owner, let sink = sink else { return }

    let iface = owner.currentSync()
    var rttMs: Double = -1
    var loss = true

    if !iface.gateway.isEmpty, let addr = SocketHelper.resolveIPv4(iface.gateway) {
      let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
      if fd >= 0 {
        let packet = SocketHelper.makeICMP(type: 8, id: 0x4E50, seq: 1)
        let start = Date()
        if SocketHelper.send(fd: fd, packet: packet, to: addr) >= 0,
           let resp = SocketHelper.recv(fd: fd, timeoutMs: 900),
           resp.type == 0 {
          rttMs = Date().timeIntervalSince(start) * 1000
          loss = false
        }
        close(fd)
      }
    }

    let payload: [String: Any] = [
      "connected": !iface.ip.isEmpty,
      "ip": iface.ip,
      "prefix": iface.prefix,
      "gateway": iface.gateway,
      "probeRtt": rttMs,
      "probeLoss": loss,
      "rssi": 0,
      "rssiAvailable": false,
      "ssid": "",
      "bssid": ""
    ]
    DispatchQueue.main.async { sink(payload) }
  }
}

// MARK: - 网络工具

final class NetProbeTools: NSObject {

  private var pingSink: FlutterEventSink?
  private var traceSink: FlutterEventSink?
  private var pingRunning = false
  private var traceRunning = false
  private var pingThread: Thread?
  private var traceThread: Thread?

  private let tone = ToneEngine()

  lazy var pingStreamHandler = SimpleStreamHandler(
    onListen: { [weak self] sink in self?.pingSink = sink },
    onCancel: { [weak self] in self?.pingSink = nil }
  )

  lazy var traceStreamHandler = SimpleStreamHandler(
    onListen: { [weak self] sink in self?.traceSink = sink },
    onCancel: { [weak self] in self?.traceSink = nil }
  )

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ping":
      let host = args["host"] as? String ?? ""
      guard !host.isEmpty else {
        result(FlutterError(code: "bad_args", message: "host 为空", details: nil))
        return
      }
      let count = args["count"] as? Int ?? 4
      let interval = args["interval"] as? Double ?? 0.5
      startPing(host: host, count: count, interval: interval)
      result(true)

    case "stopPing":
      pingRunning = false
      result(true)

    case "trace":
      let host = args["host"] as? String ?? ""
      guard !host.isEmpty else {
        result(FlutterError(code: "bad_args", message: "host 为空", details: nil))
        return
      }
      let maxHops = args["maxHops"] as? Int ?? 20
      startTrace(host: host, maxHops: maxHops)
      result(true)

    case "stopTrace":
      traceRunning = false
      result(true)

    case "arpTable":
      result([String: String]())

    case "toneStart":
      tone.setFrequency(args["freq"] as? Double ?? 440)
      tone.setVolume(args["volume"] as? Double ?? 0.3)
      tone.start()
      result(true)

    case "toneUpdate":
      if let v = args["volume"] as? Double { tone.setVolume(v) }
      if let f = args["freq"] as? Double { tone.setFrequency(f) }
      result(true)

    case "toneStop":
      tone.stop()
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: ping

  private func startPing(host: String, count: Int, interval: Double) {
    pingRunning = false
    pingRunning = true
    let c = max(1, min(count, 50))
    let iv = max(0.3, min(interval, 5))
    let t = Thread { [weak self] in
      self?.pingLoop(host: host, count: c, interval: iv)
    }
    t.stackSize = 512 * 1024
    pingThread = t
    t.start()
  }

  private func pingLoop(host: String, count: Int, interval: Double) {
    defer { pingRunning = false }

    guard let target = SocketHelper.resolveIPv4(host) else {
      emitPing(["type": "error", "text": "无法解析主机名：\(host)"])
      emitPing(["type": "done", "sent": 0, "received": 0, "loss": 100])
      return
    }

    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else {
      emitPing(["type": "error", "text": "无法创建 ICMP socket（系统限制）"])
      emitPing(["type": "done", "sent": 0, "received": 0, "loss": 100])
      return
    }

    var received = 0
    let pid = UInt16(truncatingIfNeeded: Int32(bitPattern: getpid()))

    for seq in 1...count {
      if !pingRunning { break }
      let packet = SocketHelper.makeICMP(type: 8, id: pid, seq: UInt16(seq))
      let start = Date()
      let sent = SocketHelper.send(fd: fd, packet: packet, to: target)
      if sent < 0 {
        emitPing(["type": "error", "text": "发送失败 errno=\(errno)"])
        continue
      }

      if let resp = SocketHelper.recv(fd: fd, timeoutMs: 2000) {
        let rtt = Date().timeIntervalSince(start) * 1000
        if resp.type == 0 {
          received += 1
          let ttlText = resp.ttl.map(String.init) ?? "-"
          emitPing([
            "type": "reply",
            "rtt": rtt,
            "ttl": resp.ttl ?? 0,
            "seq": seq,
            "ip": resp.ip,
            "text": "\(resp.bytes) bytes from \(resp.ip): icmp_seq=\(seq) ttl=\(ttlText) time=\(String(format: "%.1f", rtt)) ms"
          ])
        } else {
          emitPing(["type": "line", "text": "icmp_seq=\(seq) 收到 ICMP type=\(resp.type)"])
        }
      } else {
        emitPing(["type": "line", "text": "Request timeout for icmp_seq \(seq)"])
      }

      if seq < count && pingRunning {
        Thread.sleep(forTimeInterval: interval)
      }
    }

    close(fd)
    let loss = (count - received) * 100 / max(count, 1)
    emitPing(["type": "done", "sent": count, "received": received, "loss": loss])
  }

  private func emitPing(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.pingSink?(payload)
    }
  }

  // MARK: traceroute

  private func startTrace(host: String, maxHops: Int) {
    traceRunning = false
    traceRunning = true
    let hops = max(1, min(maxHops, 32))
    let t = Thread { [weak self] in
      self?.traceLoop(host: host, maxHops: hops)
    }
    t.stackSize = 512 * 1024
    traceThread = t
    t.start()
  }

  private func traceLoop(host: String, maxHops: Int) {
    defer { traceRunning = false }

    guard let target = SocketHelper.resolveIPv4(host) else {
      emitTrace(["type": "error", "text": "无法解析主机名：\(host)"])
      emitTrace(["type": "done"])
      return
    }

    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else {
      emitTrace(["type": "error", "text": "无法创建 ICMP socket"])
      emitTrace(["type": "done"])
      return
    }
    defer { close(fd) }

    let pid = UInt16(truncatingIfNeeded: Int32(bitPattern: getpid()))

    for ttl in 1...maxHops {
      if !traceRunning { break }
      emitTrace(["type": "hop", "hop": ttl, "pending": true])

      var ttlValue = Int32(ttl)
      setsockopt(fd, IPPROTO_IP, IP_TTL, &ttlValue, socklen_t(MemoryLayout<Int32>.size))

      let packet = SocketHelper.makeICMP(type: 8, id: pid, seq: UInt16(ttl))
      let start = Date()
      _ = SocketHelper.send(fd: fd, packet: packet, to: target)

      if let resp = SocketHelper.recv(fd: fd, timeoutMs: 2000) {
        let rtt = Date().timeIntervalSince(start) * 1000
        let isFinal = resp.type == 0
        emitTrace([
          "type": "hop",
          "hop": ttl,
          "ip": resp.ip,
          "rtt": rtt,
          "final": isFinal,
          "pending": false,
          "timeout": false
        ])
        if isFinal { break }
      } else {
        emitTrace([
          "type": "hop",
          "hop": ttl,
          "ip": "",
          "rtt": -1.0,
          "final": false,
          "pending": false,
          "timeout": true
        ])
      }
    }

    emitTrace(["type": "done"])
  }

  private func emitTrace(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.traceSink?(payload)
    }
  }
}
