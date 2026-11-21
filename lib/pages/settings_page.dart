import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  WifiCapability _cap = const WifiCapability();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cap = await NativeWifi.capabilities();
    if (!mounted) return;
    setState(() => _cap = cap);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置与说明')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
        children: [
          const SectionTitle('平台能力'),
          Panel(
            child: Column(
              children: [
                _capRow('运行平台', _cap.isIOS ? 'iOS' : 'Android'),
                _capRow('扫描附近 WiFi', _cap.canScan ? '支持' : '不支持',
                    ok: _cap.canScan),
                _capRow('真实信号强度 (dBm)', _cap.realRssi ? '支持' : '不支持（用延迟代理）',
                    ok: _cap.realRssi),
                _capRow('定位权限', _cap.locationPermission ? '已授权' : '未授权',
                    ok: _cap.locationPermission),
                if (!_cap.isIOS)
                  _capRow('系统定位服务', _cap.locationEnabled ? '已开启' : '已关闭',
                      ok: _cap.locationEnabled),
                _capRow('读取 ARP 表(MAC)', _cap.canReadArp ? '支持' : '不支持',
                    ok: _cap.canReadArp),
              ],
            ),
          ),
          if (_cap.scanNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _cap.scanNote,
              style: const TextStyle(color: AppColors.textFaint, fontSize: 11, height: 1.5),
            ),
          ],
          const SectionTitle('使用须知'),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bullet('Android', '扫描附近 WiFi 需要「定位」权限且系统定位服务必须开启，这是 Android 的硬性要求（扫描结果可用于推算位置）。'),
                _bullet('Android', '系统限制前台每 2 分钟最多 4 次扫描。若提示被限流，属于正常现象，可关闭开发者选项里的「WiFi 扫描节流」缓解。'),
                _bullet('iOS', 'Apple 未开放第三方扫描附近 WiFi 的接口（官方技术说明 TN3111），因此本页无法列出邻居网络，也拿不到真实 dBm。'),
                _bullet('iOS', '为了提供可用的信号曲线，iOS 端改用「网关 ICMP 往返时延」换算成质量分，时延低则分数高、提示音更响。'),
                _bullet('通用', '局域网与端口扫描仅对您拥有或已获授权的网络使用。扫描为并发 TCP 探测，不发洪泛包。'),
              ],
            ),
          ),
          const SectionTitle('信号提示音'),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '在 WiFi 页右上角开启后，会按信号强弱实时改变提示音：',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 8),
                _bullet('强', '音调高（最高约 1200Hz）、音量大'),
                _bullet('弱', '音调低（最低约 280Hz）、音量小'),
                _bullet('场景', '拿着手机在屋里走动找最佳位置，不用一直看屏幕，靠听就能判断信号变好还是变差'),
                const SizedBox(height: 6),
                const Text(
                  '提示音为脉冲式（每 0.8 秒响一次），不会持续蜂鸣。切到后台会自动静音。',
                  style: TextStyle(color: AppColors.textFaint, fontSize: 10.5, height: 1.5),
                ),
              ],
            ),
          ),
          const SectionTitle('免责声明'),
          Panel(
            borderColor: AppColors.warn.withOpacity(0.35),
            color: AppColors.warn.withOpacity(0.06),
            child: const Text(
              '本工具面向网络排障与自查，仅可用于您本人拥有、或已获得明确书面授权的网络与设备。\n\n'
              '「风险提示」基于开放端口、服务类型与常见弱配置特征给出判断，属于启发式推断，'
              '不代表目标设备确实存在可被利用的漏洞；本工具不包含任何漏洞利用代码。\n\n'
              '未经授权对他人网络或设备进行扫描、探测，在多数国家和地区可能构成违法行为，'
              '请自行确认合规性，使用后果由使用者承担。',
              style: TextStyle(color: AppColors.warn, fontSize: 11.5, height: 1.7),
            ),
          ),
          const SectionTitle('关于'),
          Panel(
            child: Column(
              children: [
                _capRow('应用名称', '网络工具箱 NetProbe'),
                _capRow('版本', '1.1.0'),
                _capRow('技术栈', 'Flutter + 原生通道'),
                _capRow('网络工具', 'ICMP Ping / Traceroute / DoH DNS'),
                _capRow('扫描能力', '网段发现 / 端口探测 / 风险研判'),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Center(
            child: Text(
              '局域网内的数据全部在本机处理，不上传任何服务器',
              style: TextStyle(color: AppColors.textFaint, fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _capRow(String k, String v, {bool? ok}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(k, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          ),
          Text(
            v,
            style: TextStyle(
              color: ok == null ? AppColors.textFaint : (ok ? AppColors.accent : AppColors.warn),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bullet(String tag, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Chip2(tag, color: AppColors.blue),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.55),
            ),
          ),
        ],
      ),
    );
  }
}
