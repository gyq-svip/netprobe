package com.gyq.netprobe

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/**
 * 用 AudioTrack 实时合成提示音。
 *
 * 不打包音频资源：音高与音量都由信号强度驱动，
 * 信号强 -> 音调高、音量大；信号弱 -> 音调低、音量小。
 * 采用脉冲式发声（每 0.8s 响 0.25s），避免连续蜂鸣扰人。
 */
class ToneEngine {

    @Volatile private var running = false
    @Volatile private var targetVol = 0.0f
    @Volatile private var liveVol = 0.0f
    @Volatile private var freq = 440.0

    private var thread: Thread? = null

    fun setVolume(v: Float) {
        targetVol = v.coerceIn(0f, 1f)
    }

    fun setFreq(f: Double) {
        freq = f.coerceIn(120.0, 2400.0)
    }

    fun start() {
        if (running) return
        running = true
        liveVol = 0f
        thread = Thread({ renderLoop() }, "netprobe-tone").also { it.start() }
    }

    fun stop() {
        running = false
        try {
            thread?.join(400)
        } catch (t: InterruptedException) {
        }
        thread = null
    }

    private fun renderLoop() {
        val rate = 44100
        val minBuf = AudioTrack.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = maxOf(minBuf, 4096)

        val track = try {
            AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
                bufSize,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE
            )
        } catch (t: Throwable) {
            return
        }

        try {
            track.play()
            val buf = ShortArray(1024)
            var phase = 0.0
            var idx = 0L
            val periodSamples = (rate * 0.8).toLong()
            val beepSamples = (rate * 0.25).toLong()

            while (running) {
                // 音量平滑逼近，避免突变产生爆音
                liveVol += (targetVol - liveVol) * 0.08f
                val f = freq
                val phaseInc = 2.0 * PI * f / rate

                for (i in buf.indices) {
                    val pos = idx % periodSamples
                    val gate = if (pos < beepSamples) envelope(pos, beepSamples, rate) else 0.0
                    // 轻微的谐波让声音更"实"一点
                    val wave = sin(phase) * 0.8 + sin(phase * 2) * 0.2
                    buf[i] = (wave * gate * liveVol * 32000).toInt().toShort()
                    phase += phaseInc
                    if (phase > 2 * PI) phase -= 2 * PI
                    idx++
                }
                track.write(buf, 0, buf.size)
            }
        } catch (t: Throwable) {
            // 忽略播放异常
        } finally {
            try {
                track.stop()
            } catch (t: Throwable) {
            }
            try {
                track.release()
            } catch (t: Throwable) {
            }
        }
    }

    /** 5ms 上升 + 30ms 下降包络 */
    private fun envelope(pos: Long, total: Long, rate: Int): Double {
        val attack = rate * 0.005
        val release = rate * 0.03
        val fromEnd = (total - pos).toDouble()
        return min(1.0, min(pos / attack, fromEnd / release)).coerceIn(0.0, 1.0)
    }
}
