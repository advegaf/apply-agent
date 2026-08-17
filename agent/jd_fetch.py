#!/usr/bin/env python3
"""Fetch job-description text per listing, best-effort per ATS.

For each entry in agent/state/new_matches.json, writes:
  agent/state/jd-cache/<id>.txt      the JD text, or the stub template
  agent/state/jd-cache/<id>.status   fetched | stub | dead

The stub GUARANTEE: every listing gets a jd.txt-ready file no matter what.
Fetched text only replaces the stub when it passes a sanity floor (>80 words
and mentions qualifications/requirements/responsibilities), because a bogus
"clean" ATS report against boilerplate is worse than an honest stub. The stub
carries the literal sentinel line ats-check.sh greps for.
"""
import html, json, os, re, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "agent", "state", "jd-cache")
MATCHES = os.path.join(ROOT, "agent", "state", "new_matches.json")

STUB = """PASTE THE REQUIREMENTS SECTION HERE.

This posting could not be fetched server-side ({reason}).
URL: {url}

Open the posting, copy the Requirements / Qualifications / Skills sections
verbatim, replace this text, then run ats-check.sh for this folder.
"""

DEAD_PAT = re.compile(r"job (is )?no longer (available|active|posted)|position has been filled|this job is closed", re.I)

def get(url, timeout=45):
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "Accept": "text/html,application/json",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")

def strip_html(s):
    s = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", s, flags=re.S | re.I)
    s = re.sub(r"<br\s*/?>|</p>|</li>|</div>", "\n", s, flags=re.I)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    s = re.sub(r"[ \t]+", " ", s)
    return re.sub(r"\n{3,}", "\n\n", s).strip()

def sane(text):
    if not text or len(text.split()) < 80:
        return False
    return bool(re.search(r"qualif|require|responsib|skill", text, re.I))

def try_greenhouse(url):
    m = re.search(r"greenhouse\.io/(?:embed/job_app\?for=)?([\w-]+)/jobs/(\d+)", url) or \
        re.search(r"boards\.greenhouse\.io/([\w-]+)/jobs/(\d+)", url) or \
        re.search(r"job-boards\.greenhouse\.io/([\w-]+)/jobs/(\d+)", url)
    if not m:
        return None
    board, jid = m.group(1), m.group(2)
    data = json.loads(get(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs/{jid}"))
    return strip_html(data.get("content", ""))

def try_lever(url):
    m = re.search(r"jobs\.lever\.co/([\w-]+)/([\w-]{36})", url)
    if not m:
        return None
    co, pid = m.group(1), m.group(2)
    data = json.loads(get(f"https://api.lever.co/v0/postings/{co}/{pid}"))
    parts = [strip_html(data.get("description", ""))]
    for lst in data.get("lists", []):
        parts.append(lst.get("text", ""))
        parts.append(strip_html(lst.get("content", "")))
    parts.append(strip_html(data.get("additional", "")))
    return "\n".join(p for p in parts if p)

def try_ashby(url):
    m = re.search(r"jobs\.ashbyhq\.com/([\w-]+)/([\w-]{36})", url)
    if not m:
        return None
    org, jid = m.group(1), m.group(2)
    data = json.loads(get(f"https://api.ashbyhq.com/posting-api/job-board/{org}?includeCompensation=true"))
    for job in data.get("jobs", []):
        if job.get("id") == jid:
            return strip_html(job.get("descriptionHtml", ""))
    return None

def try_workday(url):
    m = re.search(r"https://([\w-]+)\.wd\d+\.myworkdayjobs\.com/(?:[a-z-]+/)?([\w_-]+)/job/[^/]+/([\w_%-]+)", url)
    if not m:
        return None
    tenant_host = url.split("/job/")[0]
    path = url.split(tenant_host)[1]
    m2 = re.match(r"https://([\w-]+)\.(wd\d+)\.myworkdayjobs\.com/([^/]+)", tenant_host)
    if not m2:
        return None
    tenant, wd, site = m2.group(1), m2.group(2), m2.group(3)
    cxs = f"https://{tenant}.{wd}.myworkdayjobs.com/wday/cxs/{tenant}/{site}{path.split('?')[0]}"
    data = json.loads(get(cxs))
    info = data.get("jobPostingInfo", {})
    text = strip_html(info.get("jobDescription", ""))
    return text or None

def try_generic(url):
    page = get(url)
    if DEAD_PAT.search(page):
        return "DEAD"
    return strip_html(page)

def fetch_one(url):
    for name, fn in (("greenhouse", try_greenhouse), ("lever", try_lever),
                     ("ashby", try_ashby), ("workday", try_workday)):
        try:
            text = fn(url)
            if text == "DEAD":
                return "dead", ""
            if text and sane(text):
                return "fetched", text
        except Exception as e:
            print(f"[jd_fetch]   {name} path failed: {e}", file=sys.stderr)
    try:
        text = try_generic(url)
        if text == "DEAD":
            return "dead", ""
        if text and sane(text):
            # Generic scrapes carry nav junk; keep, the model trims into jd.txt.
            return "fetched", text
    except Exception as e:
        print(f"[jd_fetch]   generic failed: {e}", file=sys.stderr)
    return "stub", ""

def main():
    os.makedirs(CACHE, exist_ok=True)
    with open(MATCHES) as f:
        matches = json.load(f)
    counts = {"fetched": 0, "stub": 0, "dead": 0}
    for m in matches:
        lid, url = m["id"], m.get("url", "")
        status, text = fetch_one(url) if url else ("stub", "")
        if status != "fetched":
            reason = "the posting appears to be closed" if status == "dead" else "JS-rendered or blocked"
            text = STUB.format(reason=reason, url=url)
        with open(os.path.join(CACHE, f"{lid}.txt"), "w") as f:
            f.write(text)
        with open(os.path.join(CACHE, f"{lid}.status"), "w") as f:
            f.write(status)
        counts[status] += 1
        print(f"[jd_fetch] {m['company']} — {m['title'][:50]}: {status}", file=sys.stderr)
    print(json.dumps(counts))

if __name__ == "__main__":
    main()
