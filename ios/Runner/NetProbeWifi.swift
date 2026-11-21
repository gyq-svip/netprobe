import CoreLocation
import Flutter
import Foundation
import NetworkExtension

/// iOS 侧 WiFi 能力。
///
/// 重要事实：iOS 没有开放"扫描附近 WiFi"的公共 API，
/// 且 NEHotspotNetwork.signalStrength 对普通 App 返回占位值而非真实 dBm。
/// 因此这里如实上报 rssiAvailable = false，由 Dart 侧改用 ping 网关的
/// 往返时延作为链路质量的代理指标。
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

    // MARK: - 通道分发

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
                "reason": "iOS 系统未开放附近 WiFi 扫描接口（TN3111）",
                "list": []
            ] as [String: Any])
        case "requestPermissions":
            requestPermission(result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func capabilities() -> [String: Any] {
        let status = locationManager.authorizationStatus
        let auth = (status == .authorizedWhenInUse || status == .authorizedAlways)
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

    // MARK: - 权限

    private func requestPermission(_ result: @escaping FlutterResult) {
        let status = locationManager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
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
        guard status != .notDetermined else { return }
        guard let pending = pendingPerm else { return }
        pendingPerm = nil
        pending(["location": status == .authorizedWhenInUse || status == .authorizedAlways])
    }

    // MARK: - 当前网络

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
                // 没有定位权限时 iOS 不返回 SSID，但这不代表没连上
                if ssid.isEmpty { map["ssidUnavailable"] = true }
                DispatchQueue.main.async { completion(map) }
            }
        } else {
            completion(base)
        }
    }

    // MARK: - 本机 IPv4

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
               (name == "en0" || name.hasPrefix("en")) {
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

    /// iOS 读不到路由表，用 TCP 探测常见的网关地址来推断（可能为空的）
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
}

// MARK: - 实时信号流

/// iOS 每秒推送一次：网关 ICMP 往返时延 + 链路连通状态。
/// Dart 侧把 RTT 映射成 0-100 的质量分，用作"信号强度"的替代。
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
        guard let owner = owner else { return }
        guard let sink = sink else { return }

        let iface = owner.currentSync()
        var rttMs: Double = -1
        var loss = true

        if !iface.gateway.isEmpty, let addr = SocketHelper.resolveIPv4(iface.gateway) {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            if fd >= 0 {
                defer { close(fd) }
                let packet = SocketHelper.makeICMP(type: 8, id: 0x4E50, seq: 1)
                let start = Date()
                if SocketHelper.send(fd: fd, packet: packet, to: addr) >= 0,
                   let resp = SocketHelper.recv(fd: fd, timeoutMs: 900) {
                    if resp.type == 0 {
                        rttMs = Date().timeIntervalSince(start) * 1000
                        loss = false
                    }
                }
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
        DispatchQueue.main.async {
            sink(payload)
        }
    }
}

extension NetProbeWifi {
    /// 供 RSSI 轮询使用的同步取值（避免嵌套异步回调）
    func currentSync() -> (ip: String, prefix: Int, gateway: String) {
        let iface = ipv4Info()
        cachedIp = iface.ip
        cachedPrefix = iface.prefix

        if cachedGateway.isEmpty && !iface.ip.isEmpty {
            // 网关推断要发多次 TCP 探测，做 60s 节流避免拖慢每秒轮询
            if Date().timeIntervalSince(lastGatewayCheck) > 60 {
                lastGatewayCheck = Date()
                let g = guessGateway(ip: iface.ip)
                if !g.isEmpty { cachedGateway = g }
            }
        }
        return (iface.ip, iface.prefix, cachedGateway)
    }
}
