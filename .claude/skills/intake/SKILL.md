---
name: intake
description: Onboard a new user to apply-agent. Reads their resume, interrogates every number on it, and generates private/answers.yml, private/NUMBERS.md and a resume that builds green. Use when the user says /intake, or on first run when private/ is empty.
---

# /intake

Turns a stranger's resume into a working instance of this system.

Nothing else here runs until `private/` exists. Skip this and you get a scheduler
watching job listings with no answers to fill forms with.

Budget 30 to 60 minutes. Most of that is step 2, and step 2 is the point.

## 1. Read what they already have

Ask for their current resume (PDF, LaTeX, Word, or a link). Extract every claim:
employers, dates, titles, projects, links, and **every number**.

Show the extracted list back and ask what is missing. People leave things off their
resume that belong in an application: memberships, tutoring, a business, a side
project with users.

## 2. Interrogate every number — this is the part that matters

The governing rule of this whole system:

> **If you cannot explain how a number was measured, it should not be on the page.**

For each figure, ask how it was measured and sort it:

- **Measured.** There is a command, a dashboard, a report, or a document that
  reproduces it. Record the reproduce step next to the number.
- **Provisional.** Plausible, defensible in spirit, never actually counted. Keep it
  only with an explicit warning on every build.
- **Unsupported.** Cannot be reproduced and cannot be defended. **It comes off.**

Be direct here and expect resistance. People are attached to their biggest numbers,
and the biggest numbers are usually the least supported. Two things help:

- A smaller number with a stated method beats a larger one without. "About 3
  minutes down to 10 seconds, measured across ten cases" is stronger than "30
  minutes to 3" if the second was a guess.
- The question is not whether the number is true. It is whether they can survive
  being asked how they got it, by someone who does this for a living.

Write the result to `private/NUMBERS.md`, tiered, with the reproduce command beside
every measured figure.

**Also ask what they would not want asked about.** Every real project has a
weakness the author already knows. Write those down privately in
`private/INTERVIEW-DEFENSE.md` with an honest answer prepared for each. Naming your
own defect before an interviewer finds it converts a liability into evidence of
judgment. **That file never leaves their machine.**

## 3. Walk the knockout questions

These end applications before a human reads anything, so get them exactly right and
never guess. Write `private/answers.yml`:

Identity and contact. Work authorization, sponsorship, export-control status.
Education, graduation month and year, GPA and whether it goes on the page.
Languages. Memberships. Availability dates. Pending offers. Voluntary
self-identification. Location preferences and hard excludes.

Two classes need care:

- **Permanently ask-the-human.** Outside business activity, outside employment,
  conflicts of interest, anything with regulatory weight. These change with reality
  and are wrong to automate. Mark them so every drafted answer renders a visible
  marker rather than a guess.
- **Anything unusual but true.** An internship that predates enrollment, a gap, a
  transfer. Record the one-sentence explanation now. Do not reorder dates to hide
  it; someone will count.

## 4. Capture their voice

Ask for two or three things they have written that sound like them: an essay, a
long post, a README they are proud of. Save to `private/voice-sample.md`.

The humanizer uses this to calibrate, and a supplied sample outranks its default
style rules. Without it, output is clean but generic. With it, output sounds like
the person. This is five minutes for a large return.

## 5. Build their resume through the gates

Copy the example configs into place and fill them for this candidate:

```
resume/candidate.env      names, filenames, graduation strings, scan-floor facts
resume/gates.conf         content assertions about their resume
resume/links.conf         every URL the resume embeds
resume/drift.conf         figures that appear in more than one variant
resume/internal-strings.txt   employer-confidential terms that must never ship
```

That last one matters if they have an employer. Internal hostnames, system names,
project code names, usernames, vendor names. The gate fails the build if any of
them reaches a PDF. **The file is gitignored, because the list itself is the
confidential material.**

Then run `cd resume && ./build.sh` and fix what it reports. Do not disable a gate
to make it pass.

## 6. Finish

- `cp agent/config.env.example agent/config.env` and set the feed, term and excludes.
- `python3 agent/fetch_diff.py --baseline` so the agent starts from today rather
  than surfacing every historical listing as new.
- Optional: install the scheduler with `scripts/install-scheduler.sh`.

Tell them what to do next: `/apply <folder>` once the agent has prepared one.

## What good looks like

Every number on their resume either has a reproduce command or a warning. The
knockout answers are exact. `build.sh` is green. The voice sample is real. Nothing
in `private/` is committed.

If they push back on removing an unsupported number, that is their call and it is
their resume. Record the disagreement in `NUMBERS.md` so the next person to read it
knows the figure was questioned, and move on.
