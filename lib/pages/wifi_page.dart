import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/models.dart';
import '../core/nettools.dart';
import '../theme.dart';
import '../widgets/charts.dart';

class WifiPage extends StatefulWidget {
  const WifiPage({super.key});

  @override
  State<WifiPage> createState() => _WifiPageState();
}

class _WifiPageState extends State<WifiPage> with WidgetsBindingObserver {
  WifiCapability _cap = const WifiCapability();
  WifiConn _conn = const WifiConn();
  List<WifiAp> _aps = const [];
  List<RiskItem> _risks = const [];

  final List<double> _history = [];
  StreamSubscription<WifiConn>? _rssiSub;

  bool _scanning = false;
  bool _soundOn = false;
  String _scanNote = '';
  DateTime _lastScan = DateTime.fromMillisecondsSinceEpoch(0);
  int _weakStreak = 0;
  bool _weakAlert = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rssiSub?.cancel();
    if (_soundOn) NativeProbe.toneStop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _soundOn) {
      NativeProbe.toneStop();
    } else if (state == AppLifecycleState.resumed && _soundOn) {
      NativeProbe.toneStart(volume: 0.2, freq: 500);
    }
  }

  Future<void> _bootstrap() async {
    var cap = await NativeWifi.capabilities();

    // 首次进入主动申请定位权限：Android 扫描 WiFi、iOS 读取 SSID 都依赖它
    if (!cap.locationPermission) {
      await NativeWifi.requestPermissions();
      cap = await NativeWifi.capabilities();
    }

    final conn = await NativeWifi.current();
    if (!mounted) return;

    setState(() {
      _cap = cap;
      _conn = conn;
    });

    _rssiSub?.cancel();
    _rssiSub = NativeWifi.rssiStream().listen(_onRssi, onError: (_) {});

    if (cap.canScan) {
      await _doScan(auto: true);
    } else {
      setState(() {
        _scanNote = cap.scanNote.isNotEmpty ? cap.scanNote : '当前平台不支持扫描附近 WiFi';
      });
    }
  }

  void _onRssi(WifiConn incoming) {
    if (!mounted) return;

    final merged = WifiConn(
      connected: incoming.connected || _conn.connected,
      ssid: incoming.ssid.isNotEmpty ? incoming.ssid : _conn.ssid,
      bssid: incoming.bssid.isNotEmpty ? incoming.bssid : _conn.bssid,
      ip: incoming.ip.isNotEmpty ? incoming.ip : _conn.ip,
      gateway: incoming.gateway.isNotEmpty ? incoming.gateway : _conn.gateway,
      mac: _conn.mac,
      prefix: incoming.prefix > 0 ? incoming.prefix : _conn.prefix,
      rssi: incoming.rssi != 0 ? incoming.rssi : _conn.rssi,
      frequency: incoming.frequency != 0 ? incoming.frequency : _conn.frequency,
      channel: incoming.channel != 0 ? incoming.channel : _conn.channel,
      linkSpeed: incoming.linkSpeed != 0 ? incoming.linkSpeed : _conn.linkSpeed,
      rssiAvailable: _conn.rssiAvailable,
      dns: _conn.dns,
      probeRtt: incoming.probeRtt,
      probeLoss: incoming.probeLoss,
      note: _conn.note,
    );

    final q = merged.quality;

    setState(() {
      _conn = merged;
      _history.add(q.toDouble());
      if (_history.length > 120) _history.removeAt(0);

      if (q < 30) {
        _weakStreak++;
        if (_weakStreak >= 3 && !_weakAlert) _weakAlert = true;
      } else {
        _weakStreak = 0;
        _weakAlert = false;
      }
    });

    if (_soundOn) {
      NativeProbe.toneUpdate(
        volume: (q / 100 * 0.85).clamp(0.03, 0.9),
        freq: 280 + q * 9.0,
      );
    }
  }

  Future<void> _doScan({bool auto = false}) async {
    if (_scanning) return;

    final elapsed = DateTime.now().difference(_lastScan).inSeconds;
    if (!auto && elapsed < 15) {
      _toast('请稍候 ${15 - elapsed} 秒再扫描（系统限制扫描频率）');
      return;
    }

    setState(() => _scanning = true);

    if (!_cap.locationPermission) {
      await NativeWifi.requestPermissions();
    }

    final outcome = await NativeWifi.scan();
    if (!mounted) return;

    final sorted = [...outcome.list]..sort((a, b) => b.rssi.compareTo(a.rssi));

    setState(() {
      _scanning = false;
      _lastScan = DateTime.now();
      if (outcome.ok) {
        _aps = sorted;
        _risks = RiskAnalyzer.analyzeWifi(sorted);
        _scanNote = outcome.throttled ? '系统限流，显示的是上一轮缓存结果' : '';
      } else {
        _scanNote = outcome.reason;
        if (outcome.throttled) _scanNote = '扫描被系统限流，请稍后再试';
      }
    });

    if (!auto && outcome.ok && sorted.isEmpty) {
      _toast('没有扫描到网络，请确认定位服务已开启');
    }
  }

  void _toggleSound() {
    setState(() => _soundOn = !_soundOn);
    if (_soundOn) {
      NativeProbe.toneStart(volume: (_conn.quality / 100 * 0.85).clamp(0.05, 0.9), freq: 280 + _conn.quality * 9.0);
    } else {
      NativeProbe.toneStop();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WiFi 分析'),
        actions: [
          IconButton(
            tooltip: _soundOn ? '关闭信号提示音' : '开启信号提示音',
            onPressed: _toggleSound,
            icon: Icon(
              _soundOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              color: _soundOn ? AppColors.accent : AppColors.textFaint,
            ),
          ),
          IconButton(
            tooltip: '重新扫描',
            onPressed: _cap.canScan ? () => _doScan() : null,
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.accent,
        backgroundColor: AppColors.surface,
        onRefresh: () async => _cap.canScan ? _doScan() : _bootstrap(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
          children: [
            _currentCard(),
            const SizedBox(height: 12),
            _liveChart(),
            if (_weakAlert) ...[
              const SizedBox(height: 10),
              _alertBanner('信号持续偏弱，可能已远离路由器或存在干扰。'),
            ],
            if (!_cap.canScan) ...[
              const SizedBox(height: 10),
              _platformNotice(),
            ],
            if (_risks.isNotEmpty) ...[
              const SectionTitle('WiFi 安全提示'),
              ..._risks.map(_riskTile),
            ],
            SectionTitle(
              '附近网络',
              trailing: Text(
                _aps.isEmpty ? '' : '${_aps.length} 个',
                style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5),
              ),
            ),
            if (_scanNote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _scanNote,
                  style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5, height: 1.4),
                ),
              ),
            if (_aps.isEmpty)
              Panel(
                child: Text(
                  _cap.canScan ? '暂无数据，下拉或点击右上角刷新' : '获得权限后才能列出附近 WiFi',
                  style: const TextStyle(color: AppColors.textDim, fontSize: 13),
                ),
              )
            else
              ..._aps.map(_apTile),
            if (_aps.any((a) => a.band == '2.4G')) ...[
              const SectionTitle('2.4G 信道占用'),
              Panel(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                child: ChannelChart(aps: _aps, band: '2.4G'),
              ),
            ],
            if (_aps.any((a) => a.band == '5G')) ...[
              const SectionTitle('5G 信道占用'),
              Panel(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                child: ChannelChart(aps: _aps, band: '5G'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _currentCard() {
    final q = _conn.quality;
    final color = qualityColor(q);

    return Panel(
      padding: const EdgeInsets.all(16),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.surface, color.withOpacity(0.07)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SignalRing(
                quality: q,
                centerTop: _conn.rssiAvailable && _conn.rssi != 0 ? '${_conn.rssi}' : '$q',
                centerBottom: _conn.rssiAvailable && _conn.rssi != 0 ? 'dBm' : '质量分',
                size: 116,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _conn.displaySsid,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        Chip2(qualityLabel(q), color: color),
                        if (_conn.band.isNotEmpty) Chip2(_conn.band, color: AppColors.blue),
                        if (_conn.channel > 0) Chip2('信道 ${_conn.channel}', color: AppColors.purple),
                        if (_conn.linkSpeed > 0) Chip2('${_conn.linkSpeed} Mbps', color: AppColors.textDim),
                        if (!_conn.rssiAvailable) const Chip2('延迟代理', color: AppColors.warn),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_conn.rssiAvailable && _conn.rssi != 0)
                      _kv('信号强度', '${_conn.rssi} dBm')
                    else if (_conn.probeRtt >= 0)
                      _kv('网关时延', '${_conn.probeRtt.toStringAsFixed(1)} ms')
                    else
                      _kv('链路状态', '测量中…'),
                    _kv('本机 IP', _conn.ip.isEmpty ? '—' : _conn.ip),
                    _kv('网关', _conn.gateway.isEmpty ? '—' : _conn.gateway),
                  ],
                ),
              ),
            ],
          ),
          if (_conn.note.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _conn.note,
              style: const TextStyle(color: AppColors.textFaint, fontSize: 11, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(k, style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5)),
          ),
          Expanded(
            child: Text(
              v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textDim,
                fontSize: 11.5,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _liveChart() {
    final q = _conn.quality;
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '实时质量曲线',
                style: TextStyle(color: AppColors.text, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (_soundOn) ...[
                const Icon(Icons.graphic_eq_rounded, size: 13, color: AppColors.accent),
                const SizedBox(width: 4),
              ],
              Text(
                '$q',
                style: TextStyle(
                  color: qualityColor(q),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          RealtimeSpark(values: List<double>.from(_history), color: qualityColor(q)),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                _conn.rssiAvailable ? '数据源：RSSI' : '数据源：网关 ICMP 时延',
                style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
              ),
              const Spacer(),
              Text(
                '最近 ${_history.length} 秒',
                style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _alertBanner(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.danger.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.danger, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _platformNotice() {
    if (_cap.isIOS) return _iosNotice();

    final needPerm = !_cap.locationPermission;
    final needLoc = !_cap.locationEnabled;

    return Panel(
      borderColor: AppColors.warn.withOpacity(0.4),
      color: AppColors.warn.withOpacity(0.07),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline_rounded, color: AppColors.warn, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  needPerm ? '还差一步：授予「定位」权限' : (needLoc ? '系统定位服务未开启' : '无法扫描'),
                  style: const TextStyle(
                    color: AppColors.warn,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            needPerm
                ? 'Android 规定：读取 WiFi 扫描结果必须同时持有定位权限并开启系统定位开关'
                  '（因为扫描到的 AP 列表可用于推算你的位置）。权限只在本机使用，不会上传。'
                : '请到「设置 → 定位」打开定位服务，返回后下拉刷新即可扫描。',
            style: TextStyle(color: AppColors.warn.withOpacity(0.9), fontSize: 11.5, height: 1.55),
          ),
          if (needPerm) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  await NativeWifi.requestPermissions();
                  await _bootstrap();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.warn,
                  side: BorderSide(color: AppColors.warn.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                ),
                child: const Text(
                  '授予权限并重试',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _iosNotice() {
    return Panel(
      borderColor: AppColors.warn.withOpacity(0.4),
      color: AppColors.warn.withOpacity(0.07),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: AppColors.warn, size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'iOS 不开放附近 WiFi 扫描接口，也拿不到真实 dBm。\n'
              '本页的信号曲线改用「网关 ICMP 时延」映射为质量分，'
              '时延越低代表链路越好，体感与信号强度一致。\n'
              '想看邻居网络的信道与强度，请用 Android 端，或配一个 ESP32 探针。',
              style: TextStyle(
                color: AppColors.warn.withOpacity(0.92),
                fontSize: 11.5,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _riskTile(RiskItem item) {
    final color = riskColor(item.level);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withOpacity(0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                item.level == RiskLevel.danger ? Icons.dangerous_outlined : Icons.report_problem_outlined,
                color: color,
                size: 15,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.title,
                  style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            item.detail,
            style: const TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.45),
          ),
          if (item.suggestion.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '建议：${item.suggestion}',
              style: const TextStyle(color: AppColors.textFaint, fontSize: 11, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _apTile(WifiAp ap) {
    final color = qualityColor(ap.quality);
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          SignalBars(ap.quality, width: 24),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ap.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ap.ssid.isEmpty ? AppColors.textFaint : AppColors.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      ap.bssid,
                      style: const TextStyle(
                        color: AppColors.textFaint,
                        fontSize: 10,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      'CH ${ap.channel}',
                      style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
                    ),
                    const SizedBox(width: 7),
                    Flexible(child: Chip2(ap.securityLabel, color: ap.isDangerous ? AppColors.danger : AppColors.textDim)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                ap.hasRssi ? '${ap.rssi}' : '—',
                style: TextStyle(
                  color: ap.hasRssi ? color : AppColors.textFaint,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                ap.hasRssi ? 'dBm' : '无值',
                style: TextStyle(color: AppColors.textFaint.withOpacity(0.8), fontSize: 9),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
