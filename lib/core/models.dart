/// 数据模型
library;

/// WiFi 安全类型
enum WifiSecurity { open, wep, wpa, wpa2, wpa3, enterprise, unknown }

class WifiAp {
  final String ssid;
  final String bssid;
  final int rssi;
  final int frequency;
  final int channel;
  final String band;
  final int width;
  final String capabilities;
  final int ageMs;

  const WifiAp({
    required this.ssid,
    required this.bssid,
    required this.rssi,
    required this.frequency,
    required this.channel,
    required this.band,
    required this.width,
    required this.capabilities,
    required this.ageMs,
  });

  factory WifiAp.fromMap(Map<String, dynamic> m) => WifiAp(
        ssid: (m['ssid'] as String?)?.trim() ?? '',
        bssid: (m['bssid'] as String?) ?? '',
        rssi: (m['rssi'] as num?)?.toInt() ?? -100,
        frequency: (m['frequency'] as num?)?.toInt() ?? 0,
        channel: (m['channel'] as num?)?.toInt() ?? 0,
        band: (m['band'] as String?) ?? '',
        width: (m['width'] as num?)?.toInt() ?? 20,
        capabilities: (m['capabilities'] as String?) ?? '',
        ageMs: (m['ageMs'] as num?)?.toInt() ?? 0,
      );

  String get displayName => ssid.isEmpty ? '<隐藏网络>' : ssid;

  /// 部分设备/模拟器拿不到真实信号值时会返回 0，需要单独标注
  bool get hasRssi => rssi != 0;

  int get quality => hasRssi ? rssiToQuality(rssi) : 0;

  WifiSecurity get security {
    final c = capabilities.toUpperCase();
    if (c.contains('WPA3') || c.contains('SAE')) return WifiSecurity.wpa3;
    if (c.contains('WPA2') || c.contains('RSN')) {
      return c.contains('EAP') ? WifiSecurity.enterprise : WifiSecurity.wpa2;
    }
    if (c.contains('WPA')) return WifiSecurity.wpa;
    if (c.contains('WEP')) return WifiSecurity.wep;
    return WifiSecurity.open;
  }

  String get securityLabel {
    switch (security) {
      case WifiSecurity.open:
        return '开放';
      case WifiSecurity.wep:
        return 'WEP';
      case WifiSecurity.wpa:
        return 'WPA';
      case WifiSecurity.wpa2:
        return 'WPA2';
      case WifiSecurity.wpa3:
        return 'WPA3';
      case WifiSecurity.enterprise:
        return 'WPA2-企业';
      case WifiSecurity.unknown:
        return '未知';
    }
  }

  bool get isDangerous => security == WifiSecurity.open || security == WifiSecurity.wep;
}

/// 当前连接信息
class WifiConn {
  final bool connected;
  final String ssid;
  final String bssid;
  final String ip;
  final String gateway;
  final String mac;
  final int prefix;
  final int rssi;
  final int frequency;
  final int channel;
  final int linkSpeed;
  final bool rssiAvailable;
  final List<String> dns;
  final double probeRtt;
  final bool probeLoss;
  final String note;

  const WifiConn({
    this.connected = false,
    this.ssid = '',
    this.bssid = '',
    this.ip = '',
    this.gateway = '',
    this.mac = '',
    this.prefix = 24,
    this.rssi = 0,
    this.frequency = 0,
    this.channel = 0,
    this.linkSpeed = 0,
    this.rssiAvailable = true,
    this.dns = const [],
    this.probeRtt = -1,
    this.probeLoss = false,
    this.note = '',
  });

  factory WifiConn.fromMap(Map<String, dynamic> m) => WifiConn(
        connected: m['connected'] == true,
        ssid: (m['ssid'] as String?) ?? '',
        bssid: (m['bssid'] as String?) ?? '',
        ip: (m['ip'] as String?) ?? '',
        gateway: (m['gateway'] as String?) ?? '',
        mac: (m['mac'] as String?) ?? '',
        prefix: (m['prefix'] as num?)?.toInt() ?? 24,
        rssi: (m['rssi'] as num?)?.toInt() ?? 0,
        frequency: (m['frequency'] as num?)?.toInt() ?? 0,
        channel: (m['channel'] as num?)?.toInt() ?? 0,
        linkSpeed: (m['linkSpeed'] as num?)?.toInt() ?? 0,
        rssiAvailable: m['rssiAvailable'] != false,
        dns: ((m['dns'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
        probeRtt: (m['probeRtt'] as num?)?.toDouble() ?? -1,
        probeLoss: m['probeLoss'] == true,
        note: (m['scanNote'] as String?) ?? '',
      );

  String get displaySsid {
    if (ssid.isNotEmpty) return ssid;
    if (connected) return '已连接（名称需定位权限）';
    return '未连接';
  }

  /// 统一的质量分：Android 用真实 RSSI，iOS 用网关时延代理
  int get quality {
    if (rssiAvailable && rssi != 0) return rssiToQuality(rssi);
    if (probeLoss) return 0;
    if (probeRtt < 0) return 0;
    // 2ms 以内视作满格，300ms 以上视作掉到 0
    final q = 100 - ((probeRtt - 2) / 3).round();
    return q.clamp(0, 100);
  }

  String get band {
    if (frequency <= 0) return '';
    if (frequency < 3000) return '2.4G';
    if (frequency < 5925) return '5G';
    return '6G';
  }

  String get network {
    if (ip.isEmpty) return '';
    final p = prefix.clamp(8, 30);
    final mask = (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF;
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.contains(null)) return ip;
    final ipInt = (parts[0]! << 24) | (parts[1]! << 16) | (parts[2]! << 8) | parts[3]!;
    final net = ipInt & mask;
    return '${(net >> 24) & 0xFF}.${(net >> 16) & 0xFF}.${(net >> 8) & 0xFF}.${net & 0xFF}/$p';
  }
}

/// RSSI -> 0..100
int rssiToQuality(int rssi) {
  if (rssi >= -50) return 100;
  if (rssi <= -100) return 0;
  return ((rssi + 100) * 2).clamp(0, 100);
}

String qualityLabel(int q) {
  if (q >= 80) return '极佳';
  if (q >= 65) return '良好';
  if (q >= 45) return '一般';
  if (q >= 25) return '较弱';
  return '很差';
}

/// 局域网设备
class LanDevice {
  final String ip;
  String hostname;
  String mac;
  int rttMs;
  final List<int> openPorts;
  String vendorHint;
  String httpTitle;
  bool isGateway;
  bool isSelf;

  LanDevice({
    required this.ip,
    this.hostname = '',
    this.mac = '',
    this.rttMs = -1,
    List<int>? openPorts,
    this.vendorHint = '',
    this.httpTitle = '',
    this.isGateway = false,
    this.isSelf = false,
  }) : openPorts = openPorts ?? <int>[];

  String get label {
    if (hostname.isNotEmpty) return hostname;
    if (vendorHint.isNotEmpty) return vendorHint;
    return ip;
  }
}

/// 端口扫描结果
class PortResult {
  final int port;
  final bool open;
  final int rttMs;
  final String banner;

  const PortResult({
    required this.port,
    required this.open,
    this.rttMs = -1,
    this.banner = '',
  });
}

/// 风险等级
enum RiskLevel { info, notice, warning, danger }

class RiskItem {
  final String title;
  final String detail;
  final RiskLevel level;
  final String suggestion;

  const RiskItem({
    required this.title,
    required this.detail,
    required this.level,
    this.suggestion = '',
  });
}
