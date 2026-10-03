import AVFoundation
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Haptic and audio confirmation for snaps, merges and completion, plus the
/// optional background music.
///
/// A file in `Resources/Sounds/` named after a tone (`snap.m4a`, `merge.wav`,
/// `complete.caf`…) is played as-is; a tone without a file is synthesised at
/// launch from a handful of decaying sine partials. `music-library.*` loops
/// while a picture is being chosen and the board tune the player picked
/// (`music-piano.*` or `music.*`) while the board is on screen,
/// with a crossfade between them. If audio cannot start for any reason it
/// simply stays off — a silent game is fine, a crashing one is not.
@MainActor
final class Feedback {
    static let shared = Feedback()

    enum Tone: String, CaseIterable { case snap, merge, complete, achievement, streak }
    enum Music: String, CaseIterable { case library = "music-library", boardPiano = "music-piano", board = "music" }

    /// Music relative to the effects; the file's own level does the rest.
    static let musicVolume: Float = 0.35

    /// The old track fades out first; the new one comes in a beat later and
    /// slower, so going from the library to the table eases in rather than cuts.
    static let fadeOut: TimeInterval = 3
    static let fadeInDelay: TimeInterval = 1
    static let fadeIn: TimeInterval = 5

    /// True when a music file ships, so Settings only offers what exists.
    static let hasMusic = Music.allCases.contains { soundURL($0.rawValue) != nil }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [Tone: AVAudioPCMBuffer] = [:]
    private var filePlayers: [Tone: AVAudioPlayer] = [:]
    private var tracks: [Music: AVAudioPlayer] = [:]
    private var currentMusic: Music?
    private var audioReady = false

    private init() {}

    /// `streak` marks a snap that extends a run without misses
    /// (`GameSession.isOnStreak`); it rings instead of the plain tap.
    func report(_ outcome: SettleOutcome?, streak: Bool = false, settings: AppSettings) {
        guard let outcome, outcome.didSnap else { return }
        if outcome.didComplete {
            play(.complete, settings: settings)
            impact(.strong, settings: settings)
        } else if streak {
            play(.streak, settings: settings)
            impact(.medium, settings: settings)
        } else if outcome.didMerge {
            play(.merge, settings: settings)
            impact(.medium, settings: settings)
        } else {
            play(.snap, settings: settings)
            impact(.light, settings: settings)
        }
    }

    // MARK: - Haptics

    enum Strength { case light, medium, strong }

    func impact(_ strength: Strength, settings: AppSettings) {
        guard settings.hapticsEnabled else { return }
        #if os(macOS)
        // Trackpad haptics; a no-op on hardware without a Force Touch surface.
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch strength {
        case .light: .alignment
        case .medium: .levelChange
        case .strong: .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        #else
        let style: UIImpactFeedbackGenerator.FeedbackStyle = switch strength {
        case .light: .light
        case .medium: .medium
        case .strong: .heavy
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }

    // MARK: - Audio

    func play(_ tone: Tone, volume: Float = 1, settings: AppSettings) {
        guard settings.soundEnabled else { return }
        prepareAudioIfNeeded()
        if let file = filePlayers[tone] {
            file.volume = volume
            file.currentTime = 0
            file.play()
            return
        }
        guard let buffer = buffers[tone] else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// Crossfades to `track`, or fades everything out with `nil`. Each loop
    /// keeps its place while silent, so coming back resumes rather than restarts.
    func setMusic(_ track: Music?, settings: AppSettings) {
        let target = settings.musicEnabled ? track : nil
        guard target != currentMusic else { return }
        currentMusic = target
        prepareAudioIfNeeded()
        for (music, player) in tracks where music != target {
            player.setVolume(0, fadeDuration: Self.fadeOut)
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.fadeOut))
            for (music, player) in tracks where music != currentMusic { player.pause() }
        }
        guard let target else { return }
        if tracks[target] == nil, let url = Self.soundURL(target.rawValue),
           let loop = try? AVAudioPlayer(contentsOf: url) {
            loop.numberOfLoops = -1
            loop.volume = 0
            tracks[target] = loop
        }
        guard let player = tracks[target] else { return }
        // Nothing to fade out (first launch): no reason to wait.
        let delay = tracks.values.contains { $0 !== player && $0.isPlaying } ? Self.fadeInDelay : 0
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard currentMusic == target else { return }
            if !player.isPlaying { player.play() }
            player.setVolume(Self.musicVolume, fadeDuration: Self.fadeIn)
        }
    }

