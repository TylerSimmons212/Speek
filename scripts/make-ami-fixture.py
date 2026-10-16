#!/usr/bin/env python3
"""Turns an AMI corpus meeting into a fixture for Speek's opt-in meeting
benchmarks (SpeekTests/MeetingSpeakerBenchmarkTests.swift). The synthetic
`say` meeting (make-meeting-fixture.py) has no overlapped speech, and TTS
voices are far easier to separate than real people. AMI has both.

Inputs (download them yourself; AMI is CC BY 4.0):
  MEETING.Mix-Headset.wav  groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/MEETING/audio/
  MEETING.rttm             github.com/pyannote/AMI-diarization-setup, only_words/rttms/test/

Writes to OUT_DIR:
  far.wav    16 kHz mono Int16, the headset mix as the system tap would hear
             it: gain-normalized so the median 500 ms RMS over annotated
             speech is TARGET_RMS (roughly a conferencing app's AGC'd
             output), with a soft limiter above 0.9 full scale. Raw AMI
             levels vary ~17x between meetings; TS3003a's speech sits below
             the meeting pump's 0.012 activity threshold as recorded.
  far.rttm   the reference RTTM, unchanged
  near.wav   digital silence of the same length (no local user)
  near.rttm  empty
  fixture.json  the gain applied

Only test_live_vs_offline_speaker_labels and the hour-long test make sense
on these fixtures. The echo test needs a local talker.

Usage: scripts/make-ami-fixture.py MIX_HEADSET_WAV RTTM OUT_DIR
"""
import array
import json
import math
import os
import shutil
import sys
import wave

RATE = 16_000
TICK = 8_000  # the meeting pump's 500 ms drain
TARGET_RMS = 0.05  # ≈ −26 dBFS
KNEE = 0.9


def main(src_wav, src_rttm, out):
    os.makedirs(out, exist_ok=True)
    with wave.open(src_wav) as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (RATE, 1, 2):
            sys.exit("expected a 16 kHz mono Int16 WAV (AMI Mix-Headset)")
        pcm = array.array("h", w.readframes(w.getnframes()))
    n = len(pcm)

    speech = bytearray(n // 160 + 1)  # 10 ms frames covered by a reference turn
    for line in open(src_rttm):
        f = line.split()
        if len(f) >= 8 and f[0] == "SPEAKER":
            a = int(float(f[3]) * 100)
            b = int((float(f[3]) + float(f[4])) * 100)
            for i in range(a, min(b, len(speech))):
                speech[i] = 1

    levels = []
    for s in range(0, n - TICK + 1, TICK):
        frames = speech[s // 160:(s + TICK) // 160]
        if sum(frames) >= 0.8 * len(frames):
            x = pcm[s:s + TICK]
            levels.append(math.sqrt(sum(v * v for v in x) / TICK) / 32768)
    if not levels:
        sys.exit("no 500 ms tick is mostly speech; is the RTTM for this WAV?")
    levels.sort()
    median = levels[len(levels) // 2]
    gain = TARGET_RMS / median

    limited = 0
    span = 1 - KNEE
    far = array.array("h", bytes(2 * n))
    for i, v in enumerate(pcm):
        y = v / 32768 * gain
        m = abs(y)
        if m > KNEE:
            limited += 1
            y = math.copysign(KNEE + span * math.tanh((m - KNEE) / span), y)
        far[i] = max(-32768, min(32767, round(y * 32767)))

    write_wav(os.path.join(out, "far.wav"), far)
    write_wav(os.path.join(out, "near.wav"), array.array("h", bytes(2 * n)))
    shutil.copyfile(src_rttm, os.path.join(out, "far.rttm"))
    open(os.path.join(out, "near.rttm"), "w").close()
    info = {
        "source": os.path.basename(src_wav),
        "seconds": n / RATE,
        "rawMedianSpeechRMS": median,
        "gainDB": 20 * math.log10(gain),
        "limitedSampleShare": limited / n,
    }
    with open(os.path.join(out, "fixture.json"), "w") as f:
        json.dump(info, f, indent=2)
    print(json.dumps(info))


def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes())


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
