"""Create a reproducible production-style test song with split audio assets."""
import array
import math
from pathlib import Path
import random
import sys
import wave

if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 examples/signal-rooms.py NEW-PROJECT")
root = Path(sys.argv[1])
root.mkdir()
(root / "assets").mkdir()
(root / "revisions").mkdir()

RATE = 48000
BEAT = RATE // 2
voice_frames = 69126
voice = array.array("h")
for frame in range(voice_frames):
    t = frame / RATE
    pitch = 153 + 2.4 * math.sin(2 * math.pi * 5.2 * t)
    vowel = sum(weight * math.sin(2 * math.pi * pitch * harmonic * t)
                for harmonic, weight in [(1, .6), (2, .24), (4, .12), (7, .04)])
    swell = min(1, frame / 1100, (voice_frames-frame) / 1600)
    voice.append(round(vowel * swell * (0.75 + 0.25 * math.sin(9*t)) * 6200))
if sys.byteorder != "little":
    voice.byteswap()
with wave.open(str(root / "assets" / "synthetic-voice.wav"), "wb") as wav:
    wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
    wav.writeframes(voice.tobytes())
parts = ('Drums', 'Bass', 'Keys', 'Texture', 'Voice')
items = []
progressions = [
    (45, (57, 60, 64)), (41, (57, 60, 65)),
    (48, (55, 60, 64)), (43, (55, 59, 62)),
]
def frequency(midi):
    return 440 * 2 ** ((midi - 69) / 12)
def tone(pitch, sample_time):
    return math.sin(math.tau * frequency(pitch) * sample_time)
def compose(part, section, bars, path):
    rng = random.Random(f'{part}/{section}')
    pcm = array.array('h')
    for frame in range(bars * 4 * BEAT):
        beat, offset = divmod(frame, BEAT)
        bass, chord = progressions[(beat // 4 + section) % 4]
        t = offset / RATE
        edge = min(1, offset / 240, (BEAT - offset) / 240)
        if part == 'Drums':
            kick = math.sin(math.tau * (48*t + 4*(1-math.exp(-35*t)))) * math.exp(-20*t)
            hat = rng.uniform(-1, 1) * math.exp(-60*t) * .07
            snare = rng.uniform(-1, 1) * math.exp(-24*t) * .18 if beat % 2 else 0
            left, right = kick * .29 + hat + snare, kick * .29 - hat * .7 + snare
        elif part == 'Bass':
            note = bass - 12 + (7 if beat % 4 == 3 else 0)
            value = (tone(note, t) + .2*tone(note+12, t)) * math.exp(-4*t) * .24
            left, right = value, value
        elif part == 'Keys':
            left = sum(tone(pitch, t) for pitch in chord) * math.exp(-5*t) * .06
            right = sum(tone(pitch, t+.0019) for pitch in chord) * math.exp(-4*t) * .06
        else:
            left = tone(chord[(beat+1) % 3] + 12, t) * math.sin(math.pi * t * 2) * .095
            right = tone(chord[(beat+2) % 3] + 12, t) * math.sin(math.pi * t * 2) * .082
        pcm.extend((int(left * edge * 32767), int(right * edge * 32767)))
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(path), 'wb') as wav:
        wav.setparams((2, 2, RATE, 0, 'NONE', 'not compressed'))
        wav.writeframes(pcm.tobytes())

for section, (name, start, bars) in enumerate((('A', 0, 4), ('B', 16, 8), ('C', 48, 8))):
    for part in parts[:-1]:
        id = f'{part.lower()}-{name.lower()}'
        filename = f'assets/{id}.wav'
        compose(part, section, bars, root / filename)
        items.append(f'(:id "{id}" :kind :clip :part "{part}" :unit :beat :start {start} :duration {bars*4} :asset "{filename}")')
items += [
    f'(:id "guide-vocal" :kind :clip :part "Voice" :unit :frame :start {48*BEAT} :duration {voice_frames} :asset "assets/synthetic-voice.wav")',
    '(:id "keys-reduce" :kind :automation :part "Keys" :unit :beat :start 50 :duration 0)',
    '(:id "c-keys" :kind :notation :part "Keys" :unit :beat :start 48 :duration 8)',
]
(root / 'revisions/0.sexp').write_text(
    '(:revision 0 :parent nil :title "Signal Rooms" :bpm 120 :beats-per-bar 4 :sample-rate 48000'
    ' :sections (("A" 4) ("B" 8) ("C" 8)) :parts ("Drums" "Bass" "Keys" "Texture" "Voice")'
    ' :items (' + '\n '.join(items) + '))\n')
(root / 'HEAD.sexp').write_text('0\n')
(root / 'audition.sexp').write_text('''(:notes (("c-keys" (0 1 67) (1 1 69) (2 2 72) (4 2 67) (6 2 65)))
 :automation (("keys-reduce" . .52d0))
 :mix (("Drums" :asset-gain .56d0) ("Bass" :asset-gain .48d0)
       ("Keys" :asset-gain .60d0 :pan -.18d0) ("Texture" :asset-gain .45d0 :pan .20d0)
       ("Voice" :asset-gain .52d0))
)
''')
