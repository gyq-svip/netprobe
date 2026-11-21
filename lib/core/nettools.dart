/// 纯 Dart 侧网络能力：DNS(DoH) / 端口扫描 / 局域网发现 / 风险研判
/// 这些不依赖原生实现，双端行为一致。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'models.dart';

// ---------------------------------------------------------------- 端口字典

const Map<int, String> kPortServices = {
  20: 'FTP-Data',
  21: 'FTP',
  22: 'SSH',
  23: 'Telnet',
  25: 'SMTP',
  53: 'DNS',
  67: 'DHCP',
  69: 'TFTP',
  80: 'HTTP',
  110: 'POP3',
  123: 'NTP',
  135: 'MSRPC',
  137: 'NetBIOS-NS',
  139: 'NetBIOS',
  143: 'IMAP',
  161: 'SNMP',
  389: 'LDAP',
  443: 'HTTPS',
  445: 'SMB',
  465: 'SMTPS',
  514: 'Syslog',
  587: 'SMTP-Sub',
  631: 'IPP打印',
  636: 'LDAPS',
  853: 'DNS-over-TLS',
  873: 'Rsync',
  993: 'IMAPS',
  995: 'POP3S',
  1080: 'SOCKS',
  1433: 'MSSQL',
  1521: 'Oracle',
  1723: 'PPTP',
  1883: 'MQTT',
  1900: 'UPnP',
  2049: 'NFS',
  2375: 'Docker-API',
  2376: 'Docker-TLS',
  3306: 'MySQL',
  3389: 'RDP',
  5000: 'UPnP/Flask',
  5432: 'PostgreSQL',
  5555: 'ADB',
  5601: 'Kibana',
  5900: 'VNC',
  5984: 'CouchDB',
  6379: 'Redis',
  7001: 'WebLogic',
  8000: 'HTTP-Alt',
  8008: 'HTTP-Alt',
  8080: 'HTTP-Proxy',
  8081: 'HTTP-Alt',
  8443: 'HTTPS-Alt',
  8888: 'HTTP-Alt',
  9000: 'PHP-FPM',
  9100: '打印机RAW',
  9200: 'Elasticsearch',
  11211: 'Memcached',
  27017: 'MongoDB',
  32400: 'Plex',
  50000: 'SAP',
  55442: 'NAS',
  62078: 'iPhone 同步',
};

/// 局域网存活判定的快捷端口（命中即视为在线）
const List<int> kQuickProbePorts = [80, 443, 22, 445, 62078, 8080, 53, 9100, 5000, 3389, 5555, 21, 23];

/// 单机详情扫描的默认端口集
const List<int> kDetailPorts = [
  21, 22, 23, 25, 53, 80, 110, 135, 139, 143, 161, 389, 443, 445, 465, 514,
  587, 631, 993, 995, 1080, 1433, 1521, 1723, 1883, 1900, 2049, 2375, 2376,
  3306, 3389, 5000, 5432, 5555, 5601, 5900, 5984, 6379, 7001, 8000, 8008,
  8080, 8081, 8443, 8888, 9000, 9100, 9200, 11211, 27017, 32400, 62078,
];

List<int> parsePorts(String text) {
  final out = <int>{};
  for (final chunk in text.split(RegExp(r'[,\s]+'))) {
    if (chunk.isEmpty) continue;
    if (chunk.contains('-')) {
      final bounds = chunk.split('-');
      if (bounds.length == 2) {
        final a = int.tryParse(bounds[0]);
        final b = int.tryParse(bounds[1]);
        if (a != null && b != null && b >= a) {
          for (var p = a; p <= b && p <= 65535; p++) {
            if (p > 0) out.add(p);
          }
        }
      }
    } else {
      final p = int.tryParse(chunk);
      if (p != null && p > 0 && p <= 65535) out.add(p);
    }
  }
  return out.toList()..sort();
}

// -------------------------------------------------------------------- DNS

class DnsRecord {
  final String name;
  final int ttl;
  final String type;
  final String data;

