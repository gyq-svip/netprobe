import AVFoundation
import Flutter
import Foundation

/// iOS 侧网络工具：ping、traceroute、提示音。
///
/// iOS 沙盒禁止 fork/exec，所以无法像 Android 那样调用系统 ping，
/// 这里直接用 BSD socket 构造 ICMP（SOCK_DGRAM + IPPROTO_ICMP，无需 root）。
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
            let count = args["count"] as? Int ?? 4
            let interval = args["interval"] as? Double ?? 0.5
            guard !host.isEmpty else {
                result(FlutterError(code: "bad_args", message: "host 为空", details: nil))
                return
            }
            startPing(host: host, count: count, interval: interval)
            result(true)

        case "stopPing":
            pingRunning = false
            result(true)

        case "trace":
            let host = args["host"] as? String ?? ""
            let maxHops = args["maxHops"] as? Int ?? 20
            guard !host.isEmpty else {
                result(FlutterError(code: "bad_args", message: "host 为空", details: nil))
                return
            }
            startTrace(host: host, maxHops: maxHops)
            result(true)

        case "stopTrace":
            traceRunning = false
            result(true)

        case "arpTable":
            // iOS 无法读取 ARP 缓存，交由 Dart 侧用 TCP 探测补全
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

    // MARK: - ping

    private func startPing(host: String, count: Int, interval: Double) {
        pingRunning = false
        pingThread?.cancel()
        pingRunning = true
        let t = Thread { [weak self] in
            self?.pingLoop(host: host, count: max(1, min(count, 50)), interval: max(0.3, min(interval, 5)))
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
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let pid = UInt16(truncatingIfNeeded: Int32(bitPattern: getpid()))
        var received = 0

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
                let rtt = Date().timeIntervalSince(start) * 1000.0
                if resp.type == 0 {
                    received += 1
                    emitPing([
                        "type": "reply",
                        "rtt": rtt,
                        "ttl": resp.ttl ?? 0,
                        "seq": seq,
                        "ip": resp.ip,
                        "text": "\(resp.bytes) bytes from \(resp.ip): icmp_seq=\(seq) ttl=\(resp.ttl ?? 0) time=\(String(format: "%.1f", rtt)) ms"
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

        let loss = count == 0 ? 100 : (count - received) * 100 / max(count, 1)
        emitPing(["type": "done", "sent": count, "received": received, "loss": loss])
    }

    private func emitPing(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.pingSink?(payload)
        }
    }

    // MARK: - traceroute

    private func startTrace(host: String, maxHops: Int) {
        traceRunning = false
        traceThread?.cancel()
        traceRunning = true
        let t = Thread { [weak self] in
            self?.traceLoop(host: host, maxHops: max(1, min(maxHops, 32)))
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

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

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
                let rtt = Date().timeIntervalSince(start) * 1000.0
                let final = resp.type == 0
                emitTrace([
                    "type": "hop",
                    "hop": ttl,
                    "ip": resp.ip,
                    "rtt": rtt,
                    "final": final,
                    "pending": false,
                    "timeout": false
                ])
                if final { break }
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

// MARK: - 通用流处理器

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
