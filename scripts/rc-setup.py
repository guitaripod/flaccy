#!/usr/bin/env python3
"""Idempotent RevenueCat (v2) setup for Flaccy.

iOS and Mac are separate SKUs with separate RevenueCat projects. For the chosen
platform this registers the App Store app, imports its yearly subscription, its
lifetime unlock and the welcome-back lifetime unlock, attaches all of them to
the `pro` entitlement, and builds two offerings: `default` (`$rc_annual` +
`$rc_lifetime`, the current offering) and `lapsed` (`$rc_lifetime` carrying the
welcome-back product, never made current — the app fetches it by lookup key
while the trial-lapsed window is open).

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
OFFERINGS = {
    "default": ("Flaccy Pro", ["$rc_annual", "$rc_lifetime"]),
    "lapsed": ("Welcome back", ["$rc_lifetime"]),
}
PRODUCTS = {
    "com.midgarcorp.flaccy": [
        ("com.midgarcorp.flaccy.pro.yearly", "subscription", "Flaccy Pro Yearly", "$rc_annual", "default"),
        ("com.midgarcorp.flaccy.lifetime", "non_consumable", "Flaccy Lifetime", "$rc_lifetime", "default"),
        ("com.midgarcorp.flaccy.lifetime.welcome", "non_consumable", "Flaccy Lifetime · Welcome Back",
         "$rc_lifetime", "lapsed"),
    ],
    "com.midgarcorp.flaccy.mac": [
        ("com.midgarcorp.flaccy.mac.pro.yearly", "subscription", "Flaccy Pro Yearly (Mac)", "$rc_annual", "default"),
        ("com.midgarcorp.flaccy.mac.lifetime", "non_consumable", "Flaccy Lifetime (Mac)", "$rc_lifetime", "default"),
        ("com.midgarcorp.flaccy.mac.lifetime.welcome", "non_consumable", "Flaccy Lifetime · Welcome Back (Mac)",
         "$rc_lifetime", "lapsed"),
    ],
}


def get(path):
    r = requests.get(BASE + path, headers=H, timeout=30)
    r.raise_for_status()
    return r.json()


def post(path, body):
    r = requests.post(BASE + path, headers=H, json=body, timeout=30)
    if r.status_code >= 400:
        print(f"    ! {r.status_code} {path}: {r.text[:500]}")
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


def attached_product_ids(owner):
    return {x["id"] if "id" in x else x["product"]["id"] for x in (owner.get("products") or {}).get("items", [])}


def ensure_entitlement():
    ents = {e["lookup_key"]: e for e in items(f"/projects/{PROJECT}/entitlements?expand=items.product")}
    if "pro" in ents:
        print("✓ entitlement pro exists")
        return ents["pro"]["id"], attached_product_ids(ents["pro"])
    r = post(f"/projects/{PROJECT}/entitlements", {"lookup_key": "pro", "display_name": "Flaccy Pro"})
    if not r:
        sys.exit("could not create entitlement pro")
    print("+ entitlement pro")
    return r["id"], set()


def attach_to_entitlement(pro, attached, product_ids):
    missing = [pid for pid in product_ids.values() if pid not in attached]
    if not missing:
        print(f"  ✓ pro: {len(product_ids)} products already attached")
        return
    if post(f"/projects/{PROJECT}/entitlements/{pro}/actions/attach_products", {"product_ids": missing}):
        print(f"  + pro: attached {len(missing)} products")


def ensure_products(app_ids):
    all_products = items(f"/projects/{PROJECT}/products")
    product_ids = {}
    for key, app_id in app_ids.items():
        existing = {p["store_identifier"]: p for p in all_products if p.get("app_id") == app_id}
        for sid, ptype, name, _pkg, _offering in PRODUCTS[key]:
            if sid in existing:
                product_ids[sid] = existing[sid]["id"]
                print(f"  ✓ product {sid}")
                continue
            r = post(f"/projects/{PROJECT}/products",
                     {"store_identifier": sid, "app_id": app_id, "type": ptype, "display_name": name, "title": name})
            if r:
                product_ids[sid] = r["id"]
                print(f"  + product {sid}")
    return product_ids


def ensure_offerings():
    offs = {o["lookup_key"]: o for o in items(f"/projects/{PROJECT}/offerings")}
    ids = {}
    for lookup_key, (display_name, _packages) in OFFERINGS.items():
        if lookup_key in offs:
            ids[lookup_key] = offs[lookup_key]["id"]
            print(f"✓ offering {lookup_key} exists (current={offs[lookup_key].get('is_current')})")
            continue
        r = post(f"/projects/{PROJECT}/offerings", {"lookup_key": lookup_key, "display_name": display_name})
        if not r:
            sys.exit(f"could not create offering {lookup_key}")
        ids[lookup_key] = r["id"]
        print(f"+ offering {lookup_key} (current={r.get('is_current')})")
    return ids


def products_for(package_key, offering_key, app_ids, product_ids):
    return [{"product_id": product_ids[sid], "eligibility_criteria": "all"}
            for key in app_ids for sid, _t, _n, pkg, offering in PRODUCTS[key]
            if pkg == package_key and offering == offering_key and sid in product_ids]


def ensure_packages(offering_key, offering_id, app_ids, product_ids):
    packages = {p["lookup_key"]: p
                for p in items(f"/projects/{PROJECT}/offerings/{offering_id}/packages?expand=items.product")}
    for pkg_key in OFFERINGS[offering_key][1]:
        if pkg_key in packages:
            pkg = packages[pkg_key]["id"]
            attached = attached_product_ids(packages[pkg_key])
        else:
            r = post(f"/projects/{PROJECT}/offerings/{offering_id}/packages",
                     {"lookup_key": pkg_key, "display_name": pkg_key})
            if not r:
                continue
            pkg = r["id"]
            attached = set()
            print(f"  + package {offering_key}/{pkg_key}")
        wanted = products_for(pkg_key, offering_key, app_ids, product_ids)
        missing = [x for x in wanted if x["product_id"] not in attached]
        if not missing:
            print(f"  ✓ {offering_key}/{pkg_key}: {len(wanted)} products already attached")
            continue
        if post(f"/projects/{PROJECT}/packages/{pkg}/actions/attach_products", {"products": missing}):
            print(f"  + {offering_key}/{pkg_key}: attached {len(missing)} products")


def main():
    global PROJECT
    PROJECT = project_id()
    print("project:", PROJECT)
    app_ids = ensure_apps()
    pro, pro_products = ensure_entitlement()
    product_ids = ensure_products(app_ids)

    attach_to_entitlement(pro, pro_products, product_ids)

    offering_ids = ensure_offerings()
    for offering_key, offering_id in offering_ids.items():
        ensure_packages(offering_key, offering_id, app_ids, product_ids)

    for key, app_id in app_ids.items():
        keys = items(f"/projects/{PROJECT}/apps/{app_id}/public_api_keys")
        for k in keys:
            print(f"PUBLIC KEY {key}: {k.get('key')}")
    print("DONE")


if __name__ == "__main__":
    main()