  const DnsRecord({
    required this.name,
    required this.ttl,
    required this.type,
    required this.data,
  });
}

class DnsResult {
  final String query;
  final String type;
  final List<DnsRecord> records;
  final String status;
  final String error;
  final int elapsedMs;

  const DnsResult({
    required this.query,
    required this.type,
    this.records = const [],
    this.status = '',
    this.error = '',
    this.elapsedMs = 0,
  });

  bool get ok => error.isEmpty && records.isNotEmpty;
}

class DnsTool {
  static const _typeNames = {
    1: 'A',
    2: 'NS',
    5: 'CNAME',
    6: 'SOA',
    12: 'PTR',
    15: 'MX',
    16: 'TXT',
    28: 'AAAA',
    33: 'SRV',
    65: 'HTTPS',
    257: 'CAA',
  };

  static const _typeCodes = {
    'A': 1,
    'AAAA': 28,
    'CNAME': 5,
    'MX': 15,
    'TXT': 16,
    'NS': 2,
    'SOA': 6,
    'PTR': 12,
    'SRV': 33,
    'CAA': 257,
  };

  static String ipOfType(int code) => _typeNames[code] ?? 'T$code';

  static Future<DnsResult> query(String name, {String type = 'A'}) async {
    final started = DateTime.now();
    final code = _typeCodes[type.toUpperCase()] ?? 1;

    final endpoints = <String>[
      'https://dns.alidns.com/resolve?name=${Uri.encodeComponent(name)}&type=$code',
      'https://cloudflare-dns.com/dns-query?name=${Uri.encodeComponent(name)}&type=$code',
      'https://doh.pub/dns-query?name=${Uri.encodeComponent(name)}&type=$code',
    ];

    var lastError = '';
    for (final url in endpoints) {
      try {
        final resp = await http.get(
          Uri.parse(url),
          headers: const {'accept': 'application/dns-json'},
        ).timeout(const Duration(seconds: 6));

        if (resp.statusCode != 200) {
          lastError = 'HTTP ${resp.statusCode}';
          continue;
        }

        final body = jsonDecode(utf8.decode(resp.bodyBytes));
        if (body is! Map) {
          lastError = '返回格式异常';
          continue;
        }

        final json = Map<String, dynamic>.from(body);
        final answers = (json['Answer'] as List?) ?? const [];
        final records = answers
            .whereType<Map>()
            .map((e) {
              final m = Map<String, dynamic>.from(e);
              return DnsRecord(
                name: (m['name'] as String?) ?? name,
                ttl: (m['TTL'] as num?)?.toInt() ?? 0,
                type: _typeNames[(m['type'] as num?)?.toInt() ?? 0] ?? '?',
                data: (m['data'] as String?) ?? '',
              );
            })
            .toList();

        final statusCode = (json['Status'] as num?)?.toInt() ?? 0;
        final status = statusCode == 0
            ? 'NOERROR'
            : statusCode == 3
                ? 'NXDOMAIN（域名不存在）'
                : 'RCODE $statusCode';

        return DnsResult(
          query: name,
          type: type.toUpperCase(),
          records: records,
          status: status,
          error: records.isEmpty && statusCode != 0 ? status : '',
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
        );
      } catch (e) {
        lastError = e.toString();
      }
    }

    return DnsResult(
      query: name,
      type: type,
      error: 'DNS 查询失败：$lastError',
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
    );
  }

