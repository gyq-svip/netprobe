/// 原生桥接：通道名与 Android(Kotlin) / iOS(Swift) 两侧严格一致
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

class WifiCapability {
  final String platform;
  final bool canScan;
  final bool realRssi;
  final bool locationPermission;
  final bool locationEnabled;
  final bool canReadArp;
  final String scanNote;

  const WifiCapability({
    this.platform = '',
    this.canScan = false,
    this.realRssi = false,
    this.locationPermission = false,
    this.locationEnabled = false,
    this.canReadArp = false,
    this.scanNote = '',
  });

  factory WifiCapability.fromMap(Map<String, dynamic> m) => WifiCapability(
        platform: (m['platform'] as String?) ?? '',
        canScan: m['canScan'] == true,
        realRssi: m['realRssi'] == true,
        locationPermission: m['locationPermission'] == true,
        locationEnabled: m['locationEnabled'] == true,
        canReadArp: m['canReadArp'] == true,
        scanNote: (m['scanNote'] as String?) ?? '',
      );

  bool get isIOS => platform == 'ios';
}

class ScanOutcome {
  final bool ok;
  final bool throttled;
  final String reason;
  final List<WifiAp> list;

  const ScanOutcome({
    this.ok = false,
    this.throttled = false,
    this.reason = '',
    this.list = const [],
  });
}

class NativeWifi {
  static const _channel = MethodChannel('com.gyq.netprobe/wifi');
  static const _rssiChannel = EventChannel('com.gyq.netprobe/wifi_rssi');

  static Future<WifiCapability> capabilities() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('capabilities');
      return WifiCapability.fromMap(Map<String, dynamic>.from(raw ?? {}));
    } on PlatformException {
      return const WifiCapability(scanNote: '无法读取原生能力');
    }
  }

  static Future<WifiConn> current() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('current');
      return WifiConn.fromMap(Map<String, dynamic>.from(raw ?? {}));
    } on PlatformException catch (e) {
      return WifiConn(note: e.message ?? '读取失败');
    }
  }

  static Future<ScanOutcome> scan() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('scan');
      final map = Map<String, dynamic>.from(raw ?? {});
      final list = ((map['list'] as List?) ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map((e) => WifiAp.fromMap(Map<String, dynamic>.from(e)))
          .where((ap) => ap.bssid.isNotEmpty)
          .toList();
      return ScanOutcome(
        ok: map['ok'] == true,
        throttled: map['throttled'] == true,
        reason: (map['reason'] as String?) ?? '',
        list: list,
      );
    } on PlatformException catch (e) {
      return ScanOutcome(reason: e.message ?? '扫描失败');
    }
  }

  static Future<bool> requestPermissions() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('requestPermissions');
      final map = Map<String, dynamic>.from(raw ?? {});
      if (map.isEmpty) return false;
      return map.values.every((v) => v == true);
    } on PlatformException {
      return false;
    }
  }

  static Stream<WifiConn> rssiStream() {
    return _rssiChannel.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return WifiConn.fromMap(Map<String, dynamic>.from(event));
      }
      return const WifiConn();
    });
  }
}

/// ping / traceroute 的事件
class ProbeEvent {
  final String type;
  final String text;
  final double rtt;
  final int ttl;
  final int seq;
  final String ip;
  final int sent;
  final int received;
  final int loss;

  const ProbeEvent({
    this.type = '',
    this.text = '',
    this.rtt = -1,
    this.ttl = 0,
    this.seq = 0,
    this.ip = '',
    this.sent = 0,
    this.received = 0,
    this.loss = 0,
  });

  factory ProbeEvent.fromMap(Map<String, dynamic> m) => ProbeEvent(
        type: (m['type'] as String?) ?? '',
        text: (m['text'] as String?) ?? '',
        rtt: (m['rtt'] as num?)?.toDouble() ?? -1,
        ttl: (m['ttl'] as num?)?.toInt() ?? 0,
        seq: (m['seq'] as num?)?.toInt() ?? 0,
        ip: (m['ip'] as String?) ?? '',
        sent: (m['sent'] as num?)?.toInt() ?? 0,
        received: (m['received'] as num?)?.toInt() ?? 0,
        loss: (m['loss'] as num?)?.toInt() ?? 0,
      );
}

class TraceHop {
  final int hop;
  final String ip;
  final double rtt;
  final bool isFinal;
  final bool pending;
  final bool timeout;

  const TraceHop({
    required this.hop,
    this.ip = '',
    this.rtt = -1,
    this.isFinal = false,
    this.pending = false,
    this.timeout = false,
  });

  factory TraceHop.fromMap(Map<String, dynamic> m) => TraceHop(
        hop: (m['hop'] as num?)?.toInt() ?? 0,
        ip: (m['ip'] as String?) ?? '',
        rtt: (m['rtt'] as num?)?.toDouble() ?? -1,
        isFinal: m['final'] == true,
        pending: m['pending'] == true,
        timeout: m['timeout'] == true,
      );
}

class NativeProbe {
  static const _channel = MethodChannel('com.gyq.netprobe/probe');
  static const _pingChannel = EventChannel('com.gyq.netprobe/ping');
  static const _traceChannel = EventChannel('com.gyq.netprobe/trace');

  static Stream<ProbeEvent>? _pingStream;

  static Stream<ProbeEvent> pingEvents() {
    _pingStream ??= _pingChannel.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return ProbeEvent.fromMap(Map<String, dynamic>.from(event));
      }
      return const ProbeEvent(type: 'line');
    });
    return _pingStream!;
  }

  static Stream<TraceHop> traceEvents() {
    return _traceChannel.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return TraceHop.fromMap(Map<String, dynamic>.from(event));
      }
      return const TraceHop(hop: 0);
    });
  }

  static Future<void> startPing(String host, {int count = 4, double interval = 0.5}) async {
    await _channel.invokeMethod('ping', {
      'host': host,
      'count': count,
      'interval': interval,
    });
  }

  static Future<void> stopPing() async {
    try {
      await _channel.invokeMethod('stopPing');
    } on PlatformException {
      // 忽略
    }
  }

  static Future<void> startTrace(String host, {int maxHops = 20}) async {
    await _channel.invokeMethod('trace', {'host': host, 'maxHops': maxHops});
  }

  static Future<void> stopTrace() async {
    try {
      await _channel.invokeMethod('stopTrace');
    } on PlatformException {
      // 忽略
    }
  }

  static Future<Map<String, String>> arpTable() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('arpTable');
      if (raw == null) return {};
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    } on PlatformException {
      return {};
    }
  }

  static Future<void> toneStart({double volume = 0.3, double freq = 440}) async {
    try {
      await _channel.invokeMethod('toneStart', {'volume': volume, 'freq': freq});
    } on PlatformException {
      // 忽略
    }
  }

  static Future<void> toneUpdate({double? volume, double? freq}) async {
    try {
      await _channel.invokeMethod('toneUpdate', {
        if (volume != null) 'volume': volume,
        if (freq != null) 'freq': freq,
      });
    } on PlatformException {
      // 忽略
    }
  }

  static Future<void> toneStop() async {
    try {
      await _channel.invokeMethod('toneStop');
    } on PlatformException {
      // 忽略
    }
  }
}
