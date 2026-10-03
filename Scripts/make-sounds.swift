#!/usr/bin/env swift
// Sound effects and a draft of the background music for Sasha's Puzzles.
//
//   swift Scripts/make-sounds.swift [outdir] [music | music-piano | music-library …]
//
// Default outdir is ~/Desktop/Sasha's Sounds; naming tracks renders only those.
// Effects come in variants (snap-A.caf …) to pick by ear; rename the chosen
// ones to snap / merge / complete and drop them into Sources/Resources/Sounds/.
// Each music track (board: music and music-piano, library: music-library) is written as MIDI
// (open it in Logic and pick real instruments) and rendered through the General
// MIDI bank built into macOS (<track>-draft.m4a), folded so the end flows into
// the start without a seam; ship it as Sounds/<track>.m4a.
import AVFoundation

let home = FileManager.default.homeDirectoryForCurrentUser
let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : home.appending(path: "Desktop/Sasha's Sounds", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let rate = 44_100.0

func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

// MARK: - Synthesis primitives

var seed: UInt64 = 0x5A5A_1234
func noise() -> Double {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(Int64(bitPattern: seed) >> 11) / Double(1 << 52)
}

struct Sound {
    var samples: [Double]
    init(seconds: Double) { samples = Array(repeating: 0, count: Int(seconds * rate)) }

    /// A struck resonance: exponentially decaying sine (decay = time constant, s).
    mutating func mode(_ f: Double, _ amp: Double, decay: Double, at start: Double = 0, attack: Double = 0.0015) {
        let first = Int(start * rate)
        for i in first..<samples.count {
            let t = Double(i - first) / rate
            let env = min(1, t / attack) * exp(-t / decay)
            if env < 1e-5, t > attack { break }
            samples[i] += amp * env * sin(2 * .pi * f * t)
        }
    }

    /// The contact itself: a burst of noise, `brightness` 0 (dull) … 1 (sharp).
    mutating func click(_ amp: Double, decay: Double, brightness: Double, at start: Double = 0) {
        let first = Int(start * rate)
        var low = 0.0
        for i in first..<samples.count {
            let t = Double(i - first) / rate
            let env = exp(-t / decay)
            if env < 1e-5 { break }
            let n = noise()
            low += (n - low) * (0.05 + 0.5 * (1 - brightness))
            samples[i] += amp * env * (brightness * (n - low) + (1 - brightness) * low)
        }
    }

    /// A felt thump: a sine whose pitch falls as it dies away.
    mutating func thump(from f0: Double, to f1: Double, _ amp: Double, decay: Double, at start: Double = 0) {
        let first = Int(start * rate)
        var phase = 0.0
        for i in first..<samples.count {
            let t = Double(i - first) / rate
            let env = min(1, t / 0.002) * exp(-t / decay)
            if env < 1e-5, t > 0.002 { break }
            phase += 2 * .pi * (f1 + (f0 - f1) * exp(-t / 0.02)) / rate
            samples[i] += amp * env * sin(phase)
        }
    }

    mutating func marimba(_ midi: Double, _ amp: Double, at start: Double) {
        let f = hz(midi)
        mode(f, amp, decay: 0.45, at: start, attack: 0.002)
        mode(f * 3.93, amp * 0.25, decay: 0.08, at: start)
        mode(f * 9.2, amp * 0.06, decay: 0.025, at: start)
        click(amp * 0.08, decay: 0.002, brightness: 0.3, at: start)
    }

    mutating func kalimba(_ midi: Double, _ amp: Double, at start: Double) {
        let f = hz(midi)
        mode(f, amp, decay: 0.6, at: start, attack: 0.003)
        mode(f * 5.4, amp * 0.12, decay: 0.05, at: start)
        mode(f * 2.01, amp * 0.1, decay: 0.2, at: start)
    }

    /// Celesta / music box: bright, bell-like and short.
    mutating func bell(_ midi: Double, _ amp: Double, at start: Double, decay: Double = 0.9) {
        let f = hz(midi)
        mode(f, amp, decay: decay, at: start, attack: 0.002)
        mode(f * 2, amp * 0.3, decay: decay * 0.4, at: start)
        mode(f * 5.4, amp * 0.1, decay: decay * 0.1, at: start)
    }

    /// A soft sustained chord: detuned sines with a slow swell and release.
    mutating func pad(_ notes: [Double], _ amp: Double, at start: Double, length: Double, attack: Double = 0.35) {
        let first = Int(start * rate), count = Int(length * rate)
        for i in first..<min(samples.count, first + count) {
            let t = Double(i - first) / rate
            let env = min(1, t / attack) * min(1, (length - t) / 0.8)
            var s = 0.0
            for n in notes {
                let f = hz(n)
                s += sin(2 * .pi * f * 1.002 * t) + sin(2 * .pi * f * 0.998 * t) + 0.25 * sin(4 * .pi * f * t)
            }
            samples[i] += amp * env * s / Double(notes.count)
        }
    }

    /// A small Schroeder room so the longer sounds do not ring in a vacuum.
    mutating func reverb(_ mix: Double, size: Double = 1) {
        var wet = Array(repeating: 0.0, count: samples.count)
        for delay in [1557, 1617, 1491, 1422].map({ Int(Double($0) * size) }) {
            var line = Array(repeating: 0.0, count: delay), index = 0, low = 0.0
            for i in samples.indices {
                let y = line[index]
                low = y * 0.6 + low * 0.4
                line[index] = samples[i] + low * 0.82
                index = (index + 1) % delay
                wet[i] += y / 4
            }
        }
        for delay in [225, 556] {
            var line = Array(repeating: 0.0, count: delay), index = 0
            for i in wet.indices {
                let y = line[index]
                line[index] = wet[i] + y * 0.5
                wet[i] = y - wet[i] * 0.5
                index = (index + 1) % delay
            }
        }
        for i in samples.indices { samples[i] += mix * wet[i] }
    }

    /// Peak-normalise, then fade the last 10 ms so the end never clicks.
    func finished(peak: Double) -> [Float] {
        let top = samples.map(abs).max() ?? 1
        let fade = Int(0.01 * rate)
        return samples.enumerated().map { i, s in
            Float(s / top * peak * min(1, Double(samples.count - i) / Double(fade)))
        }
    }
}

func write(_ channels: [[Float]], to url: URL, settings: [String: Any]) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count))!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
    buffer.frameLength = buffer.frameCapacity
    for (c, data) in channels.enumerated() {
        data.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: data.count) }
    }
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

