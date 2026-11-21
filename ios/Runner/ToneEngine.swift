import AVFoundation
import Foundation

/// iOS 侧提示音：AVAudioSourceNode 实时合成正弦脉冲。
///
/// 信号强 -> 频率高、音量大；信号弱 -> 频率低、音量小。
final class ToneEngine {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var running = false
    private let sampleRate: Double = 44100

    // 由音频线程读取，保持简单基本类型即可
    private var volumeTarget: Double = 0
    private var volumeLive: Double = 0
    private var frequency: Double = 440
    private var phase: Double = 0
    private var sampleIndex: Int64 = 0

    func setVolume(_ v: Double) {
        volumeTarget = max(0, min(1, v))
    }

    func setFrequency(_ f: Double) {
        frequency = max(120, min(2400, f))
    }

    func start() {
        guard !running else { return }
        guard #available(iOS 13.0, *) else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 音频会话失败不阻断主流程
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return
        }

        let sr = sampleRate
        let node = AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            let periodSamples = Int(sr * 0.8)
            let beepSamples = Int(sr * 0.25)
            let attackSamples = max(1, Int(sr * 0.005))
            let releaseSamples = max(1, Int(sr * 0.03))

            for frame in 0..<frames {
                // 音量平滑，避免突变爆音
                self.volumeLive += (self.volumeTarget - self.volumeLive) * 0.0006

                let pos = Int(self.sampleIndex % Int64(periodSamples))
                var gate: Double = 0
                if pos < beepSamples {
                    let up = Double(pos) / Double(attackSamples)
                    let down = Double(beepSamples - pos) / Double(releaseSamples)
                    gate = max(0, min(1, min(up, down)))
                }

                let wave = sin(self.phase) * 0.8 + sin(self.phase * 2) * 0.2
                let sample = Float(wave * gate * self.volumeLive * 0.9)

                for buffer in ablPointer {
                    if let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) {
                        ptr[frame] = sample
                    }
                }

                self.phase += 2 * Double.pi * self.frequency / sr
                if self.phase > 2 * Double.pi { self.phase -= 2 * Double.pi }
                self.sampleIndex += 1
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            running = true
            sourceNode = node
        } catch {
            engine.detach(node)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        volumeTarget = 0
        volumeLive = 0
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