  /// 用系统解析器解析（对比本地 DNS 与公共 DNS 的差异）
  static Future<List<String>> localLookup(String host) async {
    try {
      final list = await InternetAddress.lookup(host).timeout(const Duration(seconds: 4));
      return list.map((e) => e.address).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<String> reverseLookup(String ip) async {
    final parts = ip.split('.');
    if (parts.length != 4) return '';
    final arpa = '${parts[3]}.${parts[2]}.${parts[1]}.${parts[0]}.in-addr.arpa';
    final result = await query(arpa, type: 'PTR');
    if (result.records.isEmpty) return '';
    return result.records.first.data.replaceAll(RegExp(r'\.$'), '');
  }
}

// ------------------------------------------------------------- 端口扫描

class PortScanner {
  static Future<List<PortResult>> scan(
    String host, {
    List<int>? ports,
    int timeoutMs = 900,
    int concurrency = 160,
    void Function(int done, int total)? onProgress,
  }) async {
    final targets = ports ?? kDetailPorts;
    final results = <PortResult>[];
    var cursor = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= targets.length) return;
        final port = targets[index];
        final r = await _probe(host, port, timeoutMs);
        if (r != null) results.add(r);
        done++;
        onProgress?.call(done, targets.length);
      }
    }

    final n = min(concurrency, targets.length);
    await Future.wait(List.generate(n, (_) => worker()));
    results.sort((a, b) => a.port.compareTo(b.port));
    return results;
  }

  static Future<PortResult?> _probe(String host, int port, int timeoutMs) async {
    final started = DateTime.now();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: Duration(milliseconds: timeoutMs));
      final rtt = DateTime.now().difference(started).inMilliseconds;
      return PortResult(port: port, open: true, rttMs: rtt, banner: kPortServices[port] ?? '');
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }
}

// ----------------------------------------------------------- 局域网发现

class LanScanner {
  /// 生成可扫描的主机列表（不超过 1024 个，避免 /16 卡死）
  static List<String> hostList(String ip, int prefix) {
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.contains(null)) return const [];

    final p = prefix.clamp(16, 30);
    final ipInt = (parts[0]! << 24) | (parts[1]! << 16) | (parts[2]! << 8) | parts[3]!;
    final mask = (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF;
    final network = ipInt & mask;
    final hostBits = 32 - p;
    final total = (1 << hostBits) - 2;

    final count = min(total, 1024);
    final out = <String>[];
    for (var i = 1; i <= count; i++) {
      final value = network + i;
      final addr =
          '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.${(value >> 8) & 0xFF}.${value & 0xFF}';
      if (addr != ip) out.add(addr);
    }
    return out;
  }

  static Future<List<LanDevice>> scan({
    required String ip,
    required int prefix,
    String gateway = '',
    int concurrency = 128,
    int timeoutMs = 450,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final hosts = hostList(ip, prefix);
    final found = <LanDevice>[];
    var cursor = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        if (shouldStop?.call() == true) return;
        final index = cursor++;
        if (index >= hosts.length) return;
        final host = hosts[index];
        final device = await _quickProbe(host, timeoutMs);
        done++;
        if (device != null) found.add(device);
        onProgress?.call(done, hosts.length);
      }
    }

    await Future.wait(List.generate(min(concurrency, max(hosts.length, 1)), (_) => worker()));

