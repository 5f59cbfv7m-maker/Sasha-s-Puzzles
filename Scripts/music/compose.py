"""Sasha's Puzzles' music from 1.4: six pieces written for the game, rendered
with real instrument samples and looped seamlessly. The three tunes of 1.0
(music-library, music-piano, music) stay as they are.

Meditative, slow and spacious, for a long quiet puzzle:
  music-calm-1  Still Lake     D major, 60 bpm. Harp arpeggios, a sparse
                               piano tune, a string bed, cello roots.
  music-calm-2  Morning Mist   F major, 56 bpm. Kalimba ostinato, a long
                               flute line, a warm pad, fretless bass.
  music-calm-3  Starlight      A minor, 66 bpm. Music box tune, vibraphone
                               chords, a pad, cello.

Melodic, tunes to hum along to:
  music-tune-1  Garden Walk    G major, 100 bpm. Flute over fingerpicked
                               nylon guitar; a glockenspiel joins the middle.
  music-tune-2  Sunny Window   D major, 84 bpm. Piano, both hands; strings
                               and a cello lift the second half.
  music-tune-3  Little Waltz   F major, 3/4 at 132 bpm. Clarinet tune over
                               bass and harp, oom-pah-pah.

Every piece is written out note by note below. Each is rendered three times
over and the middle pass is cut out, so the reverb tail of the end runs into
the start and the loop has no seam.

usage:  SF=/path/to/MuseScore_General.sf3 python3 Scripts/music/compose.py out-dir
needs:  fluidsynth on the PATH; mido, numpy, soundfile, pedalboard; afconvert (macOS)
"""
import os
import subprocess
import sys
from pathlib import Path

import mido
import numpy as np
import soundfile as sf
from pedalboard import Compressor, HighpassFilter, Limiter, Pedalboard, Reverb

SR = 44100
TPB = 480
SOUNDFONT = os.environ.get("SF", str(Path.home() / "Desktop/XCode/SashasPuzzles-Promo/music/MuseScore_General.sf3"))
NAMES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def n(name):
    """'Bb4' → MIDI number."""
    pc = NAMES[name[0]] + name.count("#") - name.count("b")
    return 12 * (int(name.lstrip("ABCDEFG#b")) + 1) + pc


CHORDS = {
    "D": ["D", "F#", "A"], "Dmaj7": ["D", "F#", "A", "C#"], "Bm": ["B", "D", "F#"], "Bm7": ["B", "D", "F#", "A"],
    "G": ["G", "B", "D"], "Gmaj7": ["G", "B", "D", "F#"], "A": ["A", "C#", "E"], "A7": ["A", "C#", "E", "G"],
    "F#m": ["F#", "A", "C#"], "F#m7": ["F#", "A", "C#", "E"], "Em": ["E", "G", "B"], "Em7": ["E", "G", "B", "D"],
    "F": ["F", "A", "C"], "Am": ["A", "C", "E"], "Am7": ["A", "C", "E", "G"], "Bb": ["Bb", "D", "F"],
    "Bbmaj7": ["Bb", "D", "F", "A"], "C": ["C", "E", "G"], "C7": ["C", "E", "G", "Bb"], "Dm": ["D", "F", "A"],
    "Dm7": ["D", "F", "A", "C"], "Gm": ["G", "Bb", "D"], "Gm7": ["G", "Bb", "D", "F"], "Fmaj7": ["F", "A", "C", "E"],
    "E7": ["E", "G#", "B", "D"], "D7": ["D", "F#", "A", "C"],
}


def tones(chord, octave):
    """The chord's tones upward from its root in `octave`."""
    out, last = [], -1
    for name in CHORDS[chord]:
        pitch = n(f"{name}{octave}")
        while pitch <= last:
            pitch += 12
        out.append(pitch)
        last = pitch
    return out


def root(chord, octave):
    return n(f"{CHORDS[chord][0]}{octave}")


def tune(bars, meter=4):
    """'A5:1 C6:0.5 r:1' per bar → [(beat, dur, pitch)]."""
    notes, beat = [], 0.0
    for bar in bars:
        start = beat
        for token in bar.split():
            name, dur = token.split(":")
            dur = float(dur)
            if name != "r":
                notes.append((beat, dur, n(name)))
            beat += dur
        assert abs(beat - start - meter) < 1e-6, f"bar does not add up to {meter}: {bar}"
    return notes


