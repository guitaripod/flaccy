#!/usr/bin/env python3
"""Flaccy's trial-to-purchase funnel, read back from RevenueCat.

The trial and both paywalls are Flaccy's own, so RevenueCat's charts only see
the people who paid. `PurchaseFunnel` (flaccy/PurchaseFunnel.swift) mirrors
every step into subscriber attributes; this reads them back per first-seen
week and per lifetime price shown, so a price change is judged by paywall
views and checkouts rather than by a handful of sales.

Customers from builds before the funnel shipped carry no attributes, so their
funnel columns read "-"; retention (came back after a day, still around a week
later) comes from RevenueCat's own first/last-seen stamps and covers everyone.
For tracked customers the table also says whether any music of their own ever
reached the library, whether they tried the sample album, and whether their
trial started — which, for installs made since the trial began starting at the
first play of their own music, is the same as having played it; older installs
were stamped at launch. Debug builds are excluded.

Usage: source ~/.config/midgar/credentials.env && python3 scripts/rc-funnel.py ios|mac [--since YYYY-MM-DD]
"""
import argparse
import collections
import datetime as dt
import os
import sys
import time
import urllib.parse

import requests

PROJECTS = {"ios": "proj69262cb7", "mac": "proj5ef1fe52"}
BASE = "https://api.revenuecat.com/v2"
DAY_MS = 86_400_000
TRIAL_DAYS = 7


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=PROJECTS)
    parser.add_argument("--since", type=dt.date.fromisoformat, default=None)
    return parser.parse_args()


def get(session, url):
    """GET with RevenueCat's rate limit honoured instead of failing the run."""
    while True:
        response = session.get(url if url.startswith("http") else BASE + url)
        if response.status_code == 429:
            time.sleep(float(response.headers.get("Retry-After", "2")))
            continue
        response.raise_for_status()
        return response.json()


def paged(session, url):
    while url:
        page = get(session, url)
        yield from page["items"]
        url = page.get("next_page")


def load_customers(session, project, since):
    for customer in paged(session, f"/projects/{project}/customers?limit=1000"):
        first_seen = dt.datetime.fromtimestamp(customer["first_seen_at"] / 1000, dt.UTC)
        if since and first_seen.date() < since:
            continue
        base = f"/projects/{project}/customers/{urllib.parse.quote(customer['id'], safe='')}"
        attributes = {a["name"]: a["value"] for a in paged(session, base + "/attributes")}
        if attributes.get("build_config") == "debug":
            continue
        entitlements = [e["entitlement_id"] for e in paged(session, base + "/active_entitlements")]
        yield customer, first_seen, attributes, entitlements


def int_attribute(attributes, name):
    try:
        return int(attributes.get(name, "0"))
    except ValueError:
        return 0


def summarize(rows):
    cohorts = collections.defaultdict(collections.Counter)
    prices = collections.defaultdict(collections.Counter)
    for customer, first_seen, attributes, entitlements in rows:
        week = (first_seen.date() - dt.timedelta(days=first_seen.weekday())).isoformat()
        span = customer["last_seen_at"] - customer["first_seen_at"]
        instrumented = "build_config" in attributes
        paid = bool(entitlements)
        viewed = int_attribute(attributes, "paywall_views") > 0
        checkouts = int_attribute(attributes, "checkouts_started")
        c = cohorts[week]
        c["customers"] += 1
        c["returned"] += span >= DAY_MS
        c["outlasted_trial"] += span >= TRIAL_DAYS * DAY_MS
        c["paid"] += paid
        if instrumented:
            c["instrumented"] += 1
            c["music"] += attributes.get("library_tracks", "0") != "0"
            c["sample"] += attributes.get("played_sample") == "true"
            c["trial"] += "trial_started_at" in attributes
            c["saw_paywall"] += viewed
            c["checkout"] += checkouts > 0
            c["cancelled"] += int_attribute(attributes, "checkouts_cancelled") > 0
        if viewed:
            p = prices[attributes.get("paywall_last_price", "?")]
            p["viewers"] += 1
            p["checkout"] += checkouts > 0
            p["paid"] += paid
    return cohorts, prices


def table(headers, rows):
    widths = [max(len(str(x)) for x in column) for column in zip(headers, *rows)]
    for row in [headers, *rows]:
        print("  ".join(str(x).rjust(w) for x, w in zip(row, widths)))


def main():
    args = parse_args()
    key = os.environ.get(f"RC_SECRET_FLACCY_{args.platform.upper()}")
    if not key:
        sys.exit(f"RC_SECRET_FLACCY_{args.platform.upper()} is not set; source ~/.config/midgar/credentials.env")
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {key}"
    cohorts, prices = summarize(load_customers(session, PROJECTS[args.platform], args.since))

    def funnel(c, name):
        return c[name] if c["instrumented"] else "-"

    table(
        ["week", "new", "back>1d", "back>7d", "tracked", "music", "sample", "trial", "paywall", "checkout",
         "cancelled", "paid"],
        [
            [week, c["customers"], c["returned"], c["outlasted_trial"], c["instrumented"],
             funnel(c, "music"), funnel(c, "sample"), funnel(c, "trial"), funnel(c, "saw_paywall"),
             funnel(c, "checkout"), funnel(c, "cancelled"), c["paid"]]
            for week, c in sorted(cohorts.items())
        ],
    )
    if prices:
        print()
        table(
            ["lifetime price shown", "viewers", "checkout", "paid"],
            [[price, p["viewers"], p["checkout"], p["paid"]] for price, p in sorted(prices.items())],
        )


if __name__ == "__main__":
    main()