    for (final d in found) {
      if (gateway.isNotEmpty && d.ip == gateway) d.isGateway = true;
      if (d.ip == ip) d.isSelf = true;
    }
    found.sort((a, b) {
      if (a.isGateway != b.isGateway) return a.isGateway ? -1 : 1;
      final pa = a.ip.split('.').map(int.parse).toList();
      final pb = b.ip.split('.').map(int.parse).toList();
      for (var i = 0; i < 4; i++) {
        if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
      }
      return 0;
    });
    return found;
  }

  static Future<LanDevice?> _quickProbe(String host, int timeoutMs) async {
    final open = <int>[];
    var bestRtt = -1;

    for (final port in kQuickProbePorts) {
      Socket? socket;
      final started = DateTime.now();
      try {
        socket = await Socket.connect(host, port, timeout: Duration(milliseconds: timeoutMs));
        final rtt = DateTime.now().difference(started).inMilliseconds;
        if (bestRtt < 0 || rtt < bestRtt) bestRtt = rtt;
        open.add(port);
        break;
      } catch (_) {
        continue;
      } finally {
        socket?.destroy();
      }
    }

    if (open.isEmpty) return null;
    return LanDevice(ip: host, openPorts: open, rttMs: bestRtt);
  }

  /// 补全设备信息：名字、MAC、厂商线索、网页标题
  static Future<LanDevice> enrich(LanDevice device, {Map<String, String> arp = const {}}) async {
    if (arp.containsKey(device.ip)) device.mac = arp[device.ip]!;

    final name = await DnsTool.reverseLookup(device.ip);
    if (name.isNotEmpty) device.hostname = name;

    if (device.openPorts.contains(80) || device.openPorts.contains(8080) || device.openPorts.contains(8000)) {
      final port = device.openPorts.contains(80)
          ? 80
          : device.openPorts.contains(8080)
              ? 8080
              : 8000;
      device.httpTitle = await _fetchTitle(device.ip, port);
    }

    device.vendorHint = _guessVendor(device.openPorts);
    return device;
  }

  static Future<String> _fetchTitle(String ip, int port) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 1500)
        ..badCertificateCallback = (_, __, ___) => true;
      final req = await client.getUrl(Uri.parse('http://$ip:$port/'));
      final resp = await req.close().timeout(const Duration(milliseconds: 2000));
      final body = await resp.transform(utf8.decoder).join().timeout(const Duration(milliseconds: 2000));
      client.close(force: true);
      final match = RegExp(r'<title[^>]*>([^<]{1,120})</title>', caseSensitive: false).firstMatch(body);
      final server = resp.headers.value('server') ?? '';
      final title = match?.group(1)?.trim() ?? '';
      if (title.isNotEmpty && server.isNotEmpty) return '$title ($server)';
      return title.isNotEmpty ? title : server;
    } catch (_) {
      return '';
    }
  }

  static String _guessVendor(List<int> ports) {
    if (ports.contains(62078)) return 'iPhone / iPad';
    if (ports.contains(9100) || ports.contains(631)) return '打印机';
    if (ports.contains(445) || ports.contains(135) || ports.contains(3389)) return 'Windows 设备';
    if (ports.contains(22) && ports.contains(53)) return '路由器 / 网络设备';
    if (ports.contains(5555)) return 'Android (ADB 开启)';
    if (ports.contains(32400)) return 'Plex 媒体服务器';
    if (ports.contains(2049)) return 'NAS (NFS)';
    if (ports.contains(22)) return 'Linux / 网络设备';
    if (ports.contains(443) || ports.contains(80)) return '通用设备';
    return '';
  }
}

// ------------------------------------------------------------- 风险研判

class RiskAnalyzer {
  /// 已知高危/中危服务端口
  static const _danger = {
    23: 'Telnet：账号密码全程明文传输，抓包即可还原',
    5555: 'ADB 调试端口：可远程安装应用、读取文件',
    2375: 'Docker API 未加密：等于把服务器 root 权限交出去',
    6379: 'Redis 默认无密码：常被写入 SSH 公钥提权',
    11211: 'Memcached：可被反射放大攻击利用',
    9200: 'Elasticsearch：默认无认证，数据裸奔',
    27017: 'MongoDB：历史默认无认证',
  };

  static const _warning = {
    21: 'FTP：明文协议，凭据可被嗅探，建议改 SFTP',
    445: 'SMB：勒索病毒横向传播的主要入口',
    3389: 'RDP：远程桌面暴露，易被暴力破解',
    5900: 'VNC：常见弱口令或无认证',
    139: 'NetBIOS：信息泄露面较大',
    1433: 'MSSQL：数据库直接暴露在局域网',
    3306: 'MySQL：数据库直接暴露在局域网',
    5432: 'PostgreSQL：数据库直接暴露在局域网',
  };

  static const _notice = {
    161: 'SNMP：默认 community 常为 public，会泄露设备全部信息',
    1900: 'UPnP：可被用于穿透 NAT，部分路由器存在命令执行漏洞',
    80: 'HTTP：管理页面为明文，同网段可被劫持',
    8080: 'HTTP 代理/管理口：确认是否需要对外开放',
  };

