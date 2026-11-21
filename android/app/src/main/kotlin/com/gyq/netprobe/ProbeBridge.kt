package com.gyq.netprobe

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

/**
 * ping / traceroute / ARP 表 / 提示音。
 *
 * ping 与 traceroute 走系统 ping 二进制（Android 上无需 root），
 * 输出逐行推送，Dart 侧负责解析 RTT 与格式化。
 */
class ProbeBridge(private val activity: MainActivity) {

    private val handler = Handler(Looper.getMainLooper())
    private var pingSink: EventChannel.EventSink? = null
    private var traceSink: EventChannel.EventSink? = null

    @Volatile private var pingProc: Process? = null
    @Volatile private var pingRunning = false
    @Volatile private var traceRunning = false

    private val tone = ToneEngine()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CH_PROBE).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ping" -> startPing(call, result)
                    "stopPing" -> {
                        stopPing()
                        result.success(true)
                    }
                    "trace" -> startTrace(call, result)
                    "stopTrace" -> {
                        traceRunning = false
                        result.success(true)
                    }
                    "arpTable" -> result.success(arpTable())
                    "toneStart" -> {
                        tone.setVolume((call.argument<Double>("volume") ?: 0.3).toFloat())
                        tone.setFreq((call.argument<Double>("freq") ?: 440.0))
                        tone.start()
                        result.success(true)
                    }
                    "toneUpdate" -> {
                        call.argument<Double>("volume")?.let { tone.setVolume(it.toFloat()) }
                        call.argument<Double>("freq")?.let { tone.setFreq(it) }
                        result.success(true)
                    }
                    "toneStop" -> {
                        tone.stop()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("probe_error", t.message ?: t.toString(), null)
            }
        }

        EventChannel(messenger, CH_PING).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                pingSink = events
            }

            override fun onCancel(arguments: Any?) {
                pingSink = null
            }
        })

        EventChannel(messenger, CH_TRACE).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                traceSink = events
            }

            override fun onCancel(arguments: Any?) {
                traceSink = null
            }
        })
    }

    // ---------------------------------------------------------------- ping

    private fun startPing(call: MethodCall, result: MethodChannel.Result) {
        val host = call.argument<String>("host") ?: return result.error("bad_args", "host 为空", null)
        val count = (call.argument<Int>("count") ?: 4).coerceIn(1, 50)
        val interval = (call.argument<Double>("interval") ?: 0.5).coerceIn(0.3, 5.0)

        stopPing()
        pingRunning = true
        result.success(true)

        Thread {
            var received = 0
            var sent = 0
            try {
                val cmd = listOf(
                    "/system/bin/ping", "-c", "$count",
                    "-i", "%.1f".format(interval),
                    "-W", "2", host
                )
                val pb = ProcessBuilder(cmd).redirectErrorStream(true)
                val p = pb.start()
                pingProc = p
                val reader = BufferedReader(InputStreamReader(p.inputStream))
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    if (!pingRunning) break
                    val text = line!!
                    val rtt = RTT_RE.find(text)?.groupValues?.get(1)?.toDoubleOrNull()
                    val ttl = TTL_RE.find(text)?.groupValues?.get(1)?.toIntOrNull()
                    if (rtt != null) {
                        received++
                        sent++
                        emitPing(mapOf("type" to "reply", "rtt" to rtt, "ttl" to ttl, "text" to text))
                    } else {
                        if (text.contains("icmp_seq")) sent++
                        emitPing(mapOf("type" to "line", "text" to text))
                    }
                }
                p.waitFor()
            } catch (t: Throwable) {
                emitPing(mapOf("type" to "error", "text" to (t.message ?: "ping 执行失败")))
            } finally {
                pingProc = null
                emitPing(
                    mapOf(
                        "type" to "done",
                        "sent" to maxOf(sent, received),
                        "received" to received,
                        "loss" to if (maxOf(sent, received) == 0) 100 else (100 - received * 100 / maxOf(sent, received))
                    )
                )
            }
        }.start()
    }

    private fun stopPing() {
        pingRunning = false
        try {
            pingProc?.destroy()
        } catch (t: Throwable) {
        }
        pingProc = null
    }

    private fun emitPing(data: Map<String, Any?>) {
        handler.post { pingSink?.success(data) }
    }

    // ----------------------------------------------------------- traceroute

    private fun startTrace(call: MethodCall, result: MethodChannel.Result) {
        val host = call.argument<String>("host") ?: return result.error("bad_args", "host 为空", null)
        val maxHops = (call.argument<Int>("maxHops") ?: 20).coerceIn(1, 32)

        if (traceRunning) return result.success(false)
        traceRunning = true
        result.success(true)

        Thread {
            try {
                for (ttl in 1..maxHops) {
                    if (!traceRunning) break
                    emitTrace(mapOf("type" to "hop", "hop" to ttl, "pending" to true))

                    val out = runSingleHop(host, ttl)
                    val hopIp = HOP_IP_RE.find(out)?.groupValues?.get(1)
                    val rtt = RTT_RE.find(out)?.groupValues?.get(1)?.toDoubleOrNull()
                    val reached = out.contains("bytes from") && rtt != null

                    emitTrace(
                        mapOf(
                            "type" to "hop",
                            "hop" to ttl,
                            "ip" to (hopIp ?: ""),
                            "rtt" to (rtt ?: -1.0),
                            "final" to reached,
                            "pending" to false,
                            "timeout" to (hopIp == null && rtt == null)
                        )
                    )
                    if (reached) break
                }
            } catch (t: Throwable) {
                emitTrace(mapOf("type" to "error", "text" to (t.message ?: "traceroute 失败")))
            } finally {
                traceRunning = false
                emitTrace(mapOf("type" to "done"))
            }
        }.start()
    }

    private fun runSingleHop(host: String, ttl: Int): String {
        return try {
            val p = ProcessBuilder(
                "/system/bin/ping", "-c", "1", "-t", "$ttl", "-W", "2", host
            ).redirectErrorStream(true).start()
            val text = p.inputStream.bufferedReader().use { it.readText() }
            p.waitFor()
            text
        } catch (t: Throwable) {
            ""
        }
    }

    private fun emitTrace(data: Map<String, Any?>) {
        handler.post { traceSink?.success(data) }
    }

    // -------------------------------------------------------------- ARP 表

    private fun arpTable(): Map<String, String> {
        val out = mutableMapOf<String, String>()
        try {
            val f = File("/proc/net/arp")
            if (!f.canRead()) return out
            f.readLines().drop(1).forEach { line ->
                val parts = line.trim().split(Regex("\\s+"))
                if (parts.size >= 4) {
                    val ip = parts[0]
                    val mac = parts[3]
                    if (mac != "00:00:00:00:00:00" && mac.matches(Regex("[0-9a-fA-F:]{17}"))) {
                        out[ip] = mac.uppercase()
                    }
                }
            }
        } catch (t: Throwable) {
        }
        return out
    }

    fun dispose() {
        stopPing()
        traceRunning = false
        tone.stop()
    }

    companion object {
        const val CH_PROBE = "com.gyq.netprobe/probe"
        const val CH_PING = "com.gyq.netprobe/ping"
        const val CH_TRACE = "com.gyq.netprobe/trace"

        private val RTT_RE = Regex("time[=<]\\s*([0-9.]+)\\s*ms")
        private val TTL_RE = Regex("ttl[=:]\\s*(\\d+)", RegexOption.IGNORE_CASE)
        private val HOP_IP_RE = Regex("From\\s+([0-9.]+)")
    }
}
