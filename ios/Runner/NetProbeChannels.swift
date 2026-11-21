import Flutter
import Foundation

/// 所有原生通道的注册入口，通道名与 Android 侧严格一致。
enum NetProbeChannels {
    static let wifi = "com.gyq.netprobe/wifi"
    static let wifiRssi = "com.gyq.netprobe/wifi_rssi"
    static let probe = "com.gyq.netprobe/probe"
    static let ping = "com.gyq.netprobe/ping"
    static let trace = "com.gyq.netprobe/trace"

    private static var wifiBridge: NetProbeWifi?
    private static var toolsBridge: NetProbeTools?

    static func register(with messenger: FlutterBinaryMessenger) {
        let wifi = NetProbeWifi()
        let tools = NetProbeTools()
        wifiBridge = wifi
        toolsBridge = tools

        let wifiChannel = FlutterMethodChannel(name: self.wifi, binaryMessenger: messenger)
        wifiChannel.setMethodCallHandler { call, result in
            wifi.handle(call, result: result)
        }

        let wifiRssiChannel = FlutterEventChannel(name: wifiRssi, binaryMessenger: messenger)
        wifiRssiChannel.setStreamHandler(wifi.rssiStreamHandler)

        let probeChannel = FlutterMethodChannel(name: probe, binaryMessenger: messenger)
        probeChannel.setMethodCallHandler { call, result in
            tools.handle(call, result: result)
        }

        let pingChannel = FlutterEventChannel(name: ping, binaryMessenger: messenger)
        pingChannel.setStreamHandler(tools.pingStreamHandler)

        let traceChannel = FlutterEventChannel(name: trace, binaryMessenger: messenger)
        traceChannel.setStreamHandler(tools.traceStreamHandler)
    }
}
