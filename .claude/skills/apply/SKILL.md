---
name: apply
description: Fill a prepared job application in the user's Chrome, pausing at attestations and final review. Use when the user says /apply <folder> for a folder under applications/. Drives the real browser; requires the user present. Never clicks submit.
---

# /apply &lt;folder&gt;

Interactive half of the application agent. The scheduled pipeline prepared the
folder; this skill turns it into a filled application with the human's finger on
the submit button.

Personal values come from `private/answers.yml`. This skill contains no
candidate-specific facts by design: if you find yourself hardcoding a name, an
email, a school or a preference here, it belongs in `answers.yml` instead.

## Preconditions

1. `applications/<folder>/` must exist with `APPLY.md` and `jd.txt`. If not, stop
   and list what is ready (`ls applications/`).
2. Verify the posting link is live (curl, follow redirects). A dead req ends the
   flow with a note in `report.md`. Never fill a dead posting.
3. Re-run the org sweep: `python3 agent/org_sweep.py <posting-url>`. If a strictly
   better sibling role exists, surface it and ask which to fill BEFORE opening the
   browser.
4. Load `private/answers.yml`, the folder's `APPLY.md`, and `private/credentials.md`.

## THE WRITING GATE — runs before any prose is produced

**This is not optional and it is not a style note. It is a required stage.**

Every free-text answer — self-introduction, short answer, essay, cover letter,
"anything else you'd like us to know" — goes through this sequence:

1. **Draft** the answer to `applications/<folder>/answers/<field>.md`. On disk,
   not in your head, because an artifact makes a skipped step visible.
2. **Invoke the `humanizer` skill in embedded mode** on that file. Embedded mode
   is documented in the skill's own Invocation Modes section: it runs the
   draft → audit → final loop internally and returns only the final prose. It is
   built for exactly this, one skill calling another as a step.
3. **Run `./quality/check-slop.sh applications/<folder>/answers/<field>.md`.**
   It must exit 0. If it fails, fix what it names and run it again.
4. Only then type the text into the form.

**If the humanizer skill is unavailable, stop and say so. Do not write the text
yourself.** You will produce something that reads as generated, it will ship, and
neither the user nor the reviewer will catch it in time. A missing answer is
recoverable. A published one is not. The skill is vendored at
`.claude/skills/humanizer/` so absence means something is wrong with the checkout,
which is worth surfacing rather than working around.

**Voice.** The humanizer's Voice Calibration section says a user-supplied writing
sample outranks its own style rules, including the em-dash ban. If
`private/voice-sample.md` exists, pass it as the sample so the output sounds like
this candidate rather than like generic clean prose. If it does not exist, the
humanizer's defaults are correct and you should not invent a voice.

**What the gate cannot do.** `check-slop.sh` catches patterns. It cannot tell you
the writing is boring, or that you answered a different question than the one
asked, or that a claim is unsupported. Those are still yours to judge.

## Browser flow

5. Invoke the Chrome automation skill. If the extension is not connected, say so
   plainly and walk the manual flow with the drafted answers on screen. Never
   pretend a fill happened.
6. Open the posting. If the ATS needs an account:
   - Check `private/credentials.md` first and reuse an existing account.
   - Otherwise generate a password (`openssl rand -base64 18`) and store it BOTH
     ways, in this order: `security add-generic-password -s "ats-<company>" -a "$APPLICANT_EMAIL" -w "<pw>"`, then append a row to `private/credentials.md`.
     Put a pointer line at the top of the folder's `report.md`.
7. **Email verification.** When the ATS sends a link or one-time code, search the
   inbox for the newest message from the ATS domain, extract it, and continue.
   Applications always use the real address from `answers.yml`: recruiter replies
   and assessment invitations must land where the user actually reads.
8. Fill every page from the drafted answers. Dates, locations and descriptions come
   from `APPLY.md` verbatim. Do not improvise facts.

## Hard pauses — never proceed past these

- Any ASK-HUMAN-class question (outside business, outside employment, conflicts of
  interest). Stop, read it aloud, wait.
- Voluntary self-identification. Prefill from `answers.yml`, then pause to confirm.
- Legal attestations and terms consent. Pause.
- **The final review page. Always stop. The user clicks submit. No exceptions,
  including being asked to.**

## After the user submits

9. Stamp `report.md` with the timestamp and any confirmation number.
10. Flip the queue row in `applications/README.md`.
11. Mark the listing applied in `agent/state/seen.json`, or note it in `report.md`
    if the listing is not in state.
12. `git add` the changed files by name and commit `applied: <company> <role>`.

## Form-fill rules, each learned from a real failure

1. **Facts are copied, never retyped from memory.** Every name, title, number and
   date comes verbatim from the resume, `APPLY.md` or `answers.yml`. A live run
   once typed the wrong university name from memory. If a fact is not in a source
   file, ask. Do not reconstruct.
2. **After writing any field, re-read it from the page and diff against the
   source.** Paste artifacts are real: stray punctuation, merged words, dropped
   line starts.
3. **Prefer real keyboard input over programmatic value writes.** Some forms
   (Ashby among them) track their own internal state; setting `.value` from
   JavaScript fills the DOM while the form still believes the field is empty, and
   submit returns "missing required field" for everything you just typed.
4. **Never use select-all to clear a field.** If focus is not where you think, it
   selects the page and the next keystroke can submit the form. Verify
   `document.activeElement` first, or clear with repeated Backspace.
5. **Address fields by label, never by index.** Overlays and dropdowns inject their
   own inputs and shift every positional lookup. A phone number once landed in a
   city field this way.
6. **URL fields contain exactly one URL and nothing else.** Extra links ride in
   description text.
7. **Never enter a URL not verified live this session.** A guessed path is a dead
   link with the candidate's name on it.
8. **Confirm location before any slot-capped submission.** Some portals cap total
   applications per cycle. Spending one on the wrong city is unrecoverable.
9. **Dates match the attached PDF.** If memory and the resume disagree, the form
   matches the PDF and the discrepancy gets flagged for a joint fix later. One
   application must never contradict itself.
10. **A forked or extended open-source project is never "contributed to".** Unless
    there are merged upstream PRs, the honest framing is "extended a codebase I did
    not write". This is trivially checkable and the wrong word costs the page.

## Tone

Narrate which page you are on and what you are filling, briefly. The user is
watching, and that narration is how they catch a wrong answer before it is typed
rather than after.