    private static func soundURL(_ name: String) -> URL? {
        for ext in ["m4a", "wav", "caf", "mp3", "aiff"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }

    private func prepareAudioIfNeeded() {
        guard !audioReady else { return }
        audioReady = true
        #if !os(macOS)
        // Ambient: the game never interrupts the user's music and obeys the mute switch.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        for tone in Tone.allCases {
            if let url = Self.soundURL(tone.rawValue), let file = try? AVAudioPlayer(contentsOf: url) {
                file.prepareToPlay()
                filePlayers[tone] = file
            }
        }
        // The synthesiser only runs for tones that have no file.
        guard filePlayers.count < Tone.allCases.count,
              let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        for tone in Tone.allCases where filePlayers[tone] == nil {
            buffers[tone] = Self.synthesize(tone, format: format)
        }
        if (try? engine.start()) == nil { buffers = [:] }
    }

    /// Additive synthesis: a few partials with a soft attack and exponential
    /// decay. Low fundamentals, quiet upper harmonics and a slow detuned pair
    /// on the chord keep it warm and muted — a wooden tap and a marimba, not
    /// a stock "ding".
    private nonisolated static func synthesize(_ tone: Tone, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        struct Partial { var frequency: Double; var amplitude: Double; var start: Double; var decay: Double }

        let partials: [Partial]
        let duration: Double
        let attack: Double
        switch tone {
        case .snap:
            // A muted wooden tap: G4 with a whisper of its harmonics.
            duration = 0.24
            attack = 0.004
            partials = [Partial(frequency: 392, amplitude: 0.22, start: 0, decay: 26),
                        Partial(frequency: 784, amplitude: 0.07, start: 0, decay: 40),
                        Partial(frequency: 1_568, amplitude: 0.025, start: 0, decay: 70)]
        case .merge:
            // Two soft marimba notes a fifth apart.
            duration = 0.7
            attack = 0.008
            partials = [Partial(frequency: 261.63, amplitude: 0.16, start: 0, decay: 7),
                        Partial(frequency: 523.25, amplitude: 0.06, start: 0, decay: 12),
                        Partial(frequency: 392, amplitude: 0.15, start: 0.09, decay: 6),
                        Partial(frequency: 784, amplitude: 0.05, start: 0.09, decay: 11)]
        case .complete:
            // A slow rising C-major arpeggio; the top note is a detuned pair
            // so it shimmers rather than rings.
            duration = 2.4
            attack = 0.02
            partials = [Partial(frequency: 261.63, amplitude: 0.16, start: 0.0, decay: 2.2),
                        Partial(frequency: 329.63, amplitude: 0.15, start: 0.16, decay: 2.2),
                        Partial(frequency: 392, amplitude: 0.15, start: 0.32, decay: 2.2),
                        Partial(frequency: 522.25, amplitude: 0.11, start: 0.5, decay: 1.5),
                        Partial(frequency: 524.25, amplitude: 0.11, start: 0.5, decay: 1.5),
                        Partial(frequency: 130.81, amplitude: 0.08, start: 0.0, decay: 1.6)]
        case .streak:
            // Three quick notes climbing: the run, not the finish.
            duration = 0.8
            attack = 0.005
            partials = [Partial(frequency: 880, amplitude: 0.12, start: 0, decay: 9),
                        Partial(frequency: 1_046.5, amplitude: 0.12, start: 0.065, decay: 9),
                        Partial(frequency: 1_396.9, amplitude: 0.12, start: 0.13, decay: 5)]
        case .achievement:
            // A quick bell run an octave above the chord, landing on a
            // detuned pair that shimmers: the medal, not a second "solved".
            duration = 1.8
            attack = 0.005
            partials = [Partial(frequency: 659.25, amplitude: 0.11, start: 0, decay: 6),
                        Partial(frequency: 1_318.5, amplitude: 0.025, start: 0, decay: 10),
                        Partial(frequency: 783.99, amplitude: 0.11, start: 0.07, decay: 6),
                        Partial(frequency: 1_568, amplitude: 0.025, start: 0.07, decay: 10),
                        Partial(frequency: 1_046.5, amplitude: 0.1, start: 0.14, decay: 3.5),
                        Partial(frequency: 2_093, amplitude: 0.02, start: 0.14, decay: 8),
                        Partial(frequency: 1_317.5, amplitude: 0.06, start: 0.24, decay: 2.4),
                        Partial(frequency: 1_319.5, amplitude: 0.06, start: 0.24, decay: 2.4)]
        }

        let frames = AVAudioFrameCount(duration * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        for frame in 0..<Int(frames) {
            let t = Double(frame) / format.sampleRate
            var sample = 0.0
            for partial in partials where t >= partial.start {
                let local = t - partial.start
                sample += partial.amplitude * sin(2 * .pi * partial.frequency * local)
                    * exp(-local * partial.decay) * min(1, local / attack)
            }
            // Short fade-out prevents a click at the buffer edge.
            let fade = min(1, (duration - t) * 20)
            let value = Float(sample * max(0, fade))
            for channel in 0..<Int(format.channelCount) { channels[channel][frame] = value }
        }
        return buffer
    }
}