class Score:
    def __init__(self, bpm, bars, meter=4):
        self.bpm, self.bars, self.meter, self.notes, self.programs = bpm, bars, meter, [], {}

    def program(self, channel, program, volume=100):
        self.programs[channel] = (program, volume)

    def add(self, channel, beat, dur, pitch, vel):
        self.notes.append((channel, beat, dur, pitch, int(np.clip(vel, 1, 127))))

    def render(self, path, passes=3, reverb=0.16, loudness=-18.0):
        """Writes the piece `passes` times in a row, renders it, keeps the middle pass."""
        mid = mido.MidiFile(ticks_per_beat=TPB)
        track = mido.MidiTrack()
        mid.tracks.append(track)
        track.append(mido.MetaMessage("set_tempo", tempo=int(60_000_000 / self.bpm)))
        events = []
        for channel, (program, volume) in self.programs.items():
            if channel != 9:
                events.append((0, 0, mido.Message("program_change", channel=channel, program=program)))
            events.append((0, 0, mido.Message("control_change", channel=channel, control=7, value=volume)))
            events.append((0, 0, mido.Message("control_change", channel=channel, control=91, value=40)))
        length = self.bars * self.meter
        for k in range(passes):
            for channel, beat, dur, pitch, vel in self.notes:
                b = beat + k * length
                events.append((round(b * TPB), 2, mido.Message("note_on", channel=channel, note=pitch, velocity=vel)))
                events.append((round((b + dur) * TPB), 1, mido.Message("note_off", channel=channel, note=pitch, velocity=0)))
        events.sort(key=lambda e: (e[0], e[1]))
        now = 0
        for tick, _, message in events:
            track.append(message.copy(time=tick - now))
            now = tick
        mid.save(path.with_suffix(".mid"))
        subprocess.run(["fluidsynth", "-ni", "-q", "-R", "0", "-C", "0", "-g", "0.5", "-o", "audio.file.format=float",
                        "-r", str(SR), "-F", str(path.with_suffix(".raw.wav")), SOUNDFONT, str(path.with_suffix(".mid"))],
                       check=True)
        audio, _ = sf.read(path.with_suffix(".raw.wav"), dtype="float32", always_2d=True)
        seconds = length * 60 / self.bpm
        start = size = int(round(seconds * SR))
        loop = audio[start:start + size]
        if len(loop) < size:
            loop = np.pad(loop, ((0, size - len(loop)), (0, 0)))
        board = Pedalboard([HighpassFilter(45), Reverb(room_size=0.62, damping=0.6, wet_level=reverb, dry_level=0.86, width=0.9),
                            Compressor(threshold_db=-20, ratio=2.2, attack_ms=12, release_ms=180), Limiter(threshold_db=-1.5)])
        # The reverb, too, runs over the seam: process two loops, keep the second.
        twice = board(np.concatenate([loop, loop]).T, SR).T[size:]
        # As loud on average as the tunes of 1.0 (about -18 dB RMS), never clipping.
        rms = 20 * np.log10(np.sqrt(np.mean(twice ** 2)) + 1e-9)
        twice *= min(10 ** ((loudness - rms) / 20), 0.95 / max(1e-6, np.abs(twice).max()))
        wav = path.with_suffix(".wav")
        sf.write(wav, twice, SR, subtype="PCM_16")
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", str(wav), str(path.with_suffix(".m4a"))], check=True)
        for extra in [".raw.wav", ".mid", ".wav"]:
            path.with_suffix(extra).unlink(missing_ok=True)
        print(f"{path.name}: {seconds:.1f} s loop")


def arpeggio(s, channel, chords, pattern, step, low, vel, meter=4, accent=8):
    """Broken chords: `pattern` indexes the chord's tones in octaves `low` and `low + 1`."""
    for bar, chord in enumerate(chords):
        notes = tones(chord, low) + tones(chord, low + 1)
        for k, index in enumerate(pattern):
            at = bar * meter + k * step
            if at >= (bar + 1) * meter:
                break
            s.add(channel, at, step * 1.8, notes[index % len(notes)], vel + (accent if k == 0 else 0))


# --- Meditative ------------------------------------------------------------

