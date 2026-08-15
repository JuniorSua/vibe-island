import AVFoundation
import Foundation

/// 8-bit style synthesized event sounds: short square-wave note sequences
/// rendered into a PCM buffer and played through AVAudioEngine.
final class SoundEngine {
    static let shared = SoundEngine()

    enum Event {
        case done            // rising arpeggio
        case needsAttention  // two-tone alert
        case question        // three quick notes
        case resolved        // short blip

        var notes: [(hz: Double, secs: Double)] {
            switch self {
            case .done:
                return [(523.25, 0.09), (659.25, 0.09), (783.99, 0.16)]          // C5 E5 G5
            case .needsAttention:
                return [(830.61, 0.12), (0, 0.04), (622.25, 0.16)]               // G#5 · D#5
            case .question:
                return [(587.33, 0.08), (739.99, 0.08), (880.00, 0.14)]          // D5 F#5 A5
            case .resolved:
                return [(1046.50, 0.07)]                                         // C6
            }
        }
    }

    var enabled = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var started = false

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.35
    }

    func play(_ event: Event) {
        guard enabled, !isQuietScene() else { return }
        if !started {
            do {
                try engine.start()
                started = true
            } catch {
                NSLog("VibeIsland: audio engine failed: \(error)")
                return
            }
        }
        guard let buffer = render(event.notes) else { return }
        player.scheduleBuffer(buffer, at: nil)
        if !player.isPlaying { player.play() }
    }

    /// Quiet scenes: mute while the screen is locked or being captured.
    private func isQuietScene() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let locked = dict["CGSSessionScreenIsLocked"] as? Int, locked == 1 {
            return true
        }
        return false
    }

    private func render(_ notes: [(hz: Double, secs: Double)]) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let totalFrames = notes.reduce(0) { $0 + AVAudioFrameCount($1.secs * sampleRate) }
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let samples = buffer.floatChannelData?[0]
        else { return nil }

        var frame = 0
        for note in notes {
            let frames = Int(note.secs * sampleRate)
            for i in 0..<frames {
                let t = Double(i) / sampleRate
                var value: Float = 0
                if note.hz > 0 {
                    // Square wave for the 8-bit character, with a fast decay envelope.
                    let phase = (t * note.hz).truncatingRemainder(dividingBy: 1.0)
                    let envelope = min(1.0, Double(frames - i) / (sampleRate * 0.03))
                    let attack = min(1.0, Double(i) / (sampleRate * 0.004))
                    value = Float((phase < 0.5 ? 0.5 : -0.5) * envelope * attack)
                }
                samples[frame + i] = value
            }
            frame += frames
        }
        buffer.frameLength = AVAudioFrameCount(frame)
        return buffer
    }
}
