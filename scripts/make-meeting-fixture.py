#!/usr/bin/env python3
"""Builds a synthetic meeting with known speakers for Speek's opt-in
meeting benchmarks (SpeekTests/MeetingSpeakerBenchmarkTests.swift).

Renders each turn with macOS `say`, then lays the turns out on one timeline:

  far.wav / far.rttm    remote participants: what the system-audio tap hears
  near.wav / near.rttm  the local user ("You"): what the mic hears directly

Both WAVs are 16 kHz mono Int16 and the same length. Remote turns are
separated by 0.15-1.4 s pauses (some shorter than the meeting gate's 0.8 s,
so pause-bounded windows sometimes hold two voices); "You" turns leave the
far track silent, and a few short "You" backchannels overlap remote speech.

TTS voices are far easier to tell apart than real people: use this to
compare labeling strategies, not as an absolute DER figure.

Usage: scripts/make-meeting-fixture.py OUT_DIR
"""
import os
import random
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 16_000
VOICES = {
    "A": "Samantha",  # en_US
    "B": "Daniel",    # en_GB
    "C": "Karen",     # en_AU
    "D": "Rishi",     # en_IN
    "Y": "Moira",     # en_IE — the local user
}

# (speaker, text). Lines prefixed "~" are "You" backchannels spoken over the
# previous remote turn instead of after it.
DIALOGUE = [
    ("A", "Okay, let's get started. Thanks everyone for joining. The goal today is to lock the launch plan for the spring release."),
    ("B", "Sounds good. I have the latest numbers from the beta if we want to start there."),
    ("A", "Yes, please, go ahead."),
    ("B", "So we had about four thousand active testers last week, which is up thirty percent. Retention after seven days is sitting at sixty two percent, and crash free sessions are just over ninety nine percent."),
    ("C", "That retention number is better than I expected."),
    ("B", "Same. The onboarding changes really helped."),
    ("Y", "Do we know how much of that came from the new tutorial versus the email nudges?"),
    ("B", "Not cleanly. They shipped in the same week, unfortunately."),
    ("D", "I can split it out. We tagged the cohorts, so I can compare people who skipped the tutorial."),
    ("A", "Great, let's do that before Friday."),
    ("C", "Right."),
    ("C", "On the marketing side, we have the landing page draft ready and the press list is about eighty contacts. The open question is whether we do an embargo or a soft launch."),
    ("A", "What's your recommendation?"),
    ("C", "Embargo. We get one shot at a story, and a soft launch tends to fizzle."),
    ("D", "The risk is that the servers aren't ready for a spike. Last time we had a few hours of degraded performance."),
    ("~Y", "Mm-hm."),
    ("D", "I'd want at least two weeks of load testing before we commit to a date."),
    ("Y", "Two weeks is fine if we start Monday. I can free up the infrastructure team."),
    ("A", "Okay."),
    ("B", "One more data point. Support tickets are mostly about sync conflicts. About forty percent of them."),
    ("D", "Yeah, that's the offline editing path. We have a fix in review."),
    ("C", "Will it make the release?"),
    ("D", "It should. It's behind a flag, so we can turn it off if it misbehaves."),
    ("A", "Let's make that a hard requirement. I don't want to launch with the top support issue still open."),
    ("B", "Agreed."),
    ("Y", "What about pricing? Are we still planning the annual discount?"),
    ("C", "We are. Twenty percent off annual, and a thirty day trial instead of fourteen."),
    ("A", "I'm a little worried the longer trial delays revenue."),
    ("C", "It does, by about a month. But conversion was higher in the test, so it pays back by month three."),
    ("B", "The test was small though. Maybe six hundred people."),
    ("C", "True."),
    ("D", "We could run both trial lengths at launch and decide after a month."),
    ("A", "I like that. Low risk, and we learn something."),
    ("~Y", "Yeah."),
    ("A", "Okay, next item. Localization. Where are we?"),
    ("D", "German, French, and Japanese are done. Spanish is in review. Portuguese slipped to the next release."),
    ("C", "Japanese is the important one for the press list, so that's good."),
    ("Y", "Did legal sign off on the new terms for the European markets?"),
    ("A", "Not yet. I'll chase them today."),
    ("B", "If it helps, the privacy page changes are already merged."),
    ("A", "Thanks."),
    ("D", "Quick question on the timeline. Are we targeting the second week of March or the third?"),
    ("A", "Third, assuming load testing starts Monday."),
    ("D", "Okay, that works."),
    ("C", "Then the embargo would lift on the eighteenth. I'll brief the first five outlets the week before."),
    ("B", "Do you want beta testimonials for the page?"),
    ("C", "Yes, three or four short quotes would be perfect."),
    ("B", "I'll pull some from the survey."),
    ("Y", "Let's make sure we get permission in writing for anything we quote."),
    ("B", "Of course."),
    ("A", "Anything else on the launch?"),
    ("D", "Just the status page. We should have one public before the press goes out."),
    ("C", "Good call."),
    ("A", "Okay, let's recap. Load testing starts Monday, the sync fix is a hard requirement, two trial lengths at launch, and the embargo lifts on the eighteenth."),
    ("~Y", "Right."),
    ("A", "Actions: the cohort split by Friday, legal sign off today, testimonials from the survey, and a public status page. Did I miss anything?"),
    ("Y", "I think that covers it. I'll send notes after this."),
    ("A", "Perfect. Thanks everyone."),
    ("B", "Thanks, bye."),
    ("C", "Bye."),
    ("D", "See you."),
]