def still_lake():
    s = Score(bpm=60, bars=16)
    s.program(0, 0, 92)     # piano: the tune
    s.program(1, 46, 82)    # harp: arpeggios
    s.program(2, 49, 60)    # slow strings: the bed
    s.program(3, 42, 66)    # cello: roots
    s.program(4, 8, 58)     # celesta: a glint at the end of each phrase
    chords = ["Dmaj7", "Bm7", "Gmaj7", "A", "Dmaj7", "F#m7", "Gmaj7", "A",
              "Bm7", "F#m7", "Gmaj7", "D", "Em7", "F#m7", "Gmaj7", "A"]
    melody = ["F#5:2 A5:2", "B5:3 A5:1", "G5:2 F#5:1 D5:1", "E5:4",
              "F#5:2 A5:2", "C#6:2 A5:2", "B5:1.5 A5:0.5 G5:1 F#5:1", "E5:3 r:1",
              "D5:2 F#5:2", "A5:2 C#6:1 E6:1", "D6:3 B5:1", "A5:4",
              "G5:2 B5:2", "A5:2 F#5:2", "G5:1 F#5:1 E5:1 D5:1", "E5:3 r:1"]
    for beat, dur, pitch in tune(melody):
        s.add(0, beat, dur * 0.98, pitch, 62 if beat % 4 == 0 else 54)
    arpeggio(s, 1, chords, [0, 1, 2, 3, 4, 3, 2, 1], 0.5, 3, 44)
    for bar, chord in enumerate(chords):
        for p in tones(chord, 4)[:3]:
            s.add(2, bar * 4, 4, p - 12, 40)
        s.add(3, bar * 4, 4, root(chord, 2), 52)
    for bar in (3, 7, 11, 15):
        s.add(4, bar * 4 + 2.5, 1.5, n("A6"), 38)
        s.add(4, bar * 4 + 3, 1, n("E6"), 32)
    return s


def morning_mist():
    s = Score(bpm=56, bars=16)
    s.program(0, 73, 86)    # flute: the long line
    s.program(1, 108, 84)   # kalimba: the ostinato
    s.program(2, 89, 56)    # warm pad
    s.program(3, 35, 70)    # fretless bass
    chords = ["F", "Am7", "Bbmaj7", "C", "F", "Dm7", "Bbmaj7", "C",
              "Dm7", "Am7", "Bbmaj7", "F", "Gm7", "Am7", "Bbmaj7", "C"]
    melody = ["A5:3 C6:1", "E5:2 G5:2", "F5:3 D5:1", "G5:4",
              "A5:2 F5:2", "D5:2 F5:1 A5:1", "D6:3 C6:1", "C6:2 G5:2",
              "F5:2 A5:2", "G5:2 E5:2", "D5:1 F5:1 A5:2", "C6:4",
              "Bb5:2 A5:1 G5:1", "E5:3 C5:1", "D5:2 F5:2", "E5:3 r:1"]
    for beat, dur, pitch in tune(melody):
        s.add(0, beat, dur * 0.96, pitch, 58 if beat % 4 == 0 else 50)
    arpeggio(s, 1, chords, [0, 2, 1, 3, 2, 4, 3, 2], 0.5, 4, 50, accent=6)
    for bar, chord in enumerate(chords):
        for p in tones(chord, 3):
            s.add(2, bar * 4, 4, p, 38)
        s.add(3, bar * 4, 2.5, root(chord, 2), 56)
        s.add(3, bar * 4 + 2.5, 1.5, root(chord, 2) + 7, 46)
    return s


def starlight():
    s = Score(bpm=66, bars=16)
    s.program(0, 10, 92)    # music box: the tune
    s.program(1, 11, 70)    # vibraphone: chords
    s.program(2, 88, 52)    # new age pad
    s.program(3, 42, 62)    # cello
    chords = ["Am7", "Fmaj7", "C", "G", "Am7", "Fmaj7", "C", "E7",
              "Fmaj7", "G", "Em7", "Am7", "Dm7", "Em7", "Fmaj7", "G"]
    melody = ["E5:1 A5:1 C6:1 B5:1", "A5:2 E5:2", "G5:1 E5:1 C5:1 E5:1", "D5:3 r:1",
              "E5:1 A5:1 C6:1 E6:1", "C6:2 A5:2", "G5:1 C6:1 E6:1 D6:1", "B5:3 r:1",
              "A5:1.5 C6:0.5 E6:2", "D6:1.5 B5:0.5 G5:2", "E5:1 G5:1 B5:1 D6:1", "C6:3 r:1",
              "F5:1 A5:1 C6:1 A5:1", "G5:1 B5:1 E6:1 D6:1", "C6:2 A5:1 F5:1", "B5:3 r:1"]
    for beat, dur, pitch in tune(melody):
        s.add(0, beat, dur * 1.4, pitch, 70 if beat % 4 == 0 else 60)
    for bar, chord in enumerate(chords):
        voicing = tones(chord, 4)
        for k in range(4):
            s.add(1, bar * 4 + k, 1.6, voicing[(k + bar) % len(voicing)], 40 if k else 48)
        for p in tones(chord, 3):
            s.add(2, bar * 4, 4, p, 36)
        s.add(3, bar * 4, 4, root(chord, 2), 48)
    return s