/// Effects are tiny, so they stay uncompressed CAF: AAC would add ~50 ms of
/// encoder priming in front of every tap.
func effect(_ name: String, _ sound: Sound, peak: Double = 0.7) throws {
    try write([sound.finished(peak: peak)], to: out.appending(path: "\(name).caf"),
              settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    print("\(name).caf")
}

// MARK: - Effects

// snap: a piece settles into place.
func woodTap(_ s: inout Sound, _ amp: Double = 1, at t: Double = 0) {
    s.click(0.5 * amp, decay: 0.004, brightness: 0.8, at: t)
    s.mode(720, 0.5 * amp, decay: 0.045, at: t)
    s.mode(1650, 0.3 * amp, decay: 0.025, at: t)
    s.mode(2900, 0.15 * amp, decay: 0.012, at: t)
    s.mode(180, 0.35 * amp, decay: 0.03, at: t)
}
var snapA = Sound(seconds: 0.25); woodTap(&snapA)
try effect("snap-A (дерево)", snapA)

var snapB = Sound(seconds: 0.25)
snapB.thump(from: 260, to: 150, 0.8, decay: 0.05)
snapB.click(0.15, decay: 0.003, brightness: 0.2)
try effect("snap-B (мягкий войлок)", snapB)

var snapC = Sound(seconds: 0.2)
snapC.click(0.6, decay: 0.006, brightness: 0.9)
snapC.mode(420, 0.35, decay: 0.02)
snapC.mode(2300, 0.25, decay: 0.01)
snapC.click(0.25, decay: 0.003, brightness: 0.9, at: 0.018)
try effect("snap-C (картон, щёлк)", snapC)

// merge: two groups join.
var mergeA = Sound(seconds: 1.0)
woodTap(&mergeA, 0.6); mergeA.marimba(67, 0.6, at: 0.03); mergeA.marimba(74, 0.55, at: 0.14)
mergeA.reverb(0.12)
try effect("merge-A (маримба, две ноты)", mergeA)

var mergeB = Sound(seconds: 1.1)
mergeB.thump(from: 260, to: 150, 0.4, decay: 0.05)
mergeB.kalimba(72, 0.6, at: 0.02); mergeB.kalimba(79, 0.5, at: 0.12)
mergeB.reverb(0.15)
try effect("merge-B (калимба)", mergeB)

var mergeC = Sound(seconds: 1.2)
woodTap(&mergeC, 0.7); mergeC.bell(88, 0.25, at: 0.04, decay: 0.5)
mergeC.reverb(0.2)
try effect("merge-C (дерево и колокольчик)", mergeC)

// streak: several pieces in a row found their place without a miss — a snap
// with three quick notes climbing over it.
var streakA = Sound(seconds: 1.0)
woodTap(&streakA, 0.6)
for (i, note) in [81.0, 84, 89].enumerated() { streakA.kalimba(note, 0.5, at: 0.03 + Double(i) * 0.065) }
streakA.reverb(0.15)
try effect("streak-A (дерево и три ноты вверх)", streakA)

// complete: the picture is finished. F major, like the music.
var completeA = Sound(seconds: 2.8)
for (i, note) in [77.0, 81, 84, 89].enumerated() { completeA.marimba(note, 0.5, at: Double(i) * 0.12) }
for (i, note) in [77.0, 81, 84, 89].enumerated() { completeA.marimba(note, 0.35, at: 0.62 + Double(i) * 0.025) }
completeA.pad([53, 60, 69], 0.12, at: 0.3, length: 2.4)
completeA.reverb(0.25)
try effect("complete-A (маримба, арпеджио)", completeA)

var completeB = Sound(seconds: 3.0)
for (i, note) in [84.0, 89, 93, 96, 101].enumerated() { completeB.bell(note, 0.35, at: Double(i) * 0.1) }
for i in 0..<8 {   // sparkle: pentatonic notes, fading
    let note = [89.0, 91, 93, 96, 98, 101][Int((noise() + 1) * 3) % 6]
    completeB.bell(note, 0.18 * (1 - Double(i) / 9), at: 0.6 + Double(i) * 0.17, decay: 0.5)
}
completeB.pad([53, 60, 65, 69], 0.1, at: 0.2, length: 2.6)
completeB.reverb(0.3)
try effect("complete-B (музыкальная шкатулка)", completeB)

var completeC = Sound(seconds: 2.8)
completeC.pad([41, 53, 60, 65, 69], 0.3, at: 0, length: 2.6, attack: 0.25)
completeC.bell(84, 0.3, at: 0.05, decay: 1.2); completeC.bell(89, 0.25, at: 0.45, decay: 1.2)
completeC.reverb(0.35)
try effect("complete-C (тёплый аккорд)", completeC)

// MARK: - Music

/// One looping track: its notes (in beats), the tempo and metre, and which
/// General MIDI programs play each part in the draft render.
struct Note { var track: Int; var pitch: Int; var start: Double; var length: Double; var velocity: Int }
struct Piece {
    var stem: String
    var bpm: Double
    var beatsPerBar: Int
    var bars: Int
    var parts: [(name: String, program: Int)]
    var reverb: AVAudioUnitReverbPreset
    var wet: Float
    var notes: [Note]
}

// Board: F major, 76 BPM, vibraphone over a rolling piano — warm and moving.
func boardPiece() -> Piece {
    struct Chord { var root: Int; var minor = false; var seventh = false; var bass: Int? }
    let phraseA = [Chord(root: 5), Chord(root: 0, bass: 4), Chord(root: 2, minor: true), Chord(root: 9, minor: true),
                   Chord(root: 10), Chord(root: 5, bass: 9), Chord(root: 7, minor: true, seventh: true), Chord(root: 0)]
    let phraseB = [Chord(root: 10), Chord(root: 0), Chord(root: 9, minor: true), Chord(root: 2, minor: true),
                   Chord(root: 7, minor: true, seventh: true), Chord(root: 0, bass: 4), Chord(root: 5), Chord(root: 0, seventh: true)]
    let melodyA: [[(Int, Double)]] = [
        [(72, 1.5), (69, 0.5), (65, 1), (69, 1)], [(67, 2), (64, 1), (67, 1)],
        [(65, 1.5), (69, 0.5), (74, 2)], [(72, 4)],
        [(74, 1.5), (72, 0.5), (70, 1), (74, 1)], [(72, 1.5), (69, 0.5), (65, 2)],
        [(67, 1), (69, 1), (70, 1), (74, 1)], [(72, 3), (0, 1)]]
    let melodyB: [[(Int, Double)]] = [
        [(77, 2), (74, 1), (70, 1)], [(76, 2), (72, 1), (67, 1)],
        [(69, 1.5), (72, 0.5), (76, 2)], [(74, 3), (0, 1)],
        [(70, 1), (74, 1), (77, 1), (74, 1)], [(72, 1.5), (70, 0.5), (67, 2)],
        [(69, 2), (67, 1), (65, 1)], [(67, 2), (0, 2)]]
    // Two passes; the second plays the first phrase an octave up and softer.
    let chords = phraseA + phraseB + phraseA + phraseB
    let melody = melodyA + melodyB + melodyA.map { $0.map { ($0.0 == 0 ? 0 : $0.0 + 12, $0.1) } } + melodyB

    var notes: [Note] = []
    for (bar, chord) in chords.enumerated() {
        let t0 = Double(bar * 4)
        let third = chord.minor ? 3 : 4
        var base = 36 + chord.root; if base < 41 { base += 12 }
        var bass = 24 + (chord.bass ?? chord.root); if bass < 29 { bass += 12 }
        let top = chord.seventh ? base + 22 : base + 19
        // Piano: a rolling eighth-note figure, each note held to the bar line like a pedal.
        for (i, pitch) in [bass, base + 7, base + 12, base + 12 + third, top, base + 12 + third, base + 12, base + 7].enumerated() {
            let start = t0 + Double(i) * 0.5
            notes.append(Note(track: 1, pitch: pitch, start: start, length: t0 + 4 - start,
                              velocity: i == 0 ? 52 : 40 + (i % 3) * 3))
        }
        notes.append(contentsOf: [base + 12, base + 12 + third, base + 19].map {
            Note(track: 2, pitch: $0, start: t0, length: 4, velocity: 34) })
        var t = t0
        let soft = (16..<24).contains(bar)
        for (pitch, length) in melody[bar] {
            if pitch > 0 {
                notes.append(Note(track: 0, pitch: pitch, start: t, length: length * 0.95,
                                  velocity: (soft ? 52 : 68) + Int(noise() * 5)))
            }
            t += length
        }
    }
    return Piece(stem: "music", bpm: 76, beatsPerBar: 4, bars: chords.count,
                 parts: [("Melody (vibraphone)", 11), ("Piano", 0), ("Pad", 89)],
                 reverb: .mediumHall, wet: 22, notes: notes)
}

// Library: D major, 60 BPM in 3/4, a slow piano in the manner of a
// Gymnopédie — a low bass on one, a quiet chord on two, a few long melody
// notes and a lot of air. Calm and thoughtful while a picture is chosen.
func libraryPiece() -> Piece {
    // (bass, chord) as MIDI notes, voiced by hand.
    let dMaj7 = (38, [54, 57, 61]), gMaj7 = (43, [54, 59, 62]), bm7 = (35, [54, 57, 62])
    let em7 = (40, [55, 59, 62]), a7sus = (33, [55, 62, 64]), asus = (33, [57, 62, 64])
    let fsm7 = (42, [57, 61, 64]), dOverFs = (42, [57, 61, 66])
    let phraseA = [dMaj7, gMaj7, bm7, gMaj7, em7, a7sus, dMaj7, asus]
    let phraseB = [gMaj7, fsm7, em7, dOverFs, gMaj7, bm7, em7, a7sus]
    let melodyA: [[(Int, Double)]] = [
        [(0, 1), (78, 1), (81, 1)], [(78, 2), (74, 1)], [(76, 3)], [(0, 1), (74, 1), (71, 1)],
        [(74, 2), (76, 1)], [(74, 3)], [(0, 1), (73, 1), (69, 1)], [(71, 2), (69, 1)]]
    let melodyB: [[(Int, Double)]] = [
        [(0, 1), (83, 1), (81, 1)], [(81, 2), (76, 1)], [(79, 3)], [(0, 1), (78, 1), (74, 1)],
        [(76, 1), (78, 1), (79, 1)], [(78, 3)], [(0, 1), (76, 1), (74, 1)], [(76, 3)]]
    let chords = phraseA + phraseB + phraseA + phraseB
    let melody = melodyA + melodyB + melodyA.map { $0.map { ($0.0 == 0 ? 0 : $0.0 + 12, $0.1) } } + melodyB

    var notes: [Note] = []
    for (bar, (bass, chord)) in chords.enumerated() {
        let t0 = Double(bar * 3)
        notes.append(Note(track: 1, pitch: bass, start: t0, length: 3, velocity: 46))
        notes.append(contentsOf: chord.map { Note(track: 1, pitch: $0, start: t0 + 1, length: 2, velocity: 32) })
        notes.append(contentsOf: (chord + [bass + 24]).map { Note(track: 2, pitch: $0, start: t0, length: 3, velocity: 24) })
        var t = t0
        let soft = (16..<24).contains(bar)
        for (pitch, length) in melody[bar] {
            if pitch > 0 {
                notes.append(Note(track: 0, pitch: pitch, start: t, length: length * 0.98,
                                  velocity: (soft ? 44 : 58) + Int(noise() * 4)))
            }
            t += length
        }
    }
    return Piece(stem: "music-library", bpm: 60, beatsPerBar: 3, bars: chords.count,
                 parts: [("Melody (piano)", 0), ("Piano", 0), ("Pad", 89)],
                 reverb: .largeHall, wet: 32, notes: notes)
}

// Board, piano: the library's language with a little more motion for play —
// G major, 66 BPM in 3/4, the left hand rolling the chord in eighths under a
// sparse melody. Five phrases (A B C A' B') so a long session hears a bridge.
func boardPianoPiece() -> Piece {
    let gMaj7 = (43, [54, 59, 62]), cMaj7 = (36, [55, 59, 64]), em7 = (40, [55, 59, 62])
    let am7 = (33, [55, 60, 64]), d7sus = (38, [55, 57, 60]), d = (38, [54, 57, 62])
    let bm7 = (35, [54, 57, 62]), cAdd9 = (36, [55, 62, 64]), em9 = (40, [55, 59, 66])
    let phraseA = [gMaj7, cMaj7, gMaj7, cMaj7, em7, am7, d7sus, d]
    let phraseB = [cMaj7, bm7, am7, gMaj7, cAdd9, em9, am7, d7sus]
    let phraseC = [em7, bm7, cMaj7, gMaj7, am7, em7, cAdd9, d7sus]
    let melodyA: [[(Int, Double)]] = [
        [(74, 2), (78, 1)], [(79, 2), (76, 1)], [(74, 3)], [(0, 1), (71, 1), (72, 1)],
        [(74, 1.5), (71, 0.5), (67, 1)], [(72, 3)], [(0, 1), (69, 1), (72, 1)], [(69, 3)]]
    let melodyB: [[(Int, Double)]] = [
        [(76, 2), (79, 1)], [(78, 3)], [(76, 1), (72, 1), (76, 1)], [(74, 3)],
        [(0, 1), (74, 1), (76, 1)], [(78, 2), (79, 1)], [(81, 1.5), (79, 0.5), (76, 1)], [(74, 3)]]
    let melodyC: [[(Int, Double)]] = [
        [(0, 1), (71, 1), (74, 1)], [(78, 2), (74, 1)], [(76, 3)], [(0, 1), (79, 1), (78, 1)],
        [(76, 2), (72, 1)], [(71, 3)], [(0, 1), (74, 1), (76, 1)], [(72, 2), (69, 1)]]
    let chords = phraseA + phraseB + phraseC + phraseA + phraseB
    let melody = melodyA + melodyB + melodyC + melodyA.map { $0.map { ($0.0 == 0 ? 0 : $0.0 + 12, $0.1) } } + melodyB

    var notes: [Note] = []
    for (bar, (bass, chord)) in chords.enumerated() {
        let t0 = Double(bar * 3)
        notes.append(Note(track: 1, pitch: bass, start: t0, length: 3, velocity: 44))
        // Up and back down the chord, each note held to the bar line like a pedal.
        for (i, pitch) in [chord[0], chord[1], chord[2], chord[1], chord[0]].enumerated() {
            let start = t0 + 0.5 + Double(i) * 0.5
            notes.append(Note(track: 1, pitch: pitch, start: start, length: t0 + 3 - start,
                              velocity: 30 + (i == 2 ? 4 : 0)))
        }
        notes.append(contentsOf: (chord + [bass + 24]).map { Note(track: 2, pitch: $0, start: t0, length: 3, velocity: 22) })
        var t = t0
        let soft = (24..<32).contains(bar)
        for (pitch, length) in melody[bar] {
            if pitch > 0 {
                notes.append(Note(track: 0, pitch: pitch, start: t, length: length * 0.98,
                                  velocity: (soft ? 44 : 58) + Int(noise() * 4)))
            }
            t += length
        }
    }
    return Piece(stem: "music-piano", bpm: 66, beatsPerBar: 3, bars: chords.count,
                 parts: [("Melody (piano)", 0), ("Piano", 0), ("Pad", 89)],
                 reverb: .largeHall, wet: 30, notes: notes)
}

// MIDI file for Logic: a conductor track and one track per part.
func vlq(_ value: Int) -> [UInt8] {
    var v = value, bytes = [UInt8(v & 0x7F)]
    v >>= 7
    while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
    return bytes
}
func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8((v >> ($0 * 8)) & 0xFF) } }
func chunk(_ name: String, _ events: [(tick: Int, off: Bool, bytes: [UInt8])]) -> [UInt8] {
    var data: [UInt8] = [0, 0xFF, 0x03] + vlq(name.utf8.count) + Array(name.utf8)
    var last = 0
    for e in events.sorted(by: { ($0.tick, $0.off ? 0 : 1) < ($1.tick, $1.off ? 0 : 1) }) {
        data += vlq(e.tick - last) + e.bytes
        last = e.tick
    }
    data += [0, 0xFF, 0x2F, 0]
    return Array("MTrk".utf8) + be(data.count, 4) + data
}

