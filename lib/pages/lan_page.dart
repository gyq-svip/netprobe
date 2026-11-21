import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/models.dart';
import '../core/nettools.dart';
import '../theme.dart';

class LanPage extends StatefulWidget {
  const LanPage({super.key});

  @override
  State<LanPage> createState() => _LanPageState();
}

class _LanPageState extends State<LanPage> with AutomaticKeepAliveClientMixin {
  WifiConn _conn = const WifiConn();
  List<LanDevice> _devices = [];
  List<RiskItem> _risks = [];
  Map<String, String> _arp = {};

  bool _scanning = false;
  bool _enriching = false;
  bool _stopFlag = false;
  int _done = 0;
  int _total = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    final conn = await NativeWifi.current();
    if (!mounted) return;
    setState(() => _conn = conn);
  }

  Future<void> _startScan() async {
    if (_scanning) return;
    if (_conn.ip.isEmpty) {
      await _loadInfo();
      if (_conn.ip.isEmpty) {
        _toast('未获取到本机 IP，请先连接 WiFi');
        return;
      }
    }

    setState(() {
      _scanning = true;
      _enriching = false;
      _devices = [];
      _risks = [];
      _done = 0;
      _total = 0;
      _stopFlag = false;
    });

    _arp = await NativeProbe.arpTable();

    final devices = await LanScanner.scan(
      ip: _conn.ip,
      prefix: _conn.prefix,
      gateway: _conn.gateway,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
      shouldStop: () => _stopFlag,
    );

    if (!mounted) return;
    setState(() {
      _devices = devices;
      _scanning = false;
      _enriching = devices.isNotEmpty;
      _risks = RiskAnalyzer.analyzeOverview(
        deviceCount: devices.length,
        devices: devices,
      );
    });

    // 分批补全设备名与网页标题，避免一次性打爆 DNS
    for (var i = 0; i < devices.length; i += 8) {
      if (!mounted || _stopFlag) break;
      final batch = devices.skip(i).take(8).toList();
      await Future.wait(batch.map((d) => LanScanner.enrich(d, arp: _arp)));
      if (!mounted) return;
      setState(() {});
    }

    if (!mounted) return;
    setState(() => _enriching = false);
  }

  void _stop() {
    setState(() => _stopFlag = true);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  int _dangerCount() => _devices
      .where((d) => d.openPorts.any((p) => const [23, 5555, 2375, 6379, 11211].contains(p)))
      .length;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final progress = _total == 0 ? 0.0 : _done / _total;

    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网扫描'),
        actions: [
          IconButton(
            tooltip: '刷新网络信息',
            onPressed: _loadInfo,
            icon: const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lan_outlined, size: 17, color: AppColors.accent),
                    const SizedBox(width: 8),
                    Text(
                      _conn.network.isEmpty ? '未连接' : _conn.network,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (_devices.isNotEmpty)
                      Chip2('${_devices.length} 台在线', color: AppColors.accent),
                  ],
                ),
                const SizedBox(height: 10),
                _row('本机 IP', _conn.ip.isEmpty ? '—' : _conn.ip),
                _row('网关', _conn.gateway.isEmpty ? '—' : _conn.gateway),
                _row('MAC', _conn.mac.isEmpty ? '不可读' : _conn.mac),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _scanning ? null : _startScan,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: const Color(0xFF04170F),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: _scanning
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF04170F),
                                ),
                              )
                            : const Icon(Icons.radar_rounded, size: 18),
                        label: Text(
                          _scanning ? '扫描中 $_done/$_total' : '扫描全部设备',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                        ),
                      ),
                    ),
                    if (_scanning) ...[
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: _stop,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          side: BorderSide(color: AppColors.danger.withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                        child: const Text('停止', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ],
                ),
                if (_scanning) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress == 0 ? null : progress,
                      minHeight: 3,
                      backgroundColor: AppColors.border,
                      valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_devices.isNotEmpty && _dangerCount() > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.danger.withOpacity(0.45)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.gpp_bad_outlined, color: AppColors.danger, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '发现 ${_dangerCount()} 台设备暴露高危端口，建议尽快处理',
                      style: const TextStyle(color: AppColors.danger, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_risks.isNotEmpty) ...[
            const SectionTitle('风险概览'),
            ..._risks.map(_riskTile),
          ],
          SectionTitle(
            '在线设备',
            trailing: _enriching
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6, color: AppColors.textFaint),
                  )
                : Text(
                    _devices.isEmpty ? '' : '${_devices.length}',
                    style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5),
                  ),
          ),
          if (_devices.isEmpty && !_scanning)
            Panel(
              child: Text(
                '点击上方按钮开始扫描当前网段。\n扫描方式为并发 TCP 探测，不发送洪泛包，仅检测本机可达的主机。',
                style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.6),
              ),
            )
          else
            ..._devices.map(_deviceTile),
        ],
      ),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(k, style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5)),
          ),
          Expanded(
            child: Text(
              v,
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

  Widget _riskTile(RiskItem item) {
    final color = riskColor(item.level);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
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

  Widget _deviceTile(LanDevice d) {
    final risky = d.openPorts.any((p) => const [23, 5555, 2375, 6379].contains(p));
    final dotColor = risky ? AppColors.danger : (d.isGateway ? AppColors.blue : AppColors.accent);

    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DeviceDetailPage(device: d)),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          d.ip,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (d.isGateway) ...[
                          const SizedBox(width: 6),
                          const Chip2('网关', color: AppColors.blue),
                        ],
                        if (d.isSelf) ...[
                          const SizedBox(width: 6),
                          const Chip2('本机', color: AppColors.purple),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      d.label == d.ip ? (d.mac.isEmpty ? '无主机名' : d.mac) : d.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textFaint, fontSize: 10.5),
                    ),
                    if (d.openPorts.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: d.openPorts
                            .take(4)
                            .map((p) => Chip2('$p', color: AppColors.textDim))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ 设备详情页

class DeviceDetailPage extends StatefulWidget {
  final LanDevice device;

  const DeviceDetailPage({super.key, required this.device});

  @override
  State<DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<DeviceDetailPage> {
  List<PortResult> _ports = [];
  List<RiskItem> _risks = [];
  bool _scanning = false;
  int _done = 0;
  int _total = 0;
  bool _scanned = false;

  Future<void> _scanPorts() async {
    setState(() {
      _scanning = true;
      _ports = [];
      _risks = [];
      _done = 0;
      _total = kDetailPorts.length;
    });

    final result = await PortScanner.scan(
      widget.device.ip,
      onProgress: (d, t) {
        if (!mounted) return;
        setState(() {
          _done = d;
          _total = t;
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _ports = result;
      _risks = RiskAnalyzer.analyzePorts(result);
      _scanning = false;
      _scanned = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final danger = _risks.where((r) => r.level == RiskLevel.danger).length;

    return Scaffold(
      appBar: AppBar(title: Text(d.ip)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      d.isGateway ? Icons.router_rounded : Icons.devices_other_rounded,
                      color: AppColors.accent,
                      size: 20,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        d.label,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _kv('IP 地址', d.ip),
                _kv('MAC', d.mac.isEmpty ? '不可读（Android 10+ 限制）' : d.mac),
                _kv('响应时延', d.rttMs < 0 ? '—' : '${d.rttMs} ms'),
                if (d.httpTitle.isNotEmpty) _kv('网页标题', d.httpTitle),
                if (d.openPorts.isNotEmpty) _kv('已知端口', d.openPorts.join(', ')),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _scanning ? null : _scanPorts,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: const Color(0xFF04170F),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: _scanning
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF04170F)),
                  )
                : const Icon(Icons.security_rounded, size: 18),
            label: Text(
              _scanning ? '端口扫描 $_done/$_total' : '扫描开放端口与风险',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
            ),
          ),
          if (danger > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.danger.withOpacity(0.45)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.gpp_bad_outlined, color: AppColors.danger, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '该设备有 $danger 项高危风险，详见下方',
                      style: const TextStyle(color: AppColors.danger, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_risks.isNotEmpty) ...[
            const SectionTitle('安全风险'),
            ..._risks.map((r) {
              final color = riskColor(r.level);
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: color.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.title,
                      style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      r.detail,
                      style: const TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.5),
                    ),
                    if (r.suggestion.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '建议：${r.suggestion}',
                        style: const TextStyle(color: AppColors.textFaint, fontSize: 11, height: 1.4),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
          if (_scanned) ...[
            SectionTitle('开放端口', trailing: Chip2('${_ports.length} 个', color: AppColors.accent)),
            if (_ports.isEmpty)
              const Panel(
                child: Text(
                  '未发现开放端口（可能是设备开启了防火墙，或只响应未扫描的端口）',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.5),
                ),
              )
            else
              ..._ports.map((p) {
                final service = kPortServices[p.port] ?? '未知服务';
                final isRisky = _risks.any((r) => r.title.contains('${p.port} '));
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isRisky ? AppColors.danger.withOpacity(0.35) : AppColors.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          '${p.port}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          service,
                          style: const TextStyle(color: AppColors.text, fontSize: 12.5),
                        ),
                      ),
                      Text(
                        '${p.rttMs} ms',
                        style: const TextStyle(color: AppColors.textFaint, fontSize: 10.5),
                      ),
                    ],
                  ),
                );
              }),
          ],
          const SizedBox(height: 20),
          const Text(
            '提示：仅可对您自己拥有或已获得明确授权的网络与设备进行扫描。'
            '本工具不包含漏洞利用功能，风险提示基于开放服务与常见弱配置特征给出，不代表已确认存在漏洞。',
            style: TextStyle(color: AppColors.textFaint, fontSize: 10.5, height: 1.55),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(k, style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5)),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                color: AppColors.textDim,
                fontSize: 11.5,
                height: 1.4,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
