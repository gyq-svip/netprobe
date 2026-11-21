# 网络工具箱 NetProbe

Flutter 一套代码出 Android + iOS 双端，一体化 WiFi 分析仪与网络工具集。

## 功能一览

| 模块 | 内容 |
|---|---|
| WiFi 分析 | 当前连接详情、附近 AP 列表、2.4G/5G 信道占用图、实时质量曲线、信号提示音 |
| 网络工具 | ICMP Ping、Traceroute、DNS 查询（DoH，支持 A/AAAA/CNAME/MX/TXT/NS/SOA/PTR） |
| 局域网 | 网段扫描、设备发现、主机名/MAC/网页标题/厂商线索、单机端口扫描 |
| 风险研判 | 高危端口识别、弱加密 WiFi 告警、开放端口风险提示（不含漏洞利用） |

## 平台能力差异（重要）

| 能力 | Android | iOS |
|---|---|---|
| 附近 WiFi 列表 | 支持（需定位权限） | **不支持**，系统未开放 |
| 真实 RSSI (dBm) | 支持 | **不支持**，`signalStrength` 返回占位值 |
| 实时信号曲线 | RSSI 驱动 | 网关 ICMP 时延代理 |
| Ping / Traceroute | 系统 ping | 原生 ICMP socket |
| DNS / 端口扫描 / 网段扫描 | 支持 | 支持 |
| 信号提示音 | 支持 | 支持（用质量分驱动） |
| 读取 MAC | 部分机型 | 不支持 |

iOS 端限制来自 Apple 官方技术说明 [TN3111](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)：
iOS 没有通用的 WiFi 扫描 API，且 `NEHotspotNetwork.signalStrength` 对普通 App 返回占位值。
该限制与签名方式无关——付费开发者证书、自签、Apple Developer Enterprise 都无法绕过，
因为相关 entitlement（`HotspotHelper`、`com.apple.private.*`）只能由 Apple 签发。

想在 iOS 上真正扫描邻居网络，只有三条路：
1. ESP32 等硬件做蓝牙探针，扫描结果推给 App（推荐，成本最低）
2. TrollStore 注入任意 entitlement（仅 ≤ iOS 17.0）
3. 越狱（palera1n，仅 A11 及以下且 ≤ iOS 18.x）

## 本地编译

```bash
export JAVA_HOME="D:/Android/jdk_extract/jdk-17.0.21+9"
export ANDROID_SDK_ROOT="D:/Android"
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

iOS 需要 macOS + Xcode：

```bash
flutter build ios --release --no-codesign
```

## GitHub Actions 出包

推送到 GitHub 后，在 Actions 页面手动触发 `Build App (APK + IPA)`。
在 macOS runner 上编译 APK 与无签名 IPA，产物推到 `releases` 分支：

- `netprobe-android-v{版本}.apk`
- `netprobe-ios-v{版本}.ipa`（用爱思助手 / AltStore 自签安装）

## 权限说明

**Android**
- `ACCESS_FINE_LOCATION` —— 扫描 WiFi 的硬性要求（系统认为扫描结果可用于定位）
- `NEARBY_WIFI_DEVICES` —— Android 13+
- `ACCESS_WIFI_STATE` / `CHANGE_WIFI_STATE` —— 读取与触发扫描
- `ACCESS_LOCAL_NETWORK` —— Android 16 起的局域网保护

**iOS**
- `NSLocationWhenInUseUsageDescription` —— 读取 SSID 的前置条件
- `NSLocalNetworkUsageDescription` —— 访问局域网设备

## 使用提醒

扫描与端口探测仅可用于自己拥有或已获授权的网络。风险提示基于开放服务与常见弱配置的启发式判断，
不等同于确认存在可被利用的漏洞，本工具不含任何漏洞利用代码。
