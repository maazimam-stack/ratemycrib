"""Uptime and health check for ratemycrib.net (run by .github/workflows/health.yml every 6 hours).

Read-only: it loads the home page, reads one public review with the public key (the same thing every visitor
does) and asks the database for rmc_health() (yes/no facts and counts, nothing about any person; added by
supabase/hardening.sql). If something is wrong, or reviews are waiting for you, it opens or updates one GitHub
issue, so GitHub emails you. When everything is fine again it closes that issue.

Run locally without GitHub:  python3 tools/health_check.py --dry-run
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = "https://ratemycrib.net/"
TITLE = "RateMyCrib health check"
OWNER_MENTION = "@maazimam-stack"
# The version each supabase/*.sql file in this repo records when it runs (the date in its private.file_versions
# line). Change these together with the files; admin.html has the same list.
EXPECTED_SQL = {"growth": "2026-10-31", "mailing": "2026-10-31", "hardening": "2026-10-31"}


def http(url, data=None, headers=None, method=None, timeout=30):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers or {})
    except Exception as e:  # DNS, timeout, TLS
        return 0, f"{type(e).__name__}", {}


def api_keys():
    src = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    url = re.search(r"const SUPABASE_URL = '([^']+)'", src).group(1)
    key = re.search(r"const SUPABASE_KEY = '([^']+)'", src).group(1)
    return url, key


def check():
    problems, notices = [], []
    # 1. The site
    for attempt in range(2):
        status, body, _ = http(SITE, headers={"User-Agent": "RateMyCrib health check"})
        if status == 200 and "RateMyCrib" in body:
            break
        time.sleep(20)
    else:
        problems.append(f"The site didn't load properly (status {status or 'no response'}). Check GitHub Pages and the domain at Namecheap.")

    # 2. The database, the way visitors use it
    url, key = api_keys()
    h = {"apikey": key, "Authorization": "Bearer " + key, "User-Agent": "RateMyCrib health check"}
    status, body, _ = http(url + "/rest/v1/reviews_public?select=id&limit=1", headers=h)
    if status != 200:
        problems.append(f"Reviews couldn't be read from the database (status {status or 'no response'}). If Supabase paused the project, open the dashboard and restore it.")

    # 3. The database's own health facts
    status, body, _ = http(url + "/rest/v1/rpc/rmc_health", data=b"{}", headers={**h, "Content-Type": "application/json"}, method="POST")
    if status == 200:
        try:
            f = json.loads(body)
        except ValueError:
            f = {}
        if not f.get("review_rules"):
            problems.append("The review rules (supabase/growth.sql) aren't installed: badges, holds and the one-review-per-lease check are off. Run growth.sql.")
        if not f.get("write_limits"):
            problems.append("The limits on public writes (supabase/hardening.sql) aren't all installed. Run hardening.sql.")
        if not f.get("mailing_list"):
            problems.append("The mailing-list functions (supabase/mailing.sql) are missing. Run mailing.sql.")
        files = f.get("files") or {}
        behind = [k for k, v in EXPECTED_SQL.items() if files.get(k) != v]
        if behind:
            problems.append("The database is older than the site: " + ", ".join(k + ".sql" for k in behind) +
                            " not run in this version. Run growth.sql, then mailing.sql, then hardening.sql (docs/RUNBOOK.md, section 1).")
        if (f.get("scheduled_jobs") or 0) < 3:
            notices.append("Fewer than 3 scheduled jobs are running in the database. Turn on pg_cron (Database → Extensions), then run growth.sql and hardening.sql again.")
        if f.get("events_stopped"):
            problems.append("The database is over 450 MB, so usage events have stopped (reviews still work). See docs/RUNBOOK.md, section 5.")
        if (f.get("unverified_24h") or 0) >= 800:
            notices.append(f"{f['unverified_24h']} unverified reviews in the last day: new ones are refused at 1,000. Probably a flood: admin.html → Reviews & reports → Held.")
        if (f.get("db_mb") or 0) >= 400:
            problems.append(f"The database is {f.get('db_mb')} MB; Supabase's free plan stops at 500 MB.")
        elif (f.get("db_mb") or 0) >= 300:
            notices.append(f"The database is {f.get('db_mb')} MB of the free plan's 500 MB: time to check why (admin.html → Overview) and plan for more room.")
        if (f.get("held_over_a_day") or 0) > 0:
            n = f["held_over_a_day"]
            notices.append(f"{n} review{'s have' if n != 1 else ' has'} waited more than a day for your approval. admin.html → Reviews & reports.")
        if (f.get("open_reports") or 0) > 0:
            n = f["open_reports"]
            notices.append(f"{n} reported review{'s are' if n != 1 else ' is'} waiting. admin.html → Reviews & reports.")
    elif status == 404:
        notices.append("The database updates aren't in yet: run growth.sql, then mailing.sql, then hardening.sql (docs/RUNBOOK.md, section 1). This check then covers everything.")
    else:
        problems.append(f"The database health check failed (status {status or 'no response'}).")
    return problems, notices


def github(method, path, payload=None):
    token, repo = os.environ.get("GITHUB_TOKEN"), os.environ.get("GITHUB_REPOSITORY")
    data = json.dumps(payload).encode() if payload is not None else None
    status, body, _ = http(f"https://api.github.com/repos/{repo}{path}", data=data, method=method, headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "RateMyCrib health check",
        "Content-Type": "application/json"})
    return status, (json.loads(body) if body.strip().startswith(("{", "[")) else body)


def report(problems, notices):
    status, issues = github("GET", "/issues?state=open&per_page=50")
    if status != 200:
        print("Couldn't list issues:", status); return
    open_issue = next((i for i in issues if i.get("title") == TITLE and "pull_request" not in i), None)
    if not problems and not notices:
        if open_issue:
            github("POST", f"/issues/{open_issue['number']}/comments", {"body": "All clear: the site and database look fine now."})
            github("PATCH", f"/issues/{open_issue['number']}", {"state": "closed"})
        return
    lines = (["**Needs attention:**"] + [f"- {p}" for p in problems] if problems else []) + \
            (["", "**Waiting for you:**"] + [f"- {n}" for n in notices] if notices else [])
    body = "\n".join(lines).strip()
    if not open_issue:
        github("POST", "/issues", {"title": TITLE, "body": f"{OWNER_MENTION} the automatic check found something.\n\n{body}\n\n"
                                   "_This issue updates itself every 6 hours and closes when everything is fine. "
                                   "See docs/RUNBOOK.md for what to do._"})
        return
    status, comments = github("GET", f"/issues/{open_issue['number']}/comments?per_page=100")
    last = (comments[-1]["body"] if status == 200 and comments else open_issue.get("body") or "")
    if body not in last:  # only say it again when something changed
        github("POST", f"/issues/{open_issue['number']}/comments", {"body": body})


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="print the result instead of updating GitHub")
    a = ap.parse_args()
    problems, notices = check()
    print(json.dumps({"problems": problems, "notices": notices}, indent=1))
    if not a.dry_run and os.environ.get("GITHUB_TOKEN"):
        report(problems, notices)
    sys.exit(1 if problems else 0)
