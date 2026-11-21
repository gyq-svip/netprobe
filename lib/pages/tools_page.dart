import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/nettools.dart';
import '../theme.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网络工具'),
        bottom: TabBar(
          controller: _tab,
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.textFaint,
          indicatorColor: AppColors.accent,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 13),
          tabs: const [
            Tab(text: 'Ping'),
            Tab(text: 'Traceroute'),
            Tab(text: 'DNS 查询'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _PingTab(),
          _TraceTab(),
          _DnsTab(),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- Ping

class _PingTab extends StatefulWidget {
  const _PingTab();

  @override
  State<_PingTab> createState() => _PingTabState();
}

class _PingTabState extends State<_PingTab> with AutomaticKeepAliveClientMixin {
  final _host = TextEditingController(text: '');
  final _log = <String>[];
  final _rtts = <double>[];

  StreamSubscription<ProbeEvent>? _sub;
  bool _running = false;
  int _loss = 0;
  int _sent = 0;
  int _received = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _sub?.cancel();
    if (_running) NativeProbe.stopPing();
    _host.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;

    _log.clear();
    _rtts.clear();
    setState(() {
      _running = true;
      _loss = 0;
      _sent = 0;
      _received = 0;
    });

    _sub?.cancel();
    _sub = NativeProbe.pingEvents().listen((e) {
      if (!mounted) return;
      setState(() {
        switch (e.type) {
          case 'reply':
            _log.add('${e.rtt.toStringAsFixed(1)} ms    ttl=${e.ttl == 0 ? '-' : e.ttl}');
            _rtts.add(e.rtt);
            break;
          case 'line':
            _log.add(e.text);
            break;
          case 'error':
            _log.add('× ${e.text}');
            _running = false;
            break;
          case 'done':
            _sent = e.sent;
            _received = e.received;
            _loss = e.loss;
            _log.add('—— 完成：接收 $_received/$_sent，丢包 $_loss% ——');
            _running = false;
            break;
        }
      });
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        _log.add('× $e');
        _running = false;
      });
    });

    final count = 4;
    await NativeProbe.startPing(host, count: count, interval: 0.5);
  }

  Future<void> _stop() async {
    await NativeProbe.stopPing();
    if (!mounted) return;
    setState(() => _running = false);
  }

  double get _avg => _rtts.isEmpty ? 0 : _rtts.reduce((a, b) => a + b) / _rtts.length;
  double get _min => _rtts.isEmpty ? 0 : _rtts.reduce((a, b) => a < b ? a : b);
  double get _max => _rtts.isEmpty ? 0 : _rtts.reduce((a, b) => a > b ? a : b);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        _inputRow(
          controller: _host,
          hint: '域名或 IP，例如 192.168.1.1',
          running: _running,
          onRun: _start,
          onStop: _stop,
        ),
        if (_rtts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Panel(
            child: Row(
              children: [
                _stat('最小', '${_min.toStringAsFixed(1)}'),
                _stat('平均', '${_avg.toStringAsFixed(1)}'),
                _stat('最大', '${_max.toStringAsFixed(1)}'),
                _stat('丢包', '$_loss%', color: _loss > 0 ? AppColors.danger : AppColors.accent),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        _logPanel(_log, empty: '输入地址后点击 Ping'),
      ],
    );
  }
}

// ------------------------------------------------------------- Traceroute

class _TraceTab extends StatefulWidget {
  const _TraceTab();

  @override
  State<_TraceTab> createState() => _TraceTabState();
}

class _TraceTabState extends State<_TraceTab> with AutomaticKeepAliveClientMixin {
  final _host = TextEditingController(text: '');
  final List<TraceHop> _hops = [];
  StreamSubscription<TraceHop>? _sub;
  bool _running = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _sub?.cancel();
    if (_running) NativeProbe.stopTrace();
    _host.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;

    _hops.clear();
    setState(() => _running = true);