# --- Melodic ---------------------------------------------------------------

def garden_walk():
    s = Score(bpm=100, bars=24)
    s.program(0, 73, 96)    # flute: the tune
    s.program(1, 24, 92)    # nylon guitar: fingerpicking
    s.program(2, 32, 84)    # acoustic bass
    s.program(3, 9, 62)     # glockenspiel: doubles the middle section
    s.program(9, 0, 50)     # shaker
    a = ["D5:1 G5:1 B5:1.5 A5:0.5", "G5:1 E5:1 B4:2", "C5:1 E5:1 G5:1 E5:1", "F#5:2 A5:2",
         "B5:1 D6:1 B5:1 G5:1", "F#5:1.5 G5:0.5 A5:1 F#5:1", "E5:1 G5:1 C6:1.5 B5:0.5", "A5:3 r:1"]
    b = ["B5:1.5 A5:0.5 G5:1 B5:1", "E6:2 C6:2", "D6:1 B5:1 G5:1 B5:1", "A5:3 r:1",
         "G5:1 B5:1 E6:1.5 D6:0.5", "C6:1 G5:1 E5:2", "A5:1 C6:1 E6:1 C6:1", "D6:2 C6:1 A5:1"]
    end = a[:7] + ["A5:2 F#5:1 D5:1"]
    chords = ["G", "Em", "C", "D", "G", "Bm", "C", "D",
              "Em", "C", "G", "D", "Em", "C", "Am7", "D7",
              "G", "Em", "C", "D", "G", "Bm", "C", "D7"]
    for beat, dur, pitch in tune(a + b + end):
        s.add(0, beat, dur * 0.92, pitch, 82 if beat % 4 == 0 else 70)
    for beat, dur, pitch in tune(b):
        s.add(3, 32 + beat, min(dur, 1), pitch + 12, 44)
    arpeggio(s, 1, chords, [0, 2, 3, 2, 4, 2, 3, 2], 0.5, 3, 56)
    for bar, chord in enumerate(chords):
        s.add(2, bar * 4, 1.8, root(chord, 2), 80)
        s.add(2, bar * 4 + 2, 1.8, root(chord, 2) + 7, 66)
        for k in range(8):
            s.add(9, bar * 4 + k * 0.5, 0.2, 82, 30 if k % 2 else 40)
    return s


def sunny_window():
    s = Score(bpm=84, bars=24)
    s.program(0, 0, 100)    # piano, right hand: the tune
    s.program(1, 0, 78)     # piano, left hand: broken chords
    s.program(2, 48, 56)    # strings: lift the second half
    s.program(3, 42, 64)    # cello: a counter-line
    s.program(4, 32, 74)    # acoustic bass
    s.program(5, 9, 54)     # glockenspiel: echoes
    a1 = ["F#5:1.5 E5:0.5 D5:1 F#5:1", "E5:1 C#5:1 A4:2", "D5:1 F#5:1 B5:1.5 A5:0.5", "A5:2 F#5:2",
          "G5:1.5 F#5:0.5 E5:1 D5:1", "F#5:2 A5:2", "G5:1 F#5:1 E5:1 D5:1", "E5:3 r:1"]
    a2 = a1[:6] + ["E5:1 A5:1 C#6:1 E6:1", "D6:3 r:1"]
    b = ["B5:2 D6:1 B5:1", "C#6:2 E6:1 C#6:1", "A5:1 F#5:1 C#6:2", "B5:2 F#5:2",
         "G5:1 B5:1 D6:1 E6:1", "C#6:3 A5:1", "F#5:1 A5:1 D6:2", "C#6:1 B5:1 A5:1 G5:1"]
    chords = ["D", "A", "Bm", "F#m", "G", "D", "Em7", "A",
              "D", "A", "Bm", "F#m", "G", "D", "A", "D",
              "G", "A", "F#m", "Bm", "Em7", "A", "D", "A7"]
    for beat, dur, pitch in tune(a1 + a2 + b):
        s.add(0, beat, dur * 0.97, pitch, 74 if beat % 4 == 0 else 64)
    for bar, chord in enumerate(chords):
        notes = [root(chord, 2) + 12] + tones(chord, 3)[1:] + [tones(chord, 4)[0]]
        for k, index in enumerate([0, 1, 2, 3, 2, 1, 2, 3]):
            s.add(1, bar * 4 + k * 0.5, 0.9, notes[index], 46 if k else 54)
        s.add(4, bar * 4, 3.5, root(chord, 2), 62)
        if bar >= 16:
            for p in tones(chord, 4)[:3]:
                s.add(2, bar * 4, 4, p, 40)
            s.add(3, bar * 4, 2, tones(chord, 3)[1], 50)
            s.add(3, bar * 4 + 2, 2, tones(chord, 3)[0], 46)
    for bar, name in [(3, "F#6"), (7, "E6"), (11, "F#6"), (15, "D6")]:
        s.add(5, bar * 4 + 2.5, 1.5, n(name), 40)
    return s


