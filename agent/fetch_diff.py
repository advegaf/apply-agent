#!/usr/bin/env python3
"""Fetch SimplifyJobs listings.json, filter, diff against seen-state.

Stdlib only. Writes agent/state/new_matches.json for the model step.

Modes:
  --baseline   mark every currently-matching listing as seen, create no matches
  (default)    diff and emit new matches

The state is keyed by the listing UUID, which survives README reordering and
format churn. Reposts under fresh UUIDs are deduped by (company, normalized
title, canonical URL).
"""
import json
import os, os, re, socket, sys, tempfile, time, urllib.error, urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_DIR = os.path.join(ROOT, "agent", "state")
STATE = os.path.join(STATE_DIR, "seen.json")
LATEST = os.path.join(STATE_DIR, "listings-latest.json")
ETAG = os.path.join(STATE_DIR, "listings.etag")
OUT = os.path.join(STATE_DIR, "new_matches.json")

URL = os.environ.get("LISTINGS_URL",
    "https://raw.githubusercontent.com/SimplifyJobs/Summer2027-Internships"
    "/dev/.github/scripts/listings.json")
TERM = os.environ.get("TERM_FILTER", "Summer 2027")
# Companies you will not work for. Yours, not anyone else's. Set in agent/config.env.
EXCLUDED_COMPANIES = {
    c.strip().lower() for c in os.environ.get("EXCLUDED_COMPANIES", "").split(",") if c.strip()
}

# Transient network failures must not end a run. On Aug 10 2026 the 09:00 slot
# coalesced to 09:13 on wake, hit DNS before the network was up, and died on the
# first attempt: "socket.gaierror: nodename nor servname provided". Three new
# listings went undetected for a day and the log looked healthy.
RETRY_DELAYS = (15, 45, 90, 180)  # 5 attempts, ~5.5 minutes of patience
QUANT_TITLE = re.compile(r"engineer|developer|software", re.I)

def log(msg):
    print(f"[fetch_diff] {msg}", file=sys.stderr)

def _get():
    """One attempt. Returns (data, etag), or None for a 304 ETag hit."""
    req = urllib.request.Request(URL, headers={"User-Agent": "apply-agent/1.0"})
    if os.path.exists(ETAG):
        with open(ETAG) as f:
            req.add_header("If-None-Match", f.read().strip())
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read(), r.headers.get("ETag", "")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return None
        # A 4xx/5xx from the server is a real answer, not a flaky link. Do not
        # retry it and do not let it masquerade as a network blip.
        raise

def fetch():
    # Retry ONLY the transient transport failures. HTTPError and SCHEMA CHANGED
    # stay loud and immediate: those mean something actually changed and a retry
    # would just delay the alarm.
    last = None
    for attempt in range(len(RETRY_DELAYS) + 1):
        try:
            got = _get()
            break
        except (urllib.error.URLError, socket.gaierror, socket.timeout, TimeoutError) as e:
            last = e
            if attempt == len(RETRY_DELAYS):
                log(f"network unreachable after {attempt + 1} attempts: {e}")
                raise
            delay = RETRY_DELAYS[attempt]
            log(f"network error ({e}); retry {attempt + 1}/{len(RETRY_DELAYS)} in {delay}s")
            time.sleep(delay)
    if got is None:
        log("not modified (ETag hit); using cached listings")
        with open(LATEST, "rb") as f:
            return json.load(f)
    data, etag = got
    listings = json.loads(data)
    # Schema sanity: a parse "success" on changed structure must be loud, not
    # a silently empty diff.
    if not isinstance(listings, list) or len(listings) < 1000:
        raise SystemExit(f"SCHEMA CHANGED: got {type(listings)} len {len(listings) if isinstance(listings, list) else 'n/a'}")
    probe = listings[0]
    for key in ("id", "company_name", "title", "active", "url"):
        if key not in probe:
            raise SystemExit(f"SCHEMA CHANGED: missing key {key}")
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(LATEST, "wb") as f:
        f.write(data)
    if etag:
        with open(ETAG, "w") as f:
            f.write(etag)
    return listings

def canonical_url(u):
    return re.sub(r"[?&](utm_[^=&]+|ref)=[^&]*", "", u or "").rstrip("?&")

def dedupe_key(l):
    title = re.sub(r"\s+", " ", (l.get("title") or "").lower()).strip()
    return f"{(l.get('company_name') or '').lower()}|{title}|{canonical_url(l.get('url'))}"

def matches(l):
    if not l.get("active") or not l.get("is_visible", True):
        return False
    if TERM not in (l.get("terms") or []):
        return False
    company = (l.get("company_name") or "").strip().lower()
    if company in EXCLUDED_COMPANIES:
        return False
    cat = (l.get("category") or "").strip()
    if cat in ("Software", "Software Engineering"):
        return True
    if cat == "Quant" and QUANT_TITLE.search(l.get("title") or ""):
        return True
    return False

def load_state():
    if os.path.exists(STATE):
        with open(STATE) as f:
            return json.load(f)
    return {"schema": 1, "last_run": None, "listings": {}}

def save_state(state):
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    state["last_run"] = now
    # save_state runs only after a fetch+diff actually succeeded, so this is the
    # honest "the agent worked" timestamp. The wrapper reads it to tell a quiet
    # day apart from a dead agent, which is the distinction that failed on
    # Aug 10 2026 when a whole day of runs looked identical to "nothing new".
    state["last_success"] = now
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix="seen.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, STATE)

def main():
    baseline = "--baseline" in sys.argv
    listings = fetch()
    state = load_state()
    seen = state["listings"]
    seen_dedupe = {dedupe_key_from_record(r) for r in seen.values()}

    current = [l for l in listings if matches(l)]
    log(f"{len(listings)} total rows, {len(current)} match filters")

    new = []
    for l in current:
        lid = l["id"]
        if lid in seen:
            continue
        record = {
            "first_seen": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "company": l.get("company_name"),
            "title": l.get("title"),
            "url": l.get("url"),
            "locations": l.get("locations"),
            "category": l.get("category"),
            "date_posted": l.get("date_posted"),
            "status": "baseline-seen" if baseline else "new",
            "folder": None,
            "note": "",
        }
        if not baseline and dedupe_key(l) in seen_dedupe:
            record["status"] = "skipped-repost"
            record["note"] = "same company+title+url already seen under another id"
            seen[lid] = record
            continue
        seen[lid] = record
        seen_dedupe.add(dedupe_key(l))
        if not baseline:
            new.append({"id": lid, **{k: record[k] for k in ("company", "title", "url", "locations", "category", "date_posted")}})

    save_state(state)
    with open(OUT, "w") as f:
        json.dump(new, f, indent=1)
    log(f"baseline={baseline} new={len(new)} state={len(seen)} entries")
    print(len(new))

def dedupe_key_from_record(r):
    title = re.sub(r"\s+", " ", (r.get("title") or "").lower()).strip()
    return f"{(r.get('company') or '').lower()}|{title}|{canonical_url(r.get('url'))}"

if __name__ == "__main__":
    main()