func writeMIDI(_ piece: Piece) throws {
    let tpq = 480
    var midi = Array("MThd".utf8) + be(6, 4) + be(1, 2) + be(piece.parts.count + 1, 2) + be(tpq, 2)
    midi += chunk("Sasha's Puzzles", [(0, false, [0xFF, 0x51, 0x03] + be(Int(60_000_000 / piece.bpm), 3)),
                                      (0, false, [0xFF, 0x58, 0x04, UInt8(piece.beatsPerBar), 2, 24, 8])])
    for (track, part) in piece.parts.enumerated() {
        var events: [(tick: Int, off: Bool, bytes: [UInt8])] = []
        for n in piece.notes where n.track == track {
            let on: [UInt8] = [UInt8(0x90 | track), UInt8(n.pitch), UInt8(n.velocity)]
            let off: [UInt8] = [UInt8(0x80 | track), UInt8(n.pitch), 0]
            events.append((Int(n.start * Double(tpq)), false, on))
            events.append((Int((n.start + n.length) * Double(tpq)), true, off))
        }
        midi += chunk(part.name, events)
    }
    try Data(midi).write(to: out.appending(path: "\(piece.stem).mid"))
    print("\(piece.stem).mid")
}

// Draft render: General MIDI bank, notes fired block by block (1.5 ms blocks).
func renderDraft(_ piece: Piece) throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 64)
    let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    let samplers = piece.parts.map { part -> AVAudioUnitSampler in
        let s = AVAudioUnitSampler()
        engine.attach(s)
        engine.connect(s, to: engine.mainMixerNode, format: format)
        try! s.loadSoundBankInstrument(at: bank, program: UInt8(part.program),
                                       bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        return s
    }
    let room = AVAudioUnitReverb()
    room.loadFactoryPreset(piece.reverb); room.wetDryMix = piece.wet
    engine.attach(room)
    engine.connect(engine.mainMixerNode, to: room, format: format)
    engine.connect(room, to: engine.outputNode, format: format)
    try engine.start()

    let secondsPerBeat = 60 / piece.bpm
    let loopFrames = Int(Double(piece.bars * piece.beatsPerBar) * secondsPerBeat * rate), tailFrames = Int(6 * rate)
    var events: [(frame: Int, on: Bool, note: Note)] = []
    for n in piece.notes {
        events.append((Int(n.start * secondsPerBeat * rate), true, n))
        events.append((Int((n.start + n.length) * secondsPerBeat * rate), false, n))
    }
    events.sort { ($0.frame, $0.on ? 1 : 0) < ($1.frame, $1.on ? 1 : 0) }
    var left: [Float] = [], right: [Float] = []
    let block = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 64)!
    var frame = 0, next = 0
    while frame < loopFrames + tailFrames {
        while next < events.count, events[next].frame < frame + 64 {
            let e = events[next]
            if e.on { samplers[e.note.track].startNote(UInt8(e.note.pitch), withVelocity: UInt8(e.note.velocity), onChannel: 0) }
            else { samplers[e.note.track].stopNote(UInt8(e.note.pitch), onChannel: 0) }
            next += 1
        }
        guard try engine.renderOffline(64, to: block) == .success else { fatalError("render failed") }
        left += UnsafeBufferPointer(start: block.floatChannelData![0], count: Int(block.frameLength))
        right += UnsafeBufferPointer(start: block.floatChannelData![1], count: Int(block.frameLength))
        frame += Int(block.frameLength)
    }
    // Fold the release of the last bar onto the first so the loop has no seam.
    for i in 0..<tailFrames { left[i] += left[loopFrames + i]; right[i] += right[loopFrames + i] }
    left.removeLast(left.count - loopFrames); right.removeLast(right.count - loopFrames)
    let peak = max(left.map(abs).max()!, right.map(abs).max()!)
    guard peak > 0.001 else { fatalError("\(piece.stem) rendered silent") }
    let gain = 0.89 / peak   // -1 dBFS
    left = left.map { $0 * gain }; right = right.map { $0 * gain }

    let wav = out.appending(path: "\(piece.stem)-draft.wav")
    try write([left, right], to: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                 AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                 AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    let m4a = out.appending(path: "\(piece.stem)-draft.m4a")
    try? FileManager.default.removeItem(at: m4a)
    let convert = Process()
    convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    convert.arguments = ["-f", "m4af", "-d", "aac", "-b", "160000", wav.path, m4a.path]
    try convert.run(); convert.waitUntilExit()
    try FileManager.default.removeItem(at: wav)
    // Loudness by 10-second stretch, as a sanity check nobody has to listen for.
    let rms = stride(from: 0, to: loopFrames, by: Int(10 * rate)).map { start -> String in
        let slice = left[start..<min(loopFrames, start + Int(10 * rate))]
        return String(format: "%.0f", 20 * log10(sqrt(slice.reduce(0) { $0 + Double($1 * $1) } / Double(slice.count))))
    }
    print("\(piece.stem)-draft.m4a  \(String(format: "%.0f", Double(loopFrames) / rate)) s, RMS dB per 10 s: \(rms.joined(separator: " "))")
}

// Only the pieces named on the command line after the directory, or both.
let wanted = Set(CommandLine.arguments.dropFirst(2))
for piece in [boardPiece(), boardPianoPiece(), libraryPiece()] where wanted.isEmpty || wanted.contains(piece.stem) {
    try writeMIDI(piece)
    try renderDraft(piece)
}
