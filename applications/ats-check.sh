#!/bin/bash
# Keyword coverage: does the resume in this folder use the words the employer used?
#
# What this is: it extracts skill and tool terms from the role's real job
# description and reports which ones appear in the resume text and which do not.
#
# What this is NOT: a score, a prediction, or advice to add anything. A term
# showing up as MISSING is information, not an instruction. Padding a resume
# with a keyword because a posting used it is how people end up unable to answer
# a question about their own page, and this resume's whole value is that every
# line survives being drilled. Decide each gap yourself.
#
# Usage:  ./ats-check.sh                 check every folder
#         ./ats-check.sh palantir-fdse   check one

set -uo pipefail
cd "$(dirname "$0")"

# Terms worth checking for. Extended regex, matched case-insensitively against
# both the JD and the resume. Add to this list as new roles bring new vocabulary.
TERMS=(
  "python" "java" "javascript" "typescript" "c\+\+" "\bc#" "\bgo\b" "golang" "rust"
  "swift" "objective-c" "kotlin" "scala" "perl" "haskell" "clojure" "lua" "ruby"
  "sql" "nosql" "postgres" "mysql" "redis"
  "react" "angular" "vue" "node" "front-end|frontend" "full-stack|fullstack"
  "aws" "azure" "gcp" "cloud" "kubernetes" "docker" "terraform" "jenkins" "microservices"
  "rest|restful" "api" "distributed systems" "storage systems" "cloud infrastructure"
  "data structures" "algorithms" "computer architecture" "networks" "operating systems"
  "machine learning|ml\b" "\bai\b" "llm" "tensorflow" "pytorch" "scikit"
  "debugging" "performance optimization|performance" "unit test|unit testing|testing"
  "documentation" "automation" "observability" "monitoring" "security" "privacy"
  "data protection" "governance" "production" "scale" "open source"
  "communication" "collaborat" "problem solving|problem-solving" "ownership"
)

RESUME_TEXT=""
check_folder() {
  local d="$1"
  local jd="$d/jd.txt"
  local pdf
  pdf=$(find "$d" -maxdepth 1 -name '*.pdf' | head -1)

  echo "=============================================================="
  echo "  $d"
  echo "=============================================================="

  if [ ! -f "$jd" ]; then echo "  no jd.txt, skipping"; echo; return 0; fi
  if grep -q "PASTE THE REQUIREMENTS SECTION HERE" "$jd"; then
    echo "  SKIPPED: jd.txt is still a stub."
    echo "  Paste the real requirements text in, then re-run. Reporting a clean"
    echo "  result against an empty JD would be worse than reporting nothing."
    echo; return 0
  fi
  if [ -z "$pdf" ]; then echo "  no resume PDF in this folder, skipping"; echo; return 0; fi

  local jd_l res_l matched=() missing=()
  jd_l=$(tr '[:upper:]' '[:lower:]' < "$jd")
  res_l=$(pdftotext "$pdf" - 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')

  for t in "${TERMS[@]}"; do
    # Only consider terms the JD actually asks for.
    if printf '%s' "$jd_l" | grep -qE "$t"; then
      if printf '%s' "$res_l" | grep -qE "$t"; then
        matched+=("$t")
      else
        missing+=("$t")
      fi
    fi
  done

  local total=$(( ${#matched[@]} + ${#missing[@]} ))
  echo "  JD asks for ${total} tracked terms. Resume uses ${#matched[@]}."
  echo
  if [ ${#matched[@]} -gt 0 ]; then
    echo "  PRESENT:"
    printf '    %s\n' "${matched[@]}" | sed 's/|/ or /g; s/\\b//g; s/\\+/+/g'
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo
    echo "  NOT ON THE PAGE (decide each one; do not pad):"
    printf '    %s\n' "${missing[@]}" | sed 's/|/ or /g; s/\\b//g; s/\\+/+/g'
  fi
  echo

  # Graduation-window sanity, the thing that actually auto-rejects.
  if printf '%s' "$jd_l" | grep -qE "graduat"; then
    echo "  GRADUATION LANGUAGE IN JD:"
    grep -iE "graduat" "$jd" | sed 's/^/    /'
    printf '%s' "$res_l" | grep -q "december 2027" \
      && echo "    resume says: December 2027" \
      || echo "    WARNING: resume does not state December 2027"
    echo
  fi
  return 0
}

if [ $# -ge 1 ]; then
  check_folder "${1%/}"
else
  for d in */; do check_folder "${d%/}"; done
fi

echo "Reminder: MISSING is information, not an instruction. Only claim what you"
echo "have actually done. A gap you can explain beats a keyword you cannot."
