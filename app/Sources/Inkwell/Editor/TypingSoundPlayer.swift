import AVFoundation
import AppKit

/// Synthesized key sounds. Each "machine" is a small set of procedurally
/// generated clicks so no audio assets are needed.
final class TypingSoundPlayer {
    static let shared = TypingSoundPlayer()

    private enum Key: Hashable { case normal(Int), space, enter, backspace }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [Key: AVAudioPCMBuffer] = [:]
    private var bufferSound: TypingSound?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var started = false

    private init() {}

    func play(for event: NSEvent) {
        let sound = AppSettings.shared.typingSound
        guard sound != .off, !event.isARepeat else { return }
        let key: Key
        switch event.keyCode {
        case 49: key = .space
        case 36, 76: key = .enter
        case 51, 117: key = .backspace
        default: key = .normal(Int(event.keyCode) % 5)
        }
        play(key, sound: sound)
    }

    /// Plays a sample (used by the settings preview).
    func preview(_ sound: TypingSound) {
        guard sound != .off else { return }
        play(.normal(Int.random(in: 0..<5)), sound: sound)
    }

    private func play(_ key: Key, sound: TypingSound) {
        if bufferSound != sound {
            buffers = [:]
            bufferSound = sound
        }
        if !started { start() }
        guard started else { return }
        let buffer = buffers[key] ?? makeBuffer(key, sound: sound)
        buffers[key] = buffer
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = Float(AppSettings.shared.typingVolume)
        player.stop()
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    private func start() {
        for _ in 0..<6 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        do {
            try engine.start()
            started = true
        } catch {
            started = false
        }
    }

    /// Builds a click: a filtered noise burst plus a short resonant body.
    private func makeBuffer(_ key: Key, sound: TypingSound) -> AVAudioPCMBuffer {
        struct Voice { var noise: Double; var tone: Double; var decay: Double; var noiseDecay: Double; var length: Double; var cutoff: Double }
        var v: Voice
        switch sound {
        case .normal: v = Voice(noise: 0.55, tone: 1900, decay: 55, noiseDecay: 90, length: 0.05, cutoff: 0.35)
        case .soft: v = Voice(noise: 0.35, tone: 900, decay: 60, noiseDecay: 120, length: 0.045, cutoff: 0.15)
        case .creamy: v = Voice(noise: 0.3, tone: 520, decay: 38, noiseDecay: 70, length: 0.07, cutoff: 0.12)
        case .retro: v = Voice(noise: 0.7, tone: 2600, decay: 40, noiseDecay: 60, length: 0.06, cutoff: 0.55)
        case .typewriter: v = Voice(noise: 0.8, tone: 1400, decay: 30, noiseDecay: 45, length: 0.09, cutoff: 0.6)
        case .off: v = Voice(noise: 0, tone: 0, decay: 1, noiseDecay: 1, length: 0.01, cutoff: 0)
        }
        switch key {
        case .space: v.tone *= 0.6; v.length *= 1.4; v.decay *= 0.7
        case .enter: v.tone *= 0.75; v.length *= 1.6; v.noise *= 1.2
        case .backspace: v.tone *= 0.85; v.length *= 1.2
        case let .normal(i): v.tone *= 1 + Double(i - 2) * 0.04
        }
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(v.length * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        var lowpass = 0.0
        var rng = SystemRandomNumberGenerator()
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let white = Double.random(in: -1...1, using: &rng)
            lowpass += v.cutoff * (white - lowpass)
            let noise = lowpass * v.noise * exp(-t * v.noiseDecay)
            let body = sin(2 * .pi * v.tone * t) * 0.35 * exp(-t * v.decay)
            var sample = noise + body
            if sound == .typewriter, case .enter = key {
                // A little bell at the end of the line.
                sample += sin(2 * .pi * 2100 * t) * 0.25 * exp(-t * 12)
            }
            out[i] = Float(sample * 0.8)
        }
        return buffer
    }
}
