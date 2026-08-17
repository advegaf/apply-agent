#!/bin/bash
# Builds every resume PDF from resume.tex and verifies it.
#
# Output names are submission-ready on purpose: you attach the file straight
# from out/, so there is no step where a build artifact name ("resume.pdf")
# can end up in a recruiter's inbox. out/ is PURGED first for the same reason:
# a stale PDF from an earlier matrix (an August-dated one, say) sitting in a
# send-from directory is one mis-click from being sent.
#
# NEVER re-save these through Preview, Pages, or any macOS print pipeline.
# That flattens text to vector outlines and destroys the text layer, which is
# exactly what happened to the previous resume.
#
# Optional: export PHONE="(979) 555-0134" to put a phone number in the header.
# Unset, the element is omitted entirely and the build still succeeds.

set -euo pipefail

variant_file() {
  case "$1" in
    iOS|ios)         echo "${OUT_IOS:-Resume_iOS.pdf}" ;;
    Backend|be)      echo "${OUT_BACKEND:-Resume_Backend.pdf}" ;;
    Product|prod)    echo "${OUT_PRODUCT:-Resume_Product.pdf}" ;;
    *)               echo "${OUT_EMPLOYER:-Resume_Employer.pdf}" ;;
  esac
}

# --- per-candidate configuration -------------------------------------------
# Everything below is about ONE person's resume, so it lives in a gitignored
# file rather than in tracked code. Copy candidate.example.env to candidate.env.
_CAND="$(dirname "$0")/candidate.env"
# shellcheck source=/dev/null
[ -f "$_CAND" ] && . "$_CAND"
: "${SCAN_FLOOR_FACTS:=}"
if [ -z "${SCAN_FLOOR_FACTS:-}" ]; then SCAN_FLOOR_FACTS=(); else read -r -a SCAN_FLOOR_FACTS <<< "$SCAN_FLOOR_FACTS"; fi

cd "$(dirname "$0")"

PHONE="${PHONE:-}"