    _sub?.cancel();
    _sub = NativeProbe.traceEvents().listen((hop) {
      if (!mounted) return;
      setState(() {
        if (hop.hop == 0) return;
        final idx = _hops.indexWhere((h) => h.hop == hop.hop);
        if (idx >= 0) {
          _hops[idx] = hop;
        } else {
          _hops.add(hop);
        }
      });
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() => _running = false);
    });

    await NativeProbe.startTrace(host, maxHops: 20);
    if (mounted && _running) {
      // 原生侧结束后不会有额外通知，靠超时兜底解锁
      Timer(const Duration(seconds: 30), () {
        if (mounted && _running) setState(() => _running = false);
      });
    }
  }

  Future<void> _stop() async {
    await NativeProbe.stopTrace();
    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        _inputRow(
          controller: _host,
          hint: '目标域名或 IP',
          running: _running,
          onRun: _start,
          onStop: _stop,
          runLabel: '开始追踪',
        ),
        const SizedBox(height: 12),
        if (_hops.isEmpty)
          const Panel(
            child: Text(
              'Traceroute 逐跳探测到目标经过的路由节点。\n'
              'Android 走系统 ping 的 TTL 递增，iOS 走 ICMP 原生实现。\n'
              '部分节点不响应 ICMP，会显示为超时，属正常现象。',
              style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.6),
            ),
          )
        else
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              children: _hops.map((h) {
                final color = h.pending
                    ? AppColors.textFaint
                    : h.timeout
                        ? AppColors.textFaint
                        : h.isFinal
                            ? AppColors.accent
                            : AppColors.text;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 26,
                        child: Text(
                          '${h.hop}',
                          style: const TextStyle(
                            color: AppColors.textFaint,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          h.pending ? '探测中…' : (h.timeout ? '*  *  *' : (h.ip.isEmpty ? '—' : h.ip)),
                          style: TextStyle(
                            color: color,
                            fontSize: 12.5,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Text(
                        h.rtt < 0 ? '' : '${h.rtt.toStringAsFixed(1)} ms',
                        style: const TextStyle(color: AppColors.textFaint, fontSize: 11),
                      ),
                      if (h.isFinal) ...[
                        const SizedBox(width: 6),
                        const Chip2('到达', color: AppColors.accent),
                      ],
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

// -------------------------------------------------------------------- DNS

class _DnsTab extends StatefulWidget {
  const _DnsTab();

  @override
  State<_DnsTab> createState() => _DnsTabState();
}

class _DnsTabState extends State<_DnsTab> with AutomaticKeepAliveClientMixin {
  final _host = TextEditingController(text: '');
  String _type = 'A';
  bool _running = false;
  bool _useLocal = false;
  DnsResult? _result;
  List<String> _localIps = [];

  static const _types = ['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'SOA', 'PTR'];

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _query() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;

    setState(() {
      _running = true;
      _result = null;
      _localIps = [];
    });

    final local = await DnsTool.localLookup(host);
    final result = await DnsTool.query(host, type: _type);

    if (!mounted) return;
    setState(() {
      _localIps = local;
      _result = result;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        TextField(
          controller: _host,
          style: const TextStyle(color: AppColors.text, fontSize: 13.5),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _query(),
          decoration: const InputDecoration(hintText: '域名，例如 example.com'),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 30,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _types.length,
            separatorBuilder: (_, __) => const SizedBox(width: 7),
            itemBuilder: (context, i) {
              final t = _types[i];
              final active = t == _type;
              return GestureDetector(
                onTap: () => setState(() => _type = t),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? AppColors.accent.withOpacity(0.15) : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: active ? AppColors.accent.withOpacity(0.6) : AppColors.border,
                    ),
                  ),
                  child: Text(
                    t,
                    style: TextStyle(
                      color: active ? AppColors.accent : AppColors.textDim,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _running ? null : _query,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: const Color(0xFF04170F),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: _running
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF04170F)),
                      )
                    : const Icon(Icons.search_rounded, size: 17),
                label: Text(
                  _running ? '查询中…' : '查询 $_type 记录',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
            ),
            const SizedBox(width: 9),
            OutlinedButton(
              onPressed: () => setState(() => _useLocal = !_useLocal),
              style: OutlinedButton.styleFrom(
                foregroundColor: _useLocal ? AppColors.accent : AppColors.textDim,
                side: BorderSide(color: _useLocal ? AppColors.accent : AppColors.border),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              child: const Text('本地解析', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_useLocal && _localIps.isNotEmpty) ...[
          const SizedBox(height: 12),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '系统解析器结果',
                  style: TextStyle(color: AppColors.text, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                ..._localIps.map((ip) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        ip,
                        style: const TextStyle(
                          color: AppColors.textDim,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ],
        if (_result != null) ...[
          const SizedBox(height: 12),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Chip2(
                      _result!.error.isEmpty ? '成功' : '失败',
                      color: _result!.error.isEmpty ? AppColors.accent : AppColors.danger,
                    ),
                    const SizedBox(width: 7),
                    if (_result!.status.isNotEmpty)
                      Chip2(_result!.status, color: AppColors.textDim),
                    const Spacer(),
                    Text(
                      '${_result!.elapsedMs} ms',
                      style: const TextStyle(color: AppColors.textFaint, fontSize: 10.5),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_result!.error.isNotEmpty)
                  Text(
                    _result!.error,
                    style: const TextStyle(color: AppColors.danger, fontSize: 12, height: 1.5),
                  )
                else if (_result!.records.isEmpty)
                  const Text(
                    '该记录类型无返回结果',
                    style: TextStyle(color: AppColors.textDim, fontSize: 12),
                  )
                else
                  ..._result!.records.map((r) => Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Chip2(r.type, color: AppColors.purple),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SelectableText(
                                r.data,
                                style: const TextStyle(color: AppColors.text, fontSize: 12),
                              ),
                            ),
                            Text(
                              'TTL ${r.ttl}',
                              style: const TextStyle(color: AppColors.textFaint, fontSize: 9.5),
                            ),
                          ],
                        ),
                      )),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'DNS 查询走 DoH（DNS over HTTPS），依次尝试阿里 / Cloudflare / DNSPod，'
          '全部走加密通道，不受运营商 DNS 劫持影响。',
          style: TextStyle(color: AppColors.textFaint, fontSize: 10.5, height: 1.55),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- 公共组件

Widget _inputRow({
  required TextEditingController controller,
  required String hint,
  required bool running,
  required VoidCallback onRun,
  required VoidCallback onStop,
  String runLabel = '开始 Ping',
}) {
  return Row(
    children: [
      Expanded(
        child: TextField(
          controller: controller,
          style: const TextStyle(color: AppColors.text, fontSize: 13.5),
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => running ? null : onRun(),
          decoration: InputDecoration(hintText: hint),
        ),
      ),
      const SizedBox(width: 9),
      SizedBox(
        height: 44,
        child: FilledButton(
          onPressed: running ? onStop : onRun,
          style: FilledButton.styleFrom(
            backgroundColor: running ? AppColors.danger : AppColors.accent,
            foregroundColor: running ? Colors.white : const Color(0xFF04170F),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(
            running ? '停止' : runLabel,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
          ),
        ),
      ),
    ],
  );
}

Widget _stat(String label, String value, {Color color = AppColors.text}) {
  return Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: AppColors.textFaint, fontSize: 10)),
      ],
    ),
  );
}

Widget _logPanel(List<String> lines, {required String empty}) {
  return Container(
    constraints: const BoxConstraints(minHeight: 180),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF070A0F),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.border),
    ),
    child: lines.isEmpty
        ? Text(empty, style: const TextStyle(color: AppColors.textFaint, fontSize: 12))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines
                .map((l) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        l,
                        style: TextStyle(
                          color: l.startsWith('——')
                              ? AppColors.accent
                              : l.startsWith('×')
                                  ? AppColors.danger
                                  : AppColors.textDim,
                          fontSize: 11.5,
                          height: 1.45,
                          fontFamily: 'monospace',
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ))
                .toList(),
          ),
  );
}
