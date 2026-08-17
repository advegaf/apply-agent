#!/usr/bin/env python3
"""List a company's other open roles from its ATS board, API-backed only.

Usage:  org_sweep.py <listing-url> [--json]

Given one posting URL, detect the ATS and org token, pull the org's full
posting list, and filter to roles plausibly relevant to a Summer 2027 SWE
intern candidate. Greenhouse, Lever and Ashby have public listing APIs and are
handled. Workday, Oracle, iCIMS and custom sites (lifeattiktok.com) have no
public org-listing API; for those the output is a single manual-check note,
never a scrape of the site being applied through.

Stdlib only. Read-only. Exit 0 always (a sweep failure is a note, not a crash).
"""
import json, re, sys, urllib.request

INTERN_PAT = re.compile(r"intern|co-?op|university|campus|new grad|graduate", re.I)
TERM_PAT = re.compile(r"2027|summer", re.I)

def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "apply-agent/1.0"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read())

def sweep_greenhouse(url):
    m = re.search(r"greenhouse\.io/(?:embed/job_app\?for=)?([\w-]+)", url) or \
        re.search(r"(?:boards|job-boards)\.greenhouse\.io/([\w-]+)", url)
    if not m:
        return None
    board = m.group(1)
    data = get_json(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs")
    out = []
    for j in data.get("jobs", []):
        title = j.get("title", "")
        if INTERN_PAT.search(title):
            out.append({"title": title,
                        "location": (j.get("location") or {}).get("name", ""),
                        "url": j.get("absolute_url", "")})
    return {"ats": "greenhouse", "org": board, "roles": out}

def sweep_lever(url):
    m = re.search(r"jobs\.lever\.co/([\w-]+)", url)
    if not m:
        return None
    org = m.group(1)
    data = get_json(f"https://api.lever.co/v0/postings/{org}?mode=json")
    out = []
    for j in data:
        title = j.get("text", "")
        if INTERN_PAT.search(title):
            out.append({"title": title,
                        "location": (j.get("categories") or {}).get("location", ""),
                        "url": j.get("hostedUrl", "")})
    return {"ats": "lever", "org": org, "roles": out}

def sweep_ashby(url):
    m = re.search(r"jobs\.ashbyhq\.com/([\w-]+)", url)
    if not m:
        return None
    org = m.group(1)
    data = get_json(f"https://api.ashbyhq.com/posting-api/job-board/{org}")
    out = []
    for j in data.get("jobs", []):
        title = j.get("title", "")
        if INTERN_PAT.search(title):
            out.append({"title": title,
                        "location": j.get("location", ""),
                        "url": j.get("jobUrl", "") or j.get("applyUrl", "")})
    return {"ats": "ashby", "org": org, "roles": out}

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: org_sweep.py <listing-url>"}))
        return
    url = sys.argv[1]
    result = None
    for fn in (sweep_greenhouse, sweep_lever, sweep_ashby):
        try:
            result = fn(url)
            if result:
                break
        except Exception as e:
            result = {"ats": fn.__name__.replace("sweep_", ""),
                      "error": f"sweep failed: {e}", "roles": []}
            break
    if result is None:
        result = {"ats": "unsupported",
                  "note": ("No public org-listing API for this ATS. Check the "
                           "company's careers board manually while applying; do "
                           "not scrape the site you are applying through."),
                  "roles": []}
    # Rank Summer-2027-relevant first, so the judgment step reads the best first.
    if result.get("roles"):
        result["roles"].sort(key=lambda r: 0 if TERM_PAT.search(r["title"]) else 1)
    print(json.dumps(result, indent=1))

if __name__ == "__main__":
    main()
