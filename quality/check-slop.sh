#!/usr/bin/env bash
# check-slop.sh — fail the build if application prose reads as AI-generated.
#
# This is the mechanical half of the humanizer rule. The skills instruct the
# model to run the humanizer in embedded mode before writing anything; this
# script is what catches it when that does not happen. Instructions are a
# promise. A non-zero exit is a mechanism.
#
# Modelled on resume/build.sh's leak gate: a list of literal patterns, checked
# against real output, loud on failure.
#
#   ./quality/check-slop.sh applications/acme/answers/*.md
#   ./quality/check-slop.sh --all
#   echo "some text" | ./quality/check-slop.sh -
#
# Exit 0 clean, 1 on any FAIL. WARN lines never fail the build; they are
# patterns with real false-positive rates and a human should judge them.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
warns=0

red()  { printf '\033[31m%s\033[0m\n' "$1"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$1"; }
grn()  { printf '\033[32m%s\033[0m\n' "$1"; }

# --- FAIL patterns -----------------------------------------------------------
# Each entry: <extended-regex>|<what it is>|<what to do instead>

FAIL_PATTERNS=(
  '—|em dash|Replace with a period, comma, colon, or parentheses. This is the single most reliable AI tell.'
  '–|en dash|Same as above. LaTeX date ranges are the only defensible use, and this is not LaTeX.'
  '\bnot just [^.]{1,60}\bbut\b|negative parallelism|"not just X but Y" is a construction almost nobody writes by hand. Say the thing.'
  "\\bisn't just\\b|negative parallelism|Drop the setup and make the claim directly."
  '\bnot only\b[^.]{1,60}\bbut also\b|negative parallelism|Two clauses joined plainly beat this.'
  '\bdelve\b|AI vocabulary|Use "look at", "go into", or cut the sentence.'
  '\btapestry\b|AI vocabulary|Almost always decorative. Cut it.'
  '\btestament to\b|AI vocabulary|States significance instead of showing it. Cut.'
  '\bunderscore(s|d)? (the|its|his|her|their)\b|AI vocabulary|"Underscores the importance of" is filler. Say what happened.'
  '\bpivotal\b|AI vocabulary|Puffery. Give the fact and let the reader rank it.'
  '\bshowcas(e|es|ing)\b|AI vocabulary|Use "shows" or name the thing.'
  '\bintricacies\b|AI vocabulary|Use "details" or be specific.'
  '\bvibrant\b|AI vocabulary|Promotional. Cut.'
  '\bboasts a\b|AI vocabulary|Copula avoidance. Use "has".'
  '\bnestled\b|AI vocabulary|Brochure language.'
  '\bseamless(ly)?\b|AI vocabulary|Says nothing measurable. Describe the behaviour.'
  '\brobust\b|AI vocabulary|Vague. Say what it survives.'
  '\bleverag(e|es|ing)\b|AI vocabulary|Use "use".'
  '\bfoster(ing)?\b|AI vocabulary|Corporate register.'
  '\bgarner(ed|ing)?\b|AI vocabulary|Use "got" or "received".'
  '\bcutting-edge\b|AI vocabulary|Marketing.'
  '\bGreat question\b|sycophantic opener|Chatbot artifact. Delete the sentence.'
  '\bI hope this helps\b|collaborative artifact|Chat correspondence pasted as content.'
  "\\bLet me know if\\b|collaborative artifact|Same. This is not a chat message."
  '\bCertainly[!,]|sycophantic opener|Delete.'
  "\\blet's dive in\\b|signposting|Announcing what you are about to do. Just do it."
  "\\bhere's what you need to know\\b|signposting|Tutorial-script cadence."
  '\bin order to\b|filler|Use "to".'
  '\bdue to the fact that\b|filler|Use "because".'
  '\bat this point in time\b|filler|Use "now".'
  '\bit is important to note that\b|filler|Delete the phrase and keep the fact.'
  '^[[:space:]]*[-*][[:space:]]+\*\*[^*]+:\*\*|inline-header bullet|The "- **Thing:** description" list is a chatbot shape. Write prose.'
  '\bthe (currency|architecture|language) of\b|aphorism formula|Sounds profound, says less than the plain claim.'
)

# --- WARN patterns -----------------------------------------------------------
WARN_PATTERNS=(
  '[“”]|curly quotes|Fine if your editor did it, a tell when stacked with others.'
  "[‘’]|curly apostrophes|Same."
  '\b[A-Za-z]+, [A-Za-z]+,? and [A-Za-z]+\b|possible rule of three|LLMs force ideas into threes. If the third item is padding, cut it.'
  '[🚀💡✅🔥✨]|emoji|Rarely right in an application.'
)

check_file() {
  local f="$1" label="$2" text
  text="$(cat "$f")"
  [ -z "${text// }" ] && return 0

  local hit
  for entry in "${FAIL_PATTERNS[@]}"; do
    IFS='|' read -r pat name fix <<< "$entry"
    if hit=$(printf '%s' "$text" | grep -nEi -- "$pat" 2>/dev/null); then
      red "  FAIL  $label — $name"
      printf '%s\n' "$hit" | head -3 | sed 's/^/          /'
      printf '        fix: %s\n\n' "$fix"
      fails=$((fails+1))
    fi
  done
  for entry in "${WARN_PATTERNS[@]}"; do
    IFS='|' read -r pat name fix <<< "$entry"
    if printf '%s' "$text" | grep -qEi -- "$pat" 2>/dev/null; then
      ylw "  warn  $label — $name"
      printf '        %s\n' "$fix"
      warns=$((warns+1))
    fi
  done
}

targets=()
if [ "${1:-}" = "--all" ]; then
  while IFS= read -r f; do targets+=("$f"); done < <(
    find "$ROOT/applications" -path '*/answers/*.md' -type f 2>/dev/null | sort
  )
  [ ${#targets[@]} -eq 0 ] && { grn "No drafted answers found under applications/*/answers/. Nothing to check."; exit 0; }
elif [ "${1:-}" = "-" ]; then
  tmp=$(mktemp); cat > "$tmp"; check_file "$tmp" "(stdin)"; rm -f "$tmp"
  [ $fails -gt 0 ] && { red "$fails failure(s)."; exit 1; }
  grn "Clean${warns:+ ($warns warning(s))}."; exit 0
elif [ $# -eq 0 ]; then
  echo "usage: check-slop.sh <file>... | --all | -" >&2; exit 2
else
  targets=("$@")
fi

echo "Checking ${#targets[@]} file(s) for AI writing patterns."
echo
for f in "${targets[@]}"; do
  [ -f "$f" ] || { red "  missing: $f"; fails=$((fails+1)); continue; }
  check_file "$f" "${f#"$ROOT"/}"
done

echo
if [ $fails -gt 0 ]; then
  red "$fails failure(s), $warns warning(s). This text is not ready to send."
  echo "Run the humanizer skill over it, then check again." >&2
  exit 1
fi
grn "Clean. $warns warning(s), none blocking."