  static List<RiskItem> analyzePorts(List<PortResult> ports) {
    final items = <RiskItem>[];
    for (final p in ports) {
      if (!p.open) continue;
      if (_danger.containsKey(p.port)) {
        items.add(RiskItem(
          title: '高危端口 ${p.port} (${kPortServices[p.port] ?? '未知'})',
          detail: _danger[p.port]!,
          level: RiskLevel.danger,
          suggestion: '若不需要，立即在设备上关闭该服务或加防火墙规则',
        ));
      } else if (_warning.containsKey(p.port)) {
        items.add(RiskItem(
          title: '中危端口 ${p.port} (${kPortServices[p.port] ?? '未知'})',
          detail: _warning[p.port]!,
          level: RiskLevel.warning,
          suggestion: '限制来源 IP，或改用加密替代协议',
        ));
      } else if (_notice.containsKey(p.port)) {
        items.add(RiskItem(
          title: '留意端口 ${p.port} (${kPortServices[p.port] ?? '未知'})',
          detail: _notice[p.port]!,
          level: RiskLevel.notice,
        ));
      }
    }
    return items;
  }

  /// 打开端口数量过多本身也是个信号
  static List<RiskItem> analyzeOverview({required int deviceCount, required List<LanDevice> devices}) {
    final items = <RiskItem>[];
    final withDanger = devices.where((d) => d.openPorts.any((p) => _danger.containsKey(p))).toList();
    if (withDanger.isNotEmpty) {
      items.add(RiskItem(
        title: '发现 ${withDanger.length} 台设备暴露高危服务',
        detail: withDanger.map((d) => d.ip).take(6).join('、'),
        level: RiskLevel.danger,
        suggestion: '优先处理这些主机，它们是最容易被拿下的入口',
      ));
    }
    final adb = devices.where((d) => d.openPorts.contains(5555)).toList();
    if (adb.isNotEmpty) {
      items.add(RiskItem(
        title: 'ADB 调试端口对局域网开放',
        detail: '${adb.length} 台设备（${adb.map((d) => d.ip).join('、')}）的 5555 端口可连',
        level: RiskLevel.danger,
        suggestion: '在开发者选项里关闭「USB 调试」或「无线调试」',
      ));
    }
    if (deviceCount > 25) {
      items.add(RiskItem(
        title: '网段内设备偏多（$deviceCount 台）',
        detail: '可能存在未授权的接入设备，建议核对名单',
        level: RiskLevel.notice,
      ));
    }
    return items;
  }

  static List<RiskItem> analyzeWifi(List<WifiAp> aps) {
    final items = <RiskItem>[];
    final open = aps.where((a) => a.security == WifiSecurity.open).toList();
    final wep = aps.where((a) => a.security == WifiSecurity.wep).toList();
    final wpa = aps.where((a) => a.security == WifiSecurity.wpa).toList();

    if (open.isNotEmpty) {
      items.add(RiskItem(
        title: '发现 ${open.length} 个开放（无密码）WiFi',
        detail: open.map((a) => a.displayName).take(5).join('、'),
        level: RiskLevel.danger,
        suggestion: '不要在这些网络上登录账号或支付，流量可被同网段任意嗅探',
      ));
    }
    if (wep.isNotEmpty) {
      items.add(RiskItem(
        title: '发现 ${wep.length} 个使用 WEP 加密的 WiFi',
        detail: wep.map((a) => a.displayName).take(5).join('、'),
        level: RiskLevel.danger,
        suggestion: 'WEP 几分钟即可破解，路由器需改为 WPA2/WPA3',
      ));
    }
    if (wpa.isNotEmpty) {
      items.add(RiskItem(
        title: '发现 ${wpa.length} 个仅 WPA 加密的 WiFi',
        detail: wpa.map((a) => a.displayName).take(5).join('、'),
        level: RiskLevel.warning,
        suggestion: 'WPA(TKIP) 已被证明不安全，建议升级到 WPA2-AES 或 WPA3',
      ));
    }
    return items;
  }
}
