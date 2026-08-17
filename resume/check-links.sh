#!/bin/bash
# Pre-send link liveness check. Run this before an application batch.
#
# Separate from build.sh on purpose: build.sh must work offline and stay fast,
# and it only verifies that the expected URLs are PRESENT in the PDF. This
# script verifies they actually RESOLVE. A dead link on a resume is worse than
# no link, because a recruiter who clicks it learns something about your
# attention to detail that you did not intend to tell them.

set -uo pipefail
cd "$(dirname "$0")"

fail=0
echo "Checking every URL embedded in out/*.pdf:"

urls=$(for f in out/*.pdf; do
  pdftohtml -i -stdout -xml "$f" 2>/dev/null | grep -oE '(https?://|mailto:)[^"<> ]+'
done | sort -u)

for u in $urls; do
  case "$u" in
    mailto:*)
      printf "  %-62s %s\n" "$u" "skipped (mail)"
      continue
      ;;
  esac
  code=$(curl -sI -o /dev/null -w '%{http_code}' -L --max-time 12 \
    -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' "$u" 2>/dev/null || echo "000")
  printf "  %-62s %s" "$u" "$code"
  case "$code" in
    2*|3*) echo "" ;;
    403)
      # LinkedIn blocks automated requests outright. A 403 from them says
      # nothing about whether the profile exists, so it is not a failure here.
      # Check it by hand once instead of pretending this script can.
      case "$u" in
        *linkedin.com*) echo "   (bot-blocked; verify by hand)" ;;
        *)              echo "   <-- DEAD"; fail=1 ;;
      esac
      ;;
    *) echo "   <-- DEAD"; fail=1 ;;
  esac
done

echo
if [ "$fail" = "0" ]; then
  echo "All links resolve."
else
  echo "DEAD LINKS FOUND. Fix before sending."
  exit 1
fi