def little_waltz():
    s = Score(bpm=132, bars=32, meter=3)
    s.program(0, 71, 96)    # clarinet: the tune
    s.program(1, 46, 80)    # harp: pah-pah
    s.program(2, 32, 84)    # acoustic bass: oom
    s.program(3, 9, 54)     # glockenspiel: phrase ends
    s.program(4, 48, 50)    # strings: the second half
    a = ["C5:1 F5:1 A5:1", "A5:2 F5:1", "G5:1 Bb5:1 D6:1", "C6:2 Bb5:1",
         "A5:1 C6:1 F6:1", "E6:2 C6:1", "D6:1 C6:1 Bb5:1", "G5:3",
         "C5:1 F5:1 A5:1", "D6:2 A5:1", "Bb5:1 A5:1 G5:1", "E5:2 G5:1",
         "F5:1 D5:1 F5:1", "E5:1 G5:1 Bb5:1", "A5:3", "F5:2 r:1"]
    b = ["D6:2 F6:1", "D6:1 C6:1 Bb5:1", "C6:2 A5:1", "F5:3",
         "G5:1 Bb5:1 D6:1", "E6:1 D6:1 C6:1", "A5:2 C6:1", "F6:3",
         "F6:1 E6:1 D6:1", "C6:2 A5:1", "Bb5:1 A5:1 G5:1", "A5:2 C6:1",
         "Bb5:1 D6:1 Bb5:1", "C6:1 Bb5:1 G5:1", "A5:3", "E5:2 G5:1"]
    chords = ["F", "Dm", "Gm", "C7", "F", "Am", "Bb", "C7",
              "F", "Dm", "Gm", "C7", "Bb", "C7", "F", "F",
              "Bb", "Bb", "F", "F", "Gm", "C7", "F", "F",
              "Dm", "Am", "Bb", "F", "Gm", "C7", "F", "C7"]
    for beat, dur, pitch in tune(a + b, meter=3):
        s.add(0, beat, dur * 0.94, pitch, 80 if beat % 3 == 0 else 68)
    for bar, chord in enumerate(chords):
        start = bar * 3
        bass = root(chord, 2) + (7 if bar % 2 else 0)
        s.add(2, start, 0.9, bass if bass < n("C3") else bass - 12, 82)
        for k in (1, 2):
            for p in tones(chord, 4)[:3]:
                s.add(1, start + k, 0.6, p, 46 if k == 1 else 40)
        if bar >= 16:
            for p in tones(chord, 4)[:3]:
                s.add(4, start, 3, p - 12, 38)
    for bar, name in [(7, "C7"), (15, "F6"), (23, "A6"), (31, "G6")]:
        s.add(3, bar * 3 + 1, 1.5, n(name), 42)
    return s


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    still_lake().render(out / "music-calm-1", reverb=0.24, loudness=-19)
    morning_mist().render(out / "music-calm-2", reverb=0.24, loudness=-19)
    starlight().render(out / "music-calm-3", reverb=0.22, loudness=-19)
    garden_walk().render(out / "music-tune-1")
    sunny_window().render(out / "music-tune-2")
    little_waltz().render(out / "music-tune-3")