def render(voice, text, path):
    subprocess.run(
        ["say", "-v", voice, "-o", path, "--file-format=WAVE", "--data-format=LEI16@16000", text],
        check=True,
    )
    with wave.open(path, "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes())


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rng = random.Random(7)
    far, near = bytearray(), bytearray()
    far_turns, near_turns = [], []
    t = 0  # samples
    last_remote_start = 0

    with tempfile.TemporaryDirectory() as tmp:
        for index, (tag, text) in enumerate(DIALOGUE):
            overlap = tag.startswith("~")
            speaker = tag.lstrip("~")
            pcm = render(VOICES[speaker], text, os.path.join(tmp, f"{index}.wav"))
            n = len(pcm) // 2
            if overlap:
                # Backchannel 40% into the previous remote turn.
                start = last_remote_start + int((t - last_remote_start) * 0.4)
                end = start + n
                if len(near) < end * 2:
                    near.extend(b"\0" * (end * 2 - len(near)))
                near[start * 2:end * 2] = pcm
                near_turns.append((start, end, speaker))
                continue
            gap = int(rng.uniform(0.15, 1.4) * RATE)
            t += gap
            for track in (far, near):
                track.extend(b"\0" * (t * 2 - len(track)))
            if speaker == "Y":
                near.extend(pcm)
                far.extend(b"\0" * (len(pcm)))
                near_turns.append((t, t + n, speaker))
            else:
                far.extend(pcm)
                near.extend(b"\0" * (len(pcm)))
                far_turns.append((t, t + n, speaker))
                last_remote_start = t
            t += n

    t += RATE
    for track in (far, near):
        track.extend(b"\0" * (t * 2 - len(track)))
    for name, data, turns in (("far", far, far_turns), ("near", near, near_turns)):
        with wave.open(os.path.join(out, f"{name}.wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(bytes(data))
        with open(os.path.join(out, f"{name}.rttm"), "w") as f:
            for start, end, speaker in turns:
                f.write(f"SPEAKER {name} 1 {start / RATE:.3f} {(end - start) / RATE:.3f} <NA> <NA> {speaker} <NA> <NA>\n")
    print(f"{t / RATE / 60:.1f} min: {len(far_turns)} remote turns, {len(near_turns)} local turns -> {out}")


if __name__ == "__main__":
    main()