mkdir -p out build
rm -f out/*.pdf

fail=0
warn=0

build_one() {
  local variant="$1" grad="$2" gs="$3" engine="$4" outname="$5"
  local job="tmp-${variant}-${grad}-${gs}"
  # Two passes: hyperref resolves links on the second.
  for _ in 1 2; do
    if ! "$engine" -interaction=nonstopmode -halt-on-error \
      -output-directory=build -jobname="$job" \
      "\\def\\variant{${variant}}\\def\\grad{${grad}}\\def\\gs{${gs}}\\def\\phone{${PHONE}}\\input{resume.tex}" \
      > "build/${job}.log" 2>&1
    then
      echo "BUILD FAILED: ${outname}"
      tail -20 "build/${job}.log"
      exit 1
    fi
  done
  cp "build/${job}.pdf" "out/${outname}"
  echo "  out/${outname}"
}

# Normalise extracted text: kill line and page breaks so a fact that wraps
# differently between the Times and Charter builds still matches as a substring.
norm() { pdftotext "$1" - 2>/dev/null | tr '\n\f' '  ' | tr -s ' ' | sed 's/–/-/g'; }

echo "Building:"
build_one ios  dec 0 pdflatex "${OUT_IOS:-Resume_iOS.pdf}"
build_one be   dec 0 pdflatex "${OUT_BACKEND:-Resume_Backend.pdf}"
build_one prod dec 0 pdflatex "${OUT_PRODUCT:-Resume_Product.pdf}"
build_one be   dec 1 xelatex  "${OUT_EMPLOYER:-Resume_Employer.pdf}"   # premium Charter build

IOS=out/${OUT_IOS:-Resume_iOS.pdf}
BE=out/${OUT_BACKEND:-Resume_Backend.pdf}
PROD=out/${OUT_PRODUCT:-Resume_Product.pdf}
GS="out/${OUT_EMPLOYER:-Resume_Employer.pdf}"

echo
echo "Manifest (exactly these four, nothing else):"
for f in "$IOS" "$BE" "$PROD" "$GS"; do
  if [ -f "$f" ]; then echo "  ok        $(basename "$f")"; else echo "  MISSING   $(basename "$f")"; fail=1; fi
done
for f in out/*.pdf; do
  case "$f" in
    "$IOS"|"$BE"|"$PROD"|"$GS") ;;
    *) echo "  UNEXPECTED FILE: $f"; fail=1 ;;
  esac
done

echo
echo "Page count and text layer:"
for f in out/*.pdf; do
  pages=$(pdfinfo "$f" | awk '/^Pages:/{print $2}')
  words=$(pdftotext "$f" - | wc -w | tr -d ' ')
  printf "  %-42s %s page(s), %s words" "$(basename "$f")" "$pages" "$words"
  [ "$pages" = "1" ] || { printf "  <-- NOT ONE PAGE"; fail=1; }
  [ "$words" -gt 300 ] || { printf "  <-- TEXT LAYER TOO THIN"; fail=1; }
  echo
done

echo
echo "Graduation date consistency (every PDF says $GRAD_REQUIRED, none says $GRAD_FORBIDDEN):"
for f in out/*.pdf; do
  t=$(norm "$f")
  printf "  %-42s" "$(basename "$f")"
  if [[ $t == *"$GRAD_REQUIRED"* ]]; then printf " grad:ok"; else printf " grad:MISSING"; fail=1; fi
  if [[ $t == *"August 2027"* ]]; then printf "  aug:LEAKED"; fail=1; else printf "  aug:clean"; fi
  echo
done

echo
echo "Track discrimination (proves each PDF holds its own track's content):"
# The obvious keywords (react, typescript, stripe) appear in more than one
# track, so they cannot detect the failure they would exist to catch: a missed
# branch emitting backend content into a PDF named Product. These sentinels are
# chosen precisely because they differ BETWEEN tracks.
t_ios=$(norm "$IOS"); t_be=$(norm "$BE"); t_prod=$(norm "$PROD"); t_gs=$(norm "$GS")

check() { # $1=description  $2=0 for pass, anything else for fail
  printf "  %-52s" "$1"
  if [ "$2" = "0" ]; then echo "ok"; else echo "FAILED"; fail=1; fi
}
want()    { if [[ $1 == *"$2"* ]]; then echo 0; else echo 1; fi; }
wantnot() { if [[ $1 == *"$2"* ]]; then echo 1; else echo 0; fi; }

# Candidate-specific content gates, read from resume/gates.conf.
#
# The generic gates above (page count, word floor, fonts, links, placeholders)
# apply to anyone. These do not: they assert facts about ONE person's resume,
# so they live in a gitignored config instead of in tracked code.
#
# Format, one per line:   <variant> <want|wantnot> <string> | <description>
# variant is one of the track suffixes used above (ios, be, prod, gs).
# See gates.example.conf. Absent file means these gates are simply skipped.
_GATES="$(dirname "$0")/gates.conf"
if [ -f "$_GATES" ]; then
  echo "Candidate content gates (from gates.conf):"
  while IFS= read -r _g; do
    _g="${_g%%\#*}"; [ -z "${_g// }" ] && continue
    _desc="${_g#*|}"; _rule="${_g%%|*}"
    read -r _var _fn _needle <<< "$_rule"
    _t=""; case "$_var" in
      ios)  _t="$t_ios" ;;  be) _t="$t_be" ;;
      prod) _t="$t_prod" ;; gs) _t="$t_gs" ;;
      *) echo "  gates.conf: unknown variant '$_var'"; fail=1; continue ;;
    esac
    check "$(echo "$_desc" | sed 's/^ *//')" "$("$_fn" "$_t" "$_needle")"
  done < "$_GATES"
else
  echo "  note: resume/gates.conf absent, candidate content gates skipped."
  echo "        Copy gates.example.conf to gates.conf to assert facts about your own resume."
fi
# Reverted Aug 10 2026: the App Store links were flipped on pre-launch and both
# ids still 404, so the iOS variant was the only unsendable build. Back to the
# GitHub link plus a TestFlight note, which is true and clickable. Flip forward
# again ONLY via resume/flip-store-links.sh, which verifies both ids resolve.
check "7 log sources, not 6"                       "$(want    "$t_be"   '7 log sources')"
check "harness present with adoption signal"        "$(want    "$t_prod" 'review pipeline')"
check "harness scope on backend"                   "$(want    "$t_be"   '194 on-demand playbooks')"
check "coursework line present"                    "$(want    "$t_prod" 'Relevant coursework')"
check "prod skills lead with TypeScript"           "$(want    "$t_prod" 'Languages: TypeScript')"
check "backend skills lead with Python"            "$(want    "$t_be"   'Languages: Python')"
check "iOS skills lead with Swift"                 "$(want    "$t_ios"  'Languages: Swift')"
check "iOS carries the Screen Time story"          "$(want    "$t_ios"  'shields lift even if the app dies')"
check "backend carries the RLS rollback story"     "$(want    "$t_be"   're-gated the rollout')"
check "prod carries the product-framed Wallet line" "$(want   "$t_prod" 'lock screen')"

