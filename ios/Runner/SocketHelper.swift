import Foundation

struct ICMPResponse {
    let type: Int
    let ip: String
    let ttl: Int?
    let bytes: Int
}

/// 基于 POSIX socket 的底层网络工具。
enum SocketHelper {

    // MARK: - 名字解析

    static func resolveIPv4(_ host: String) -> in_addr? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let list = res else { return nil }
        defer { freeaddrinfo(res) }
        var addr = in_addr()
        if let sa = list.pointee.ai_addr {
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                addr = sin.pointee.sin_addr
            }
            return addr
        }
        return nil
    }

    // MARK: - ICMP 报文

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

    // MARK: - 收发

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

        // 若内核未剥离 IP 头（首字节高 4 位为 4），先跳过
        if (buf[0] >> 4) == 4 && buf[0] != 0 {
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

    // MARK: - TCP 连通性探测

    /// 非阻塞 connect，返回是否连通及耗时（毫秒）
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
