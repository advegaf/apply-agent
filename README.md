# apply-agent

A job-application system that watches for new postings, prepares a folder per role
with the right resume variant and a real job description, drafts every form answer
from one source of truth, and fills the application in your browser while you
review and click submit.

It never submits for you. That is deliberate and it is not going to change.

## What it actually does

**Watches.** A scheduled job diffs a listings feed twice a day, filters to your
term and excludes, and prepares a folder for anything new.

**Prepares.** Per role: fetches the real job description from the ATS, checks your
resume's keyword coverage against it, sweeps the company's other openings in case a
sibling role fits better, picks a resume variant, and drafts every form answer from
`private/answers.yml`.

**Writes.** Free-text answers go through the humanizer before anything is typed,
then through a lint gate that fails on the patterns that make writing read as
generated. See "The writing gate" below.

**Fills.** `/apply <folder>` drives your real Chrome, pausing at every legal
attestation and stopping dead at the review page.

## Install

```bash
git clone <your-fork> apply-agent && cd apply-agent
claude
> /intake
```

`/intake` reads your existing resume, interrogates every number on it, walks the
knockout questions, captures a writing sample, and generates your `private/`
directory. Budget 30 to 60 minutes. It is the whole difference between a repo you
cloned and a repo you use.

Then `cp agent/config.env.example agent/config.env`, set your feed and excludes,
run `python3 agent/fetch_diff.py --baseline`, and optionally install the scheduler.

## The two ideas this is built on

**A number goes on the page only if you can reproduce it.** `private/NUMBERS.md`
holds every figure on your resume next to the command, dashboard or document that
produces it. Figures that survive that test also survive an interview. Figures that
do not come off the page, and `build.sh` warns on every build until they do. The
point is not honesty as a virtue. It is that the alternative is sitting in a room
unable to explain your own resume.

**A missing keyword is information, not an instruction.** The ATS checker reports
what a job description asks for and your resume does not say. It never edits your
resume and never suggests adding a term. Padding a resume with a keyword because a
posting used it is how people end up unable to answer a question about their own
page.

## The writing gate

Every free-text answer runs this sequence before it reaches a form:

1. Draft to `applications/<folder>/answers/<field>.md`
2. `humanizer` skill, embedded mode, over that file
3. `./quality/check-slop.sh` must exit 0
4. Only then does it get typed

Step 3 is the part that matters. Steps 1 and 2 are instructions to a model, and
instructions get skipped under time pressure, which is exactly when slop appears.
`check-slop.sh` is a script that exits non-zero on em dashes, negative parallelism,
the AI vocabulary list, sycophantic openers, aphorism formulas and inline-header
bullets. It is modelled on the confidential-string gate in `build.sh`: a list of
literal patterns, checked against real output, loud on failure.

It cannot tell you the writing is boring or that you answered the wrong question.
That is still yours.

## Layout

```
agent/          watcher, JD fetcher, org sweep, pipeline, model prompts
resume/         one .tex, several variants, and the gates that verify them
applications/   one folder per role, prepared for you
quality/        the slop gate
private/        everything about you. Never committed.
.claude/skills/ intake, apply, and a vendored copy of humanizer
```

## Things worth knowing before you trust it

**The scheduler runs unattended; the applications do not.** Preparation is
automated because it is mechanical. Submission is not, because applications end in
legal attestations about work authorization, outside business activity and
conflicts of interest. Those are yours to sign.

**`private/` is gitignored for a reason.** It holds your address, your GPA, your
offer status, and if you fill in `INTERVIEW-DEFENSE.md` properly, a list of known
weaknesses in your own live systems. Do not commit it. Do not share it.

**`resume/internal-strings.txt` is the confidential list itself.** If you have an
employer with internal system names, that file stops them reaching a PDF. It is
gitignored, and it must stay that way: git history travels with a clone, so
redacting later does not help.

## Credits

`humanizer` is vendored under `.claude/skills/humanizer/`, MIT licensed, from
https://github.com/blader/humanizer