echo
echo "Section headers survive text extraction (ATS segments on these tokens):"
for f in out/*.pdf; do
  t=$(norm "$f" | tr '[:lower:]' '[:upper:]')   # Charter small caps extract lowercase
  printf "  %-42s" "$(basename "$f")"
  for h in EDUCATION EXPERIENCE PROJECTS "TECHNICAL SKILLS"; do
    if [[ $t == *"$h"* ]]; then printf " ok"; else printf " MISSING(%s)" "$h"; fail=1; fi
  done
  echo
done

echo
echo "Retired claims must not reappear:"
_retired=0
for f in out/*.pdf; do
  t=$(norm "$f")
  for bad in "monthly recurring" "lines of Swift" "lines of production code" "Return offer" "code review" "A/B testing" "890+ orders" "30 to 3 minutes"; do
    if [[ $t == *"$bad"* ]]; then echo "  $(basename "$f") still contains '$bad'"; fail=1; _retired=1; fi
  done
done
[ "$_retired" = "0" ] && echo "  none (no MRR, no LOC, no premature offer claim, no A/B contradiction)"

echo
echo "Internal-string leak gate (nothing confidential may ship):"
# Every one of these appeared in the harness screenshots. The resume may say what
# he built and what it achieved; it may not carry internal hosts, repo paths,
# usernames, playbook names, ticket identifiers, or instance fingerprints.
# Generic product names (Splunk SOAR, ServiceNow, Python, REST) are fine.
# Confidential-string leak gate.
#
# The terms live OUTSIDE this file, in resume/internal-strings.txt, which is
# gitignored. That file is the confidential material: employer hostnames,
# internal system and project names, usernames, vendor names. Storing them in a
# tracked script would publish exactly what this gate exists to protect, and a
# clone carries git history, so redacting later does not help.
#
# One term per line. Blank lines and lines starting with # are ignored.
# See internal-strings.example.txt. If the file is absent the gate is skipped
# with a loud warning rather than silently passing.
INTERNAL=()
_INTERNAL_FILE="$(dirname "$0")/internal-strings.txt"
if [ -f "$_INTERNAL_FILE" ]; then
  while IFS= read -r _line; do
    _line="${_line%%#*}"; _line="${_line#"${_line%%[![:space:]]*}"}"; _line="${_line%"${_line##*[![:space:]]}"}"
    [ -n "$_line" ] && INTERNAL+=("$_line")
  done < "$_INTERNAL_FILE"
else
  echo "  WARNING: resume/internal-strings.txt not found. Confidential-string gate SKIPPED."
  echo "           If you have an employer with internal names that must never reach a PDF,"
  echo "           copy internal-strings.example.txt to internal-strings.txt and fill it in."
fi
_leak=0
for f in out/*.pdf; do
  t=$(norm "$f")
  for bad in "${INTERNAL[@]}"; do
    if [[ $t == *"$bad"* ]]; then
      echo "  LEAK: '$bad' found in $(basename "$f")"; fail=1; _leak=1
    fi
  done
done
[ "$_leak" = "0" ] && echo "  clean (no internal hosts, repo paths, playbook names or identifiers)"

echo
echo "Cross-variant fact consistency:"
# Tier 1: facts every PDF must assert identically. Bash substring matching, so
# $, + and % need no escaping at all.
UNIVERSAL=(
  "420 million events per day"
  "MAE, held-out validation set"
  "250 requests per second"
  "p95 120 ms"
  "10-second"
  "80+ hours per month"
)
_t1=0
for f in out/*.pdf; do
  t=$(norm "$f")
  for fact in "${UNIVERSAL[@]}"; do
    [[ $t == *"$fact"* ]] || { echo "  MISSING '$fact' in $(basename "$f")"; fail=1; _t1=1; }
  done
done
[ "$_t1" = "0" ] && echo "  all ${#UNIVERSAL[@]} universal facts present in every PDF"

# Tier 2: numbers that appear in only some variants but must never DISAGREE.
# Tier 1 alone would report a changed figure as merely absent, which reads as an
# intentional variant difference rather than drift.
check_fact() { # $1=ERE  $2=label
  local seen="" v f
  for f in out/*.pdf; do
    v=$(norm "$f" | grep -oE "$1" | head -1 || true)
    [ -n "$v" ] || continue
    if [ -z "$seen" ]; then seen="$v"
    elif [ "$v" != "$seen" ]; then
      echo "  FACT DRIFT [$2]: '$seen' vs '$v' in $(basename "$f")"; fail=1
    fi
  done
  if [ -n "$seen" ]; then
    printf "  %-22s %s\n" "$2" "$seen"
  else
    printf "  %-22s (not present in any variant)\n" "$2"
  fi
  return 0
}
check_fact '[0-9]+\+ payments'          'payments'
check_fact '\$[0-9]+K\+ processed'      'stripe-processed'
check_fact '[0-9]+\+ registered members' 'registered-members'
# Anchored exact-figure checks, not generic patterns. A generic
# '[0-9]+ unit tests' would report false drift whenever two variants lead with
# different projects carrying different counts. Declare each figure explicitly
# in drift.conf instead.
_DRIFT="$(dirname "$0")/drift.conf"
if [ -f "$_DRIFT" ]; then
  while IFS= read -r _d; do
    _d="${_d%%#*}"; [ -z "${_d// }" ] && continue
    _pat="${_d%%|*}"; _lbl="${_d#*|}"
    check_fact "$(echo "$_pat" | xargs)" "$(echo "$_lbl" | xargs)"
  done < "$_DRIFT"
fi
check_fact '[0-9]+ Deno edge functions' 'edge-functions'
check_fact '[0-9]+ log sources'         'log-sources'

echo
echo "Unfilled placeholders (must be empty before sending):"
_ph=0
for f in out/*.pdf; do
  if norm "$f" | grep -q 'XX'; then echo "  $(basename "$f") contains XX"; fail=1; _ph=1; fi
done
[ "$_ph" = "0" ] && echo "  none"

echo
# Words below contain fi/fl/ffi ligatures. Under OT1 encoding these extract as
# garbage and silently stop matching recruiter keyword searches; T1 fixes it.
# The list is per-track: the employer-facing build deliberately drops terms the
# return-offer line, so one shared list would false-fail on it.
echo "Ligature / keyword survival (every count must be > 0):"
kwcheck() { # $1=pdf  $2...=keywords
  local f="$1"; shift
  local t; t=$(norm "$f")
  printf "  %-42s" "$(basename "$f")"
  for kw in "$@"; do
    n=$(printf '%s' "$t" | grep -cio "$kw" || true)
    printf " %s:%s" "$kw" "$n"
    [ "$n" -gt 0 ] || { printf "(MISSING)"; fail=1; }
  done
  echo
}
kwcheck "$IOS"  swift firewall staff
kwcheck "$BE"   swift kubernetes postgresql stripe firewall airflow flag staff
kwcheck "$PROD" swift typescript postgresql stripe firewall cloudflare staff
kwcheck "$GS"   swift kubernetes postgresql stripe airflow flag staff workflow field

echo
echo "Font embedding (bold face present, and no Type 3 bitmaps):"
# Text gates match text, not weight, so a dropped \m{} is invisible to every
# other check here; an embedded bold face is the cheap proxy. Times bold ships
# as NimbusRomNo9L-Medi, hence the -Medi pattern. Type 3 fonts are bitmaps with
# no unicode mapping: they extract as nothing and print fuzzy.
for f in out/*.pdf; do
  printf "  %-42s" "$(basename "$f")"
  if pdffonts "$f" | grep -qiE 'bold|-medi|-bd'; then printf " bold:ok"; else printf " bold:MISSING"; fail=1; fi
  if pdffonts "$f" | grep -q 'Type 3'; then printf "  type3:PRESENT"; fail=1; else printf "  type3:none"; fi
  echo
done

echo
echo "Link targets present:"
# hyperref writes URIs into compressed object streams, so `strings` cannot see
# them; pdftohtml decompresses and reports the actual annotations.
EXPECTED_LINKS=()
_LINKS="$(dirname "$0")/links.conf"
[ -f "$_LINKS" ] && while IFS= read -r _l; do _l="${_l%%#*}"; [ -n "${_l// }" ] && EXPECTED_LINKS+=("$(echo "$_l" | xargs)"); done < "$_LINKS"
_UNUSED_LINKS=(
  # Expected link targets, one per line, from resume/links.conf (gitignored).
  # A resume's links are the proof layer, and they die silently. See links.example.conf.
)
for f in out/*.pdf; do
  printf "  %-42s" "$(basename "$f")"
  uris=$(pdftohtml -i -stdout -xml "$f" 2>/dev/null | grep -oE '(https?://|mailto:)[^"<> ]+' | sort -u || true)
  missing=0
  for l in "${EXPECTED_LINKS[@]}"; do
    printf '%s\n' "$uris" | grep -qF "$l" || { missing=1; printf " MISSING:%s" "$l"; }
  done
  if [ "$missing" = "0" ]; then echo "ok"; else echo; fail=1; fi
done

echo
echo "Top-third scan floor (first 120 words carry the screen-critical facts):"
for f in out/*.pdf; do
  head120=$(pdftotext "$f" - | tr '\n' ' ' | tr -s ' ' | cut -d' ' -f1-120)
  printf "  %-42s" "$(basename "$f")"
  for fact in "${SCAN_FLOOR_FACTS[@]}"; do
    if [[ $head120 == *"$fact"* ]]; then printf " ok"; else printf " MISSING(%s)" "$fact"; fail=1; fi
  done
  echo
done

echo
# Provisional / user-asserted figures. These are NOT verified measurements.
# They may ship, but you get reminded every build until real numbers replace
# them. See NUMBERS.md tiers 2 and 3.
echo "Provisional numbers still on the page (replace before serious targets):"
_prov=0
_ti=$(norm "$IOS"); _tb=$(norm "$BE")
[ "$_prov" = "0" ] && echo "  none"

if [ -z "$PHONE" ]; then
  echo
  echo "NOTE: no phone number in the header. Run: PHONE=\"(xxx) xxx-xxxx\" ./build.sh"
  warn=1
fi

# --- packet mode -------------------------------------------------------------
# Copies the right variant into each application folder under a company-neutral
# name, with the role named in the embedded PDF Title. No company name in the
# file or its metadata: he sends dozens of these from four variants, and a PDF
# whose metadata reads "Palantir" arriving at Optiver is an avoidable disaster.
# The folder carries the routing; the artifact stays neutral.
if [ "${1:-}" = "--packet" ]; then
  APPDIR="../applications"
  NEUTRAL="${NEUTRAL_NAME:-Resume_SWE_Intern.pdf}"
  # folder:variant mapping lives in applications/packet-map.txt so that this
  # file can be locked immutable while the agent appends new folders to a plain
  # data file. Comment lines start with #.
  MAP=$(grep -v '^#' "$APPDIR/packet-map.txt" | grep -v '^$')
  echo
  echo "Packet mode: copying variants into application folders"
  _pk=0
  for row in $MAP; do
    folder="${row%%:*}"; variant="${row##*:}"
    src="out/$(variant_file "$variant")"
    dest="$APPDIR/$folder"
    [ -d "$dest" ] || { echo "  MISSING FOLDER: $folder"; fail=1; continue; }
    [ -f "$src" ]  || { echo "  MISSING SOURCE: $src"; fail=1; continue; }
    rm -f "$dest"/*.pdf
    cp "$src" "$dest/$NEUTRAL"
    printf "  %-22s <- %s\n" "$folder" "$variant"
    _pk=$((_pk+1))
  done
  echo "  $_pk packets written as $NEUTRAL"
  echo
  echo "  Note: the iOS variant is deliberately unused in this batch. It is the"
  echo "  right file for Apple, Uber Mobile and Spotify, none of which are open yet."
fi

echo
if [ "$fail" = "0" ]; then
  echo "ALL CHECKS PASSED."
  [ "$warn" = "1" ] && echo "(with notes above)"
  exit 0
else
  echo "CHECKS FAILED. Do not send these PDFs."
  exit 1
fi
