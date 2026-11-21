package com.gyq.netprobe

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Android 侧的 WiFi 能力：当前连接信息、附近 AP 扫描、实时 RSSI 推送。
 *
 * 说明：startScan 受系统节流（前台 2 分钟 4 次），被拒时返回上一轮缓存结果，
 * 由 Dart 侧根据 timestamp 判断新鲜度。
 */
class WifiBridge(private val activity: MainActivity) {

    private val ctx: Context get() = activity.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var rssiSink: EventChannel.EventSink? = null
    private var polling = false

    private val wifi: WifiManager?
        get() = ctx.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CH_WIFI).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "capabilities" -> result.success(capabilities())
                    "current" -> result.success(current())
                    "scan" -> result.success(scan())
                    "requestPermissions" -> requestPerms(result)
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("wifi_error", t.message ?: t.toString(), null)
            }
        }

        EventChannel(messenger, CH_RSSI).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                rssiSink = events
                startPolling()
            }

            override fun onCancel(arguments: Any?) {
                stopPolling()
            }
        })
    }

    // ---------------------------------------------------------------- 能力

    private fun capabilities(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "sdkInt" to Build.VERSION.SDK_INT,
        "hasWifi" to (wifi != null),
        "locationPermission" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
        "nearbyPermission" to (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.NEARBY_WIFI_DEVICES)),
        "locationEnabled" to locationEnabled(),
        "canScan" to (wifi != null && granted(Manifest.permission.ACCESS_FINE_LOCATION) && locationEnabled()),
        "realRssi" to true,
        "canReadArp" to true
    )

    private fun granted(perm: String): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) true
        else ctx.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

    private fun locationEnabled(): Boolean = try {
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) lm.isLocationEnabled
        else lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    } catch (t: Throwable) {
        false
    }

    private fun requestPerms(result: MethodChannel.Result) {
        val perms = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        val missing = perms.filter { !granted(it) }
        if (missing.isEmpty()) {
            result.success(perms.associateWith { true })
        } else {
            activity.requestAppPermissions(missing.toTypedArray(), result)
        }
    }

    // ------------------------------------------------------------ 当前连接

    private fun current(): Map<String, Any?> {
        val m = wifi ?: return mapOf("connected" to false, "reason" to "无 WiFi 硬件")
        val info = try {
            @Suppress("DEPRECATION")
            m.connectionInfo
        } catch (t: Throwable) {
            null
        }

        val rawSsid = info?.ssid ?: ""
        val ssid = rawSsid.trim('"')
        val hasSsid = ssid.isNotEmpty() && ssid != "<unknown ssid>"

        val link = readLink()
        val ip = (link["ip"] as? String) ?: ""
        // 没有定位权限时系统不返回 SSID，但只要拿到了 IP 就说明已经连上网络
        val connected = (info != null && info.networkId != -1) || ip.isNotEmpty()
        val freq = info?.frequency ?: 0

        return mapOf(
            "connected" to connected,
            "ssid" to if (hasSsid) ssid else "",
            "bssid" to (info?.bssid ?: ""),
            "rssi" to (info?.rssi ?: 0),
            "linkSpeed" to (info?.linkSpeed ?: 0),
            "frequency" to freq,
            "channel" to freqToChannel(freq),
            "band" to bandOf(freq),
            "ip" to ip,
            "prefix" to link["prefix"],
            "gateway" to link["gateway"],
            "dns" to link["dns"],
            "mac" to wlanMac(),
            "wifiStandard" to (if (Build.VERSION.SDK_INT >= 30) info?.wifiStandard ?: 0 else 0),
            "rxLinkSpeed" to (if (Build.VERSION.SDK_INT >= 29) info?.rxLinkSpeedMbps ?: 0 else 0),
            "txLinkSpeed" to (if (Build.VERSION.SDK_INT >= 29) info?.txLinkSpeedMbps ?: 0 else 0)
        )
    }

    private fun readLink(): Map<String, Any?> {
        var ip = ""
        var prefix = 24
        var gateway = ""
        var dns = emptyList<String>()
        try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val net = cm.activeNetwork
            val caps = net?.let { cm.getNetworkCapabilities(it) }
            if (net != null && caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                val lp = cm.getLinkProperties(net)
                lp?.linkAddresses?.forEach { la ->
                    val a = la.address
                    if (a is Inet4Address && !a.isLoopbackAddress) {
                        ip = a.hostAddress ?: ""
                        prefix = la.prefixLength
                    }
                }
                lp?.routes?.forEach { r ->
                    if (r.isDefaultRoute && r.gateway is Inet4Address) {
                        gateway = r.gateway?.hostAddress ?: ""
                    }
                }
                dns = lp?.dnsServers?.mapNotNull { it.hostAddress } ?: emptyList()
            }
        } catch (t: Throwable) {
            // 退化到 dhcpInfo
        }
        if (ip.isEmpty()) {
            try {
                @Suppress("DEPRECATION")
                val dhcp = wifi?.dhcpInfo
                if (dhcp != null) {
                    ip = intToIp(dhcp.ipAddress)
                    gateway = intToIp(dhcp.gateway)
                    val mask = dhcp.netmask
                    if (mask != 0) prefix = Integer.bitCount(mask)
                    val d1 = intToIp(dhcp.dns1)
                    val d2 = intToIp(dhcp.dns2)
                    dns = listOfNotNull(
                        d1.takeIf { it != "0.0.0.0" },
                        d2.takeIf { it != "0.0.0.0" }
                    )
                }
            } catch (t: Throwable) {
                // 忽略
            }
        }
        return mapOf("ip" to ip, "prefix" to prefix, "gateway" to gateway, "dns" to dns)
    }

    private fun intToIp(v: Int): String = "${v and 0xFF}.${(v shr 8) and 0xFF}.${(v shr 16) and 0xFF}.${(v shr 24) and 0xFF}"

    private fun wlanMac(): String {
        return try {
            val ni = NetworkInterface.getByName("wlan0") ?: return ""
            ni.hardwareAddress?.joinToString(":") { "%02X".format(it) } ?: ""
        } catch (t: Throwable) {
            ""
        }
    }

    // ---------------------------------------------------------------- 扫描

    private fun scan(): Map<String, Any?> {
        val m = wifi
        if (m == null) return mapOf("ok" to false, "reason" to "无 WiFi 硬件", "list" to emptyList<Any>())
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
            return mapOf("ok" to false, "reason" to "缺少定位权限", "list" to emptyList<Any>())
        }
        if (!locationEnabled()) {
            return mapOf("ok" to false, "reason" to "系统定位服务未开启", "list" to emptyList<Any>())
        }

        val accepted = try {
            @Suppress("DEPRECATION")
            m.startScan()
        } catch (t: Throwable) {
            false
        }

        val results: List<ScanResult> = try {
            @Suppress("DEPRECATION")
            m.scanResults ?: emptyList()
        } catch (t: Throwable) {
            emptyList()
        }

        val nowUs = android.os.SystemClock.elapsedRealtime() * 1000L
        val list = results.map { r ->
            val freq = r.frequency
            mapOf(
                "ssid" to (r.SSID ?: ""),
                "bssid" to (r.BSSID ?: ""),
                "rssi" to r.level,
                "frequency" to freq,
                "channel" to freqToChannel(freq),
                "band" to bandOf(freq),
                "width" to widthOf(r),
                "capabilities" to (r.capabilities ?: ""),
                "ageMs" to ((nowUs - r.timestamp) / 1000L).coerceAtLeast(0L)
            )
        }
        return mapOf(
            "ok" to true,
            "accepted" to accepted,
            "throttled" to (!accepted && results.isNotEmpty()),
            "list" to list
        )
    }

    private fun widthOf(r: ScanResult): Int = try {
        if (Build.VERSION.SDK_INT >= 23) {
            when (r.channelWidth) {
                ScanResult.CHANNEL_WIDTH_20MHZ -> 20
                ScanResult.CHANNEL_WIDTH_40MHZ -> 40
                ScanResult.CHANNEL_WIDTH_80MHZ -> 80
                ScanResult.CHANNEL_WIDTH_160MHZ -> 160
                ScanResult.CHANNEL_WIDTH_80MHZ_PLUS_MHZ -> 80
                else -> 20
            }
        } else 20
    } catch (t: Throwable) {
        20
    }

    // ------------------------------------------------------------ RSSI 轮询

    private fun startPolling() {
        if (polling) return
        polling = true
        handler.post(pollRunnable)
    }

    private fun stopPolling() {
        polling = false
        handler.removeCallbacks(pollRunnable)
        rssiSink = null
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (!polling) return
            try {
                val c = current()
                rssiSink?.success(c)
            } catch (t: Throwable) {
                // 忽略单次失败
            }
            handler.postDelayed(this, 1000L)
        }
    }

    companion object {
        const val CH_WIFI = "com.gyq.netprobe/wifi"
        const val CH_RSSI = "com.gyq.netprobe/wifi_rssi"

        fun freqToChannel(freq: Int): Int = when {
            freq == 2484 -> 14
            freq in 2412..2472 -> (freq - 2407) / 5
            freq in 4910..4980 -> (freq - 4000) / 5
            freq in 5000..5895 -> (freq - 5000) / 5
            freq in 5925..7125 -> (freq - 5950) / 5
            else -> 0
        }

        fun bandOf(freq: Int): String = when {
            freq <= 0 -> ""
            freq < 3000 -> "2.4G"
            freq < 5925 -> "5G"
            else -> "6G"
        }
    }
}
