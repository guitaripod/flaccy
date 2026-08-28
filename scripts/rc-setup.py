#!/usr/bin/env python3
"""Idempotent RevenueCat (v2) setup for Flaccy.

iOS and Mac are separate SKUs with separate RevenueCat projects. For the chosen
platform this registers the App Store app, imports its yearly subscription and
lifetime unlock, attaches both to the `pro` entitlement, and builds a `default`
offering with `$rc_annual` and `$rc_lifetime` packages.

Reads RC_SECRET_FLACCY_<IOS|MAC> (project v2 secret key) from the environment.

Usage: source ~/.config/midgar/credentials.env && python3 scripts/rc-setup.py ios|mac
"""
import os
import sys

import requests

PLATFORM = sys.argv[1] if len(sys.argv) > 1 else ""
if PLATFORM not in ("ios", "mac"):
    sys.exit("usage: rc-setup.py ios|mac")
KEY = os.environ[f"RC_SECRET_FLACCY_{PLATFORM.upper()}"]
BASE = "https://api.revenuecat.com/v2"
H = {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"}

APPS = {
    "ios": [("Flaccy (iOS)", "com.midgarcorp.flaccy", "com.midgarcorp.flaccy")],
    "mac": [("Flaccy (Mac)", "com.midgarcorp.flaccy.mac", "com.midgarcorp.flaccy.mac")],
}[PLATFORM]
PRODUCTS = {
    "com.midgarcorp.flaccy": [
        ("com.midgarcorp.flaccy.pro.yearly", "subscription", "Flaccy Pro Yearly", "$rc_annual"),
        ("com.midgarcorp.flaccy.lifetime", "non_consumable", "Flaccy Lifetime", "$rc_lifetime"),
    ],
    "com.midgarcorp.flaccy.mac": [
        ("com.midgarcorp.flaccy.mac.pro.yearly", "subscription", "Flaccy Pro Yearly (Mac)", "$rc_annual"),
        ("com.midgarcorp.flaccy.mac.lifetime", "non_consumable", "Flaccy Lifetime (Mac)", "$rc_lifetime"),
    ],
}


def get(path):
    r = requests.get(BASE + path, headers=H, timeout=30)
    r.raise_for_status()
    return r.json()


def post(path, body):
    r = requests.post(BASE + path, headers=H, json=body, timeout=30)
    if r.status_code >= 400:
        print(f"    ! {r.status_code} {path}: {r.text[:200]}")
        return None
    return r.json()


def items(path):
    return get(path).get("items", [])


def project_id():
    projects = items("/projects")
    if len(projects) != 1:
        sys.exit(f"expected one project for this key, got {[p['id'] for p in projects]}")
    return projects[0]["id"]


def ensure_apps():
    existing = {a.get("app_store", {}).get("bundle_id"): a for a in items(f"/projects/{PROJECT}/apps")
                if a.get("type") == "app_store"}
    ids = {}
    for name, bundle, key in APPS:
        if bundle in existing:
            ids[key] = existing[bundle]["id"]
            print(f"✓ app {bundle} = {ids[key]}")
            continue
        r = post(f"/projects/{PROJECT}/apps", {"name": name, "type": "app_store", "app_store": {"bundle_id": bundle}})
        if not r:
            sys.exit(f"could not create app {bundle}")
        ids[key] = r["id"]
        print(f"+ app {bundle} = {ids[key]}")
    return ids


def main():
    global PROJECT
    PROJECT = project_id()
    print("project:", PROJECT)
    app_ids = ensure_apps()

    ents = {e["lookup_key"]: e for e in items(f"/projects/{PROJECT}/entitlements")}
    if "pro" in ents:
        pro = ents["pro"]["id"]
        print("✓ entitlement pro exists")
    else:
        pro = post(f"/projects/{PROJECT}/entitlements", {"lookup_key": "pro", "display_name": "Flaccy Pro"})["id"]
        print("+ entitlement pro")

    all_products = items(f"/projects/{PROJECT}/products")
    product_ids = {}
    for key, app_id in app_ids.items():
        existing = {p["store_identifier"]: p for p in all_products if p.get("app_id") == app_id}
        for sid, ptype, name, _pkg in PRODUCTS[key]:
            if sid in existing:
                product_ids[sid] = existing[sid]["id"]
                print(f"  ✓ product {sid}")
                continue
            r = post(f"/projects/{PROJECT}/products",
                     {"store_identifier": sid, "app_id": app_id, "type": ptype, "display_name": name, "title": name})
            if r:
                product_ids[sid] = r["id"]
                print(f"  + product {sid}")

    if product_ids:
        post(f"/projects/{PROJECT}/entitlements/{pro}/actions/attach_products",
             {"product_ids": list(product_ids.values())})
        print(f"  attached {len(product_ids)} products to pro")

    offs = {o["lookup_key"]: o for o in items(f"/projects/{PROJECT}/offerings")}
    if "default" in offs:
        off = offs["default"]["id"]
        print("✓ offering default exists")
    else:
        off = post(f"/projects/{PROJECT}/offerings", {"lookup_key": "default", "display_name": "Flaccy Pro"})["id"]
        print("+ offering default")

    packages = {p["lookup_key"]: p for p in items(f"/projects/{PROJECT}/offerings/{off}/packages")}
    for pkg_key in ("$rc_annual", "$rc_lifetime"):
        if pkg_key in packages:
            pkg = packages[pkg_key]["id"]
        else:
            r = post(f"/projects/{PROJECT}/offerings/{off}/packages", {"lookup_key": pkg_key, "display_name": pkg_key})
            if not r:
                continue
            pkg = r["id"]
            print(f"  + package {pkg_key}")
        attach = [{"product_id": product_ids[sid], "eligibility_criteria": "all"}
                  for key_ in app_ids for sid, _t, _n, key in PRODUCTS[key_]
                  if key == pkg_key and sid in product_ids]
        post(f"/projects/{PROJECT}/packages/{pkg}/actions/attach_products", {"products": attach})
        print(f"  {pkg_key}: {len(attach)} products attached")

    for key, app_id in app_ids.items():
        keys = items(f"/projects/{PROJECT}/apps/{app_id}/public_api_keys")
        for k in keys:
            print(f"PUBLIC KEY {key}: {k.get('key')}")
    print("DONE")


if __name__ == "__main__":
    main()
