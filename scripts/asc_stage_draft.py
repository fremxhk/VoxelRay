#!/usr/bin/env python3
"""
Idempotent App Store Connect Draft Staging & TestFlight Utility for VoxelRay.
Strictly prepares App metadata, Content Rights, Age Rating (4+), Pricing & Global Availability,
TestFlight Internal Testing, Build attachment, 6.9" Screenshots, and Non-Consumable IAPs
up to PREPARE_FOR_SUBMISSION. NEVER submits for App Review.
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BUNDLE_ID = "com.voxelray.app"
APP_NAME = "VoxelRay"
FALLBACK_APP_NAME = "VoxelRay: Voxel Sandbox"
SKU = "voxelray-ios-001"
VERSION_STRING = "1.0.0"

PRIVACY_URL = "https://github.com/fremxhk/VoxelRay/blob/main/PRIVACY.md"
SUPPORT_URL = "https://github.com/fremxhk/VoxelRay/blob/main/SUPPORT.md"
MARKETING_URL = "https://github.com/fremxhk/VoxelRay"

KEYWORDS = "voxel,raytracing,metal,sandbox,destruction,path tracing,3d,blocks,physics,sculpt"
assert len(KEYWORDS) <= 100

DESCRIPTION = (
    "VoxelRay is a real-time ray-traced destructible voxel sandbox built natively for iPhone.\n\n"
    "Tap to shatter travertine colonnades with physics-driven 3D voxel debris, sculpt with Gold, "
    "glowing Neon Cyan, Glass, and iridescent Prism Crystal brushes, and shift lighting from golden sunset "
    "to midnight obsidian with responsive procedural spatial audio. Powered by Metal ray tracing, optical HDR bloom, "
    "and adaptive thermal scaling with zero servers, ads, or tracking.\n\n"
    "Key Features:\n"
    "- Multi-bounce Monte Carlo global illumination, water reflections & optical bloom\n"
    "- Tap-to-carve spherical destruction with 3D debris physics, camera shake & multi-step Undo\n"
    "- Free Gold, Neon Cyan, and Glass sculpting brushes plus curated Dawn/Noon/Sunset/Night presets\n"
    "- Procedural material foley audio & spatial biome atmospheres\n"
    "- 64-sample Photo Mode convergence with instant iOS Share Sheet export\n"
    "- One-time Architect Pro and Prism Material Pack unlocks via StoreKit 2"
)

PROMO_TEXT = "Shatter, sculpt, and ray-trace destructible voxel worlds in real time on iPhone."


def _read_config_file() -> dict:
    cfg_path = Path.home() / ".config" / "cuiju-appstore" / "config.json"
    if cfg_path.exists():
        return json.loads(cfg_path.read_text())
    return {}


def load_credentials():
    env_vars = dict(os.environ)
    dotenv = Path(".env")
    if dotenv.exists():
        for line in dotenv.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env_vars.setdefault(k.strip(), v.strip().strip('"').strip("'"))

    key_id = env_vars.get("ASC_KEY_ID") or env_vars.get("APP_STORE_CONNECT_KEY_ID")
    issuer_id = env_vars.get("ASC_ISSUER_ID") or env_vars.get("APP_STORE_CONNECT_ISSUER_ID")
    key_path = (
        env_vars.get("ASC_KEY_PATH")
        or env_vars.get("ASC_PRIVATE_KEY_PATH")
        or env_vars.get("APP_STORE_CONNECT_KEY_PATH")
    )

    if not (key_id and issuer_id and key_path):
        cfg = _read_config_file()
        key_id = key_id or cfg.get("key_id")
        issuer_id = issuer_id or cfg.get("issuer_id")
        key_path = key_path or cfg.get("private_key_path")

    if not (key_id and issuer_id and key_path):
        raise RuntimeError(
            "Missing ASC credentials. Provide ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH."
        )
    if not Path(key_path).exists():
        raise RuntimeError(f"ASC private key file not found: {key_path}")
    return key_id, issuer_id, key_path


def load_review_contact() -> dict:
    cfg = _read_config_file()
    rc = cfg.get("review_contact", {})
    return {
        "first_name": os.environ.get("ASC_REVIEW_FIRST_NAME") or rc.get("first_name", ""),
        "last_name": os.environ.get("ASC_REVIEW_LAST_NAME") or rc.get("last_name", ""),
        "phone": os.environ.get("ASC_REVIEW_PHONE") or rc.get("phone", ""),
        "email": os.environ.get("ASC_REVIEW_EMAIL") or rc.get("email", ""),
    }


def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def _der_to_raw_es256(der: bytes) -> bytes:
    if der[0] != 0x30:
        raise ValueError("Invalid DER ECDSA signature")
    idx = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    if der[idx] != 0x02:
        raise ValueError("Invalid DER r tag")
    r_len = der[idx + 1]
    r = der[idx + 2 : idx + 2 + r_len]
    idx = idx + 2 + r_len
    if der[idx] != 0x02:
        raise ValueError("Invalid DER s tag")
    s_len = der[idx + 1]
    s = der[idx + 2 : idx + 2 + s_len]
    return r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")


class ASCClient:
    def __init__(self, key_id: str, issuer_id: str, key_path: str):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key_path = key_path
        self._token = None
        self._token_exp = 0

    def token(self) -> str:
        now = int(time.time())
        if self._token and now < self._token_exp - 120:
            return self._token
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        exp = now + 900
        payload = {"iss": self.issuer_id, "iat": now, "exp": exp, "aud": "appstoreconnect-v1"}
        si = (
            f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}."
            f"{_b64url(json.dumps(payload, separators=(',', ':')).encode())}"
        )
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.key_path],
            input=si.encode("ascii"),
            capture_output=True,
            check=True,
        )
        sig = _der_to_raw_es256(proc.stdout)
        self._token = f"{si}.{_b64url(sig)}"
        self._token_exp = exp
        return self._token

    def request(self, method: str, path: str, body=None, allow_statuses=(200, 201, 204)):
        url = path if path.startswith("https://") else f"https://api.appstoreconnect.apple.com{path}"
        headers = {
            "Authorization": f"Bearer {self.token()}",
            "Content-Type": "application/json",
        }
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                return resp.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw) if raw else {}
            except Exception:
                parsed = {"raw": raw}
            if e.code in allow_statuses:
                return e.code, parsed
            raise ASCHTTPError(e.code, path, parsed)

    def get_paginated(self, path: str) -> list:
        items = []
        next_url = path
        while next_url:
            _, res = self.request("GET", next_url)
            items.extend(res.get("data", []))
            next_url = res.get("links", {}).get("next")
        return items


class ASCHTTPError(RuntimeError):
    def __init__(self, status: int, path: str, body):
        self.status = status
        self.path = path
        self.body = body
        super().__init__(f"ASC API HTTP {status} on {path}: {json.dumps(body)[:800]}")


def ensure_bundle_id(client: ASCClient) -> str:
    _, res = client.request("GET", f"/v1/bundleIds?filter[identifier]={urllib.parse.quote(BUNDLE_ID)}")
    for item in res.get("data", []):
        if item["attributes"].get("identifier") == BUNDLE_ID:
            print(f"Bundle ID exists: {BUNDLE_ID} (id={item['id']})")
            return item["id"]
    _, created = client.request(
        "POST",
        "/v1/bundleIds",
        {
            "data": {
                "type": "bundleIds",
                "attributes": {"identifier": BUNDLE_ID, "name": APP_NAME, "platform": "IOS"},
            }
        },
    )
    bid_id = created["data"]["id"]
    print(f"Created Bundle ID: {BUNDLE_ID} (id={bid_id})")
    return bid_id


def find_app(client: ASCClient):
    _, res = client.request("GET", f"/v1/apps?filter[bundleId]={urllib.parse.quote(BUNDLE_ID)}")
    for item in res.get("data", []):
        if item["attributes"].get("bundleId") == BUNDLE_ID:
            return item
    return None


def prepare_app(client: ASCClient):
    bundle_res_id = ensure_bundle_id(client)
    app = find_app(client)
    if app is None:
        print(f"App record not found for {BUNDLE_ID}; attempting POST /v1/apps...")
        for candidate_name in (APP_NAME, FALLBACK_APP_NAME):
            try:
                _, created = client.request(
                    "POST",
                    "/v1/apps",
                    {
                        "data": {
                            "type": "apps",
                            "attributes": {
                                "bundleId": BUNDLE_ID,
                                "name": candidate_name,
                                "primaryLocale": "en-US",
                                "sku": SKU,
                            },
                            "relationships": {
                                "bundleId": {"data": {"type": "bundleIds", "id": bundle_res_id}}
                            },
                        }
                    },
                )
                app = created["data"]
                print(f"Created App record: {candidate_name} (id={app['id']})")
                break
            except ASCHTTPError as e:
                if e.status in (403, 404, 405):
                    print(f"POST /v1/apps blocked by ASC API (HTTP {e.status}): {json.dumps(e.body)}", file=sys.stderr)
                    sys.exit(42)
                if e.status == 409:
                    print(f"Name '{candidate_name}' conflict (409), trying fallback...")
                    continue
                raise

    if app is None:
        raise RuntimeError("Could not find or create ASC App record.")

    app_id = app["id"]
    _, builds = client.request("GET", f"/v1/builds?filter[app]={app_id}&limit=50")
    max_build = 0
    for b in builds.get("data", []):
        v = b["attributes"].get("version", "0")
        if str(v).isdigit():
            max_build = max(max_build, int(v))
    next_build = max_build + 1
    print(f"ASC_APP_ID={app_id}")
    print(f"ASC_APP_NAME={app['attributes'].get('name')}")
    print(f"NEXT_BUILD_NUMBER={next_build}")


def wait_for_valid_build(client: ASCClient, app_id: str, build_number: str):
    print(f"Polling ASC for build {VERSION_STRING} ({build_number})...")
    for attempt in range(1, 61):
        _, res = client.request(
            "GET",
            f"/v1/builds?filter[app]={app_id}&filter[version]={urllib.parse.quote(build_number)}&limit=5",
        )
        builds = res.get("data", [])
        if builds:
            b = builds[0]
            state = b["attributes"].get("processingState")
            print(f"  [Attempt {attempt}/60] Build {b['id']} processingState={state}")
            if state == "VALID":
                return b
            if state in ("INVALID", "FAILED"):
                raise RuntimeError(f"Build {b['id']} processingState={state}")
        else:
            print(f"  [Attempt {attempt}/60] Build not visible yet...")
        time.sleep(20)
    raise TimeoutError(f"Timed out waiting for build {build_number} to become VALID")


def upload_asset_binary(upload_ops: list, file_bytes: bytes):
    for op in upload_ops:
        method = op["method"]
        url = op["url"]
        offset = op.get("offset", 0)
        length = op.get("length", len(file_bytes))
        chunk = file_bytes[offset : offset + length]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        req = urllib.request.Request(url, data=chunk, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=60) as resp:
            if resp.status not in (200, 201, 204):
                raise RuntimeError(f"Asset upload chunk failed HTTP {resp.status}")


def find_or_update_ios_version(client: ASCClient, app_id: str) -> dict:
    _, vers = client.request("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=20")
    existing = None
    for v in vers.get("data", []):
        if v["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION":
            existing = v
            break
    if existing:
        vid = existing["id"]
        attrs = existing["attributes"]
        if attrs.get("versionString") != VERSION_STRING or attrs.get("releaseType") != "MANUAL" or attrs.get("copyright") != "2026 Ho Kit Cheung":
            _, patched = client.request(
                "PATCH",
                f"/v1/appStoreVersions/{vid}",
                {
                    "data": {
                        "type": "appStoreVersions",
                        "id": vid,
                        "attributes": {
                            "versionString": VERSION_STRING,
                            "releaseType": "MANUAL",
                            "copyright": "2026 Ho Kit Cheung",
                        },
                    }
                },
            )
            existing = patched["data"]
            print(f"Updated existing PREPARE_FOR_SUBMISSION version {vid} -> {VERSION_STRING}")
        return existing

    _, created_ver = client.request(
        "POST",
        "/v1/appStoreVersions",
        {
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": "IOS",
                    "versionString": VERSION_STRING,
                    "releaseType": "MANUAL",
                    "copyright": "2026 Ho Kit Cheung",
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    print(f"Created new version {created_ver['data']['id']} ({VERSION_STRING})")
    return created_ver["data"]


def stage_testflight_internal(client: ASCClient, app_id: str, build_id: str, review_contact: dict):
    print("Configuring TestFlight Internal Testing...")
    _, bg_res = client.request("GET", f"/v1/apps/{app_id}/betaGroups?limit=20")
    internal_group = None
    for g in bg_res.get("data", []):
        if g["attributes"].get("isInternalGroup") is True:
            internal_group = g
            break

    if internal_group is None:
        _, created_bg = client.request(
            "POST",
            "/v1/betaGroups",
            {
                "data": {
                    "type": "betaGroups",
                    "attributes": {
                        "name": "Internal Testers",
                        "isInternalGroup": True,
                        "hasAccessToAllBuilds": True,
                        "feedbackEnabled": True,
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )
        internal_group = created_bg["data"]
        print(f"  Created TestFlight Internal Group: {internal_group['id']}")
    else:
        gid = internal_group["id"]
        attrs = internal_group["attributes"]
        if not attrs.get("hasAccessToAllBuilds") or not attrs.get("feedbackEnabled"):
            client.request(
                "PATCH",
                f"/v1/betaGroups/{gid}",
                {
                    "data": {
                        "type": "betaGroups",
                        "id": gid,
                        "attributes": {"hasAccessToAllBuilds": True, "feedbackEnabled": True},
                    }
                },
            )
        print(f"  Using existing TestFlight Internal Group: {gid}")

    group_id = internal_group["id"]
    print(f"ASC_BETA_GROUP_ID={group_id}")

    # Discover internal team Account Holder email
    _, users_res = client.request("GET", "/v1/users?limit=10")
    tester_email = os.environ.get("ASC_INTERNAL_TESTER_EMAIL")
    tester_first = review_contact.get("first_name") or "Ho Kit"
    tester_last = review_contact.get("last_name") or "Cheung"
    if not tester_email and users_res.get("data"):
        u = users_res["data"][0]
        tester_email = u["attributes"].get("username")
        tester_first = u["attributes"].get("firstName") or tester_first
        tester_last = u["attributes"].get("lastName") or tester_last

    if tester_email:
        _, group_testers = client.request("GET", f"/v1/betaGroups/{group_id}/betaTesters?limit=50")
        already_in_group = any(
            (t["attributes"].get("email") or "").lower() == tester_email.lower()
            for t in group_testers.get("data", [])
        )
        if not already_in_group:
            _, found_testers = client.request(
                "GET",
                f"/v1/betaTesters?filter[email]={urllib.parse.quote(tester_email)}&limit=10",
            )
            linked = False
            for t in found_testers.get("data", []):
                st, _ = client.request(
                    "POST",
                    f"/v1/betaGroups/{group_id}/relationships/betaTesters",
                    {"data": [{"type": "betaTesters", "id": t["id"]}]},
                    allow_statuses=(200, 201, 204, 409, 422),
                )
                if st in (200, 201, 204):
                    linked = True
                    print(f"  Linked internal beta tester {t['id']} to group {group_id}")
                    break
            if not linked:
                try:
                    client.request(
                        "POST",
                        "/v1/betaTesters",
                        {
                            "data": {
                                "type": "betaTesters",
                                "attributes": {
                                    "email": tester_email,
                                    "firstName": tester_first,
                                    "lastName": tester_last,
                                },
                                "relationships": {
                                    "betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}
                                },
                            }
                        },
                    )
                    print(f"  Added internal beta tester to group {group_id}")
                except ASCHTTPError as e:
                    print(f"  Internal tester creation note: {e}")

    _, final_testers = client.request("GET", f"/v1/betaGroups/{group_id}/betaTesters?limit=50")
    print(f"TESTFLIGHT_TESTER_COUNT={len(final_testers.get('data', []))}")

    # Beta App Localization (en-US)
    feedback_email = review_contact.get("email") or tester_email or ""
    beta_desc = (
        "Internal TestFlight build of VoxelRay: real-time Metal ray-traced destructible voxel sandbox "
        "with procedural material foley audio, 3D debris physics, optical bloom, and StoreKit 2 unlocks."
    )
    _, bals = client.request("GET", f"/v1/apps/{app_id}/betaAppLocalizations")
    bal_id = next(
        (l["id"] for l in bals.get("data", []) if l["attributes"].get("locale") == "en-US"),
        None,
    )
    if bal_id:
        client.request(
            "PATCH",
            f"/v1/betaAppLocalizations/{bal_id}",
            {
                "data": {
                    "type": "betaAppLocalizations",
                    "id": bal_id,
                    "attributes": {
                        "description": beta_desc,
                        "feedbackEmail": feedback_email,
                        "marketingUrl": MARKETING_URL,
                    },
                }
            },
        )
    else:
        client.request(
            "POST",
            "/v1/betaAppLocalizations",
            {
                "data": {
                    "type": "betaAppLocalizations",
                    "attributes": {
                        "locale": "en-US",
                        "description": beta_desc,
                        "feedbackEmail": feedback_email,
                        "marketingUrl": MARKETING_URL,
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )

    # Beta App Review Details
    if review_contact.get("email") and review_contact.get("phone"):
        client.request(
            "PATCH",
            f"/v1/betaAppReviewDetails/{app_id}",
            {
                "data": {
                    "type": "betaAppReviewDetails",
                    "id": app_id,
                    "attributes": {
                        "contactFirstName": review_contact["first_name"],
                        "contactLastName": review_contact["last_name"],
                        "contactPhone": review_contact["phone"],
                        "contactEmail": review_contact["email"],
                        "demoAccountRequired": False,
                        "notes": "No login required. Landscape Metal ray-tracing sandbox with StoreKit 2 non-consumable unlocks.",
                    },
                }
            },
        )

    # Beta Build Localization (What to Test)
    whats_new = (
        "Initial 1.0.0 TestFlight build: test tap-to-carve destruction across Sunlit Courtyard, "
        "live preview & StoreKit 2 unlocks for Neon Cavern & Glass Cathedral, spatial material audio, "
        "free Gold/Neon/Glass brushes, Undo, Dawn-Night presets, and 64-sample Photo Mode export."
    )
    _, bbls = client.request("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")
    bbl_id = next(
        (l["id"] for l in bbls.get("data", []) if l["attributes"].get("locale") == "en-US"),
        None,
    )
    if bbl_id:
        client.request(
            "PATCH",
            f"/v1/betaBuildLocalizations/{bbl_id}",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": bbl_id,
                    "attributes": {"whatsNew": whats_new},
                }
            },
        )
    else:
        client.request(
            "POST",
            "/v1/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": "en-US", "whatsNew": whats_new},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )

    # Enable autoNotifyEnabled on buildBetaDetails and check TestFlight state
    _, bbd = client.request("GET", f"/v1/builds/{build_id}/buildBetaDetail")
    if bbd.get("data"):
        detail_id = bbd["data"]["id"]
        try:
            _, updated_bbd = client.request(
                "PATCH",
                f"/v1/buildBetaDetails/{detail_id}",
                {
                    "data": {
                        "type": "buildBetaDetails",
                        "id": detail_id,
                        "attributes": {"autoNotifyEnabled": True},
                    }
                },
            )
            bbd_attrs = updated_bbd["data"]["attributes"]
        except ASCHTTPError:
            bbd_attrs = bbd["data"]["attributes"]
        print(f"TESTFLIGHT_INTERNAL_STATE={bbd_attrs.get('internalBuildState')}")
        print(f"TESTFLIGHT_EXTERNAL_STATE={bbd_attrs.get('externalBuildState')}")
        print(f"TESTFLIGHT_AUTO_NOTIFY={bbd_attrs.get('autoNotifyEnabled')}")


def stage_content_rights_and_age_rating(client: ASCClient, app_id: str, app_info_id: str):
    client.request(
        "PATCH",
        f"/v1/apps/{app_id}",
        {
            "data": {
                "type": "apps",
                "id": app_id,
                "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"},
            }
        },
    )
    print("Set Content Rights: DOES_NOT_USE_THIRD_PARTY_CONTENT")

    _, age_res = client.request("GET", f"/v1/appInfos/{app_info_id}/ageRatingDeclaration")
    age_id = age_res["data"]["id"]
    client.request(
        "PATCH",
        f"/v1/ageRatingDeclarations/{age_id}",
        {
            "data": {
                "type": "ageRatingDeclarations",
                "id": age_id,
                "attributes": {
                    "advertising": False,
                    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
                    "contests": "NONE",
                    "gambling": False,
                    "gamblingSimulated": "NONE",
                    "gunsOrOtherWeapons": "NONE",
                    "healthOrWellnessTopics": False,
                    "lootBox": False,
                    "medicalOrTreatmentInformation": "NONE",
                    "messagingAndChat": False,
                    "parentalControls": False,
                    "profanityOrCrudeHumor": "NONE",
                    "ageAssurance": False,
                    "sexualContentGraphicAndNudity": "NONE",
                    "sexualContentOrNudity": "NONE",
                    "socialMedia": False,
                    "socialMediaAgeRestricted": False,
                    "horrorOrFearThemes": "NONE",
                    "matureOrSuggestiveThemes": "NONE",
                    "unrestrictedWebAccess": False,
                    "userGeneratedContent": False,
                    "violenceCartoonOrFantasy": "NONE",
                    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
                    "violenceRealistic": "NONE",
                    "ageRatingOverrideV2": "NONE",
                    "koreaAgeRatingOverride": "NONE",
                },
            }
        },
    )
    _, ai_check = client.request("GET", f"/v1/appInfos/{app_info_id}")
    ai_attrs = ai_check["data"]["attributes"]
    print(f"APP_STORE_AGE_RATING={ai_attrs.get('appStoreAgeRating')}")


def stage_pricing_and_availability(client: ASCClient, app_id: str) -> list[str]:
    territories = client.get_paginated("/v1/territories?limit=200")
    territory_ids = [t["id"] for t in territories]

    # App Price Schedule (Free $0.00 USA base)
    st_ps, cur_ps = client.request("GET", f"/v1/apps/{app_id}/appPriceSchedule?include=manualPrices", allow_statuses=(200, 404))
    has_app_manual = (
        st_ps == 200
        and isinstance(cur_ps.get("data"), dict)
        and len(cur_ps["data"].get("relationships", {}).get("manualPrices", {}).get("data", [])) > 0
    )
    if has_app_manual:
        print(f"App Price Schedule already configured (id={cur_ps['data']['id']})")
    else:
        _, pp_res = client.request("GET", f"/v1/apps/{app_id}/appPricePoints?filter[territory]=USA&limit=20")
        free_pp = next(
            (p["id"] for p in pp_res.get("data", []) if float(p["attributes"].get("customerPrice", 99)) == 0.0),
            None,
        )
        if not free_pp:
            raise RuntimeError("Could not locate Free USA appPricePoint")
        client.request(
            "POST",
            "/v1/appPriceSchedules",
            {
                "data": {
                    "type": "appPriceSchedules",
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}},
                        "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                        "manualPrices": {"data": [{"type": "appPrices", "id": "${price0}"}]},
                    },
                },
                "included": [
                    {
                        "type": "appPrices",
                        "id": "${price0}",
                        "attributes": {"startDate": None},
                        "relationships": {
                            "appPricePoint": {"data": {"type": "appPricePoints", "id": free_pp}}
                        },
                    }
                ],
            },
        )
        print("Set App Price Schedule: Free ($0.00 USD)")

    # App Global Availability (v2)
    st_av, cur_av = client.request("GET", f"/v1/apps/{app_id}/appAvailabilityV2", allow_statuses=(200, 404))
    has_avail = st_av == 200 and cur_av.get("data") is not None
    if not has_avail:
        included = []
        rel_list = []
        for tid in territory_ids:
            local_id = f"${{terr_{tid}}}"
            rel_list.append({"type": "territoryAvailabilities", "id": local_id})
            included.append(
                {
                    "type": "territoryAvailabilities",
                    "id": local_id,
                    "attributes": {"available": True, "releaseDate": None, "preOrderEnabled": False},
                    "relationships": {"territory": {"data": {"type": "territories", "id": tid}}},
                }
            )
        client.request(
            "POST",
            "/v2/appAvailabilities",
            {
                "data": {
                    "type": "appAvailabilities",
                    "attributes": {"availableInNewTerritories": True},
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}},
                        "territoryAvailabilities": {"data": rel_list},
                    },
                },
                "included": included,
            },
        )
        print(f"Set Global App Availability across {len(territory_ids)} territories")
    else:
        print(f"App Global Availability already set (id={cur_av['data']['id']})")

    return territory_ids


def stage_review_detail(client: ASCClient, version_id: str, review_contact: dict):
    if not (review_contact.get("email") and review_contact.get("phone")):
        print("Review contact incomplete; skipping appStoreReviewDetails update.")
        return

    notes = (
        "1. PHYSICAL DEVICE SCREEN RECORDING\n"
        'Attached in App Review Information Attachments as "voxelray_iphone13_review.mp4" '
        "(captured directly on physical iPhone 13 mini, iPhone14,4, running iOS 27.2.1). "
        "The recording begins on the iOS Home Screen, launches VoxelRay, and demonstrates real-time "
        "Metal ray-traced voxel destruction, Undo, Gold/Neon sculpting brushes, Sunset/Night/Noon "
        "lighting, camera pan and virtual joystick flight, timed live previews of Neon Cavern and "
        "Glass Cathedral, accessing paid content via the VoxelRay Studio StoreKit 2 paywall "
        "(Architect Pro, Prism Material Pack, and Restore Purchases), and 64-sample Photo Mode export.\n"
        "- Account registration, login, and deletion: Not applicable. VoxelRay does not create, "
        "require, or support user accounts or sign-in.\n"
        "- User-generated content (UGC) reporting/blocking: Not applicable. All voxel edits exist "
        "strictly locally on-device with no social feed, server, or shared public UGC.\n\n"
        "2. PURPOSE, TARGET AUDIENCE & VALUE\n"
        "VoxelRay is a real-time ray-traced destructible voxel sandbox built natively for iPhone. "
        "Target audience: casual players, sandbox builders, and mobile graphics enthusiasts (ages 4+). "
        "Problem solved and value provided: physically based multi-bounce ray tracing and destructible "
        "3D voxel worlds are rarely available offline on handheld phones; VoxelRay delivers tactile "
        "voxel blasting, creative material sculpting, physics debris, procedural spatial audio, and "
        "64-sample Photo Mode renders entirely on-device with no servers, ads, or subscriptions.\n\n"
        "3. SETUP & FEATURE ACCESS INSTRUCTIONS\n"
        "- No login credentials, demo account, or sample files are required. Launch in landscape orientation.\n"
        "- Core Free Sandbox (Sunlit Courtyard): Tap structures to blast spherical voxel craters with 3D "
        "debris and haptics; tap Undo or Reset World (bottom right). Drag anywhere to rotate camera; "
        "use the bottom-left virtual joystick to fly. Select Carve, Gold, Neon, or Glass brushes "
        "(bottom left) to destroy or sculpt. Adjust Blast Radius, Sun Elevation, or Dawn/Noon/Sunset/"
        "Night presets (bottom right). Tap the speaker icon (top right) to toggle procedural audio.\n"
        '- Photo Mode: Tap "Photo Mode" (top right) to converge a 64-sample path-traced render and '
        "export via the native iOS Share Sheet.\n"
        '- Paid Features (StoreKit 2): Tap locked "Neon Cavern" or "Glass Cathedral" (top bar) for a '
        'live timed preview, then tap "Unlock Pro" (or tap the "Pro" button or locked "Prism" brush) '
        "to open VoxelRay Studio and purchase or restore Architect Pro "
        f"({BUNDLE_ID}.pro, $4.99) or Prism Material Pack ({BUNDLE_ID}.materials.crystal, $1.99).\n\n"
        "4. EXTERNAL SERVICES, TOOLS & PLATFORMS\n"
        "None. VoxelRay uses zero external servers, zero third-party SDKs, zero analytics or ad "
        "networks, zero external payment processors, and zero AI/ML services. Core functionality runs "
        "100% on-device using native Apple frameworks only: SwiftUI, Metal, MetalFX, AVFoundation, "
        "UIKit (UIActivityViewController), and Apple StoreKit 2 exclusively for in-app purchases.\n\n"
        "5. REGIONAL DIFFERENCES\n"
        "None. VoxelRay functions identically across all supported App Store regions with zero "
        "geo-blocking, regional feature differences, or region-specific content. Only StoreKit 2 "
        "purchase pricing displays automatically in each storefront's local currency via Apple App Store.\n\n"
        "6. REGULATED INDUSTRY / PROTECTED THIRD-PARTY MATERIAL\n"
        "Not applicable. VoxelRay is a general-audience creative sandbox game (rated 4+), does not "
        "operate in a regulated industry, and includes zero protected third-party material—all 3D voxel "
        "geometry, shaders, UI assets, and synthesized procedural audio are 100% original and generated on-device."
    )
    attrs = {
        "contactFirstName": review_contact["first_name"],
        "contactLastName": review_contact["last_name"],
        "contactPhone": review_contact["phone"],
        "contactEmail": review_contact["email"],
        "demoAccountRequired": False,
        "notes": notes,
    }
    st, cur = client.request("GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail", allow_statuses=(200, 404))
    if st == 200 and cur.get("data"):
        client.request(
            "PATCH",
            f"/v1/appStoreReviewDetails/{cur['data']['id']}",
            {"data": {"type": "appStoreReviewDetails", "id": cur["data"]["id"], "attributes": attrs}},
        )
        print(f"Updated App Store Review Detail ({cur['data']['id']})")
    else:
        _, created = client.request(
            "POST",
            "/v1/appStoreReviewDetails",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "attributes": attrs,
                    "relationships": {
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
                    },
                }
            },
        )
        print(f"Created App Store Review Detail ({created['data']['id']})")


def stage_screenshots(client: ASCClient, loc_id: str, screenshot_dir: Path):
    pngs = sorted(screenshot_dir.glob("*.png"))
    if len(pngs) < 4:
        raise RuntimeError(f"Expected >=4 PNG screenshots in {screenshot_dir}, found {len(pngs)}")

    _, sets_res = client.request("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")
    existing_sets = {s["attributes"].get("screenshotDisplayType"): s["id"] for s in sets_res.get("data", [])}

    chosen_set_id = None
    for display_type in ("APP_IPHONE_67", "APP_IPHONE_69"):
        if display_type in existing_sets:
            set_id = existing_sets[display_type]
        else:
            try:
                _, created_set = client.request(
                    "POST",
                    "/v1/appScreenshotSets",
                    {
                        "data": {
                            "type": "appScreenshotSets",
                            "attributes": {"screenshotDisplayType": display_type},
                            "relationships": {
                                "appStoreVersionLocalization": {
                                    "data": {"type": "appStoreVersionLocalizations", "id": loc_id}
                                }
                            },
                        }
                    },
                )
                set_id = created_set["data"]["id"]
            except ASCHTTPError as e:
                print(f"Display type {display_type} creation note: {e}")
                continue

        _, old_shots = client.request("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots")
        existing_complete = {
            s["attributes"].get("fileName"): s["attributes"].get("assetDeliveryState", {}).get("state")
            for s in old_shots.get("data", [])
        }
        expected_names = [p.name for p in pngs[:5]]
        if len(existing_complete) == len(expected_names) and all(existing_complete.get(n) == "COMPLETE" for n in expected_names):
            print(f"  All {len(expected_names)} screenshots already COMPLETE in {display_type}")
            return
        for s in old_shots.get("data", []):
            client.request("DELETE", f"/v1/appScreenshots/{s['id']}", allow_statuses=(200, 204, 404))

        try:
            for png in pngs[:5]:
                raw = png.read_bytes()
                md5_hex = hashlib.md5(raw).hexdigest()
                _, reserve = client.request(
                    "POST",
                    "/v1/appScreenshots",
                    {
                        "data": {
                            "type": "appScreenshots",
                            "attributes": {"fileSize": len(raw), "fileName": png.name},
                            "relationships": {
                                "appScreenshotSet": {
                                    "data": {"type": "appScreenshotSets", "id": set_id}
                                }
                            },
                        }
                    },
                )
                shot_id = reserve["data"]["id"]
                ops = reserve["data"]["attributes"]["uploadOperations"]
                upload_asset_binary(ops, raw)
                client.request(
                    "PATCH",
                    f"/v1/appScreenshots/{shot_id}",
                    {
                        "data": {
                            "type": "appScreenshots",
                            "id": shot_id,
                            "attributes": {"sourceFileChecksum": md5_hex, "uploaded": True},
                        }
                    },
                )
                for _ in range(30):
                    _, status_res = client.request("GET", f"/v1/appScreenshots/{shot_id}")
                    st = status_res["data"]["attributes"].get("assetDeliveryState", {}).get("state")
                    if st == "COMPLETE":
                        print(f"  Uploaded & verified screenshot {png.name} ({display_type})")
                        break
                    if st == "FAILED":
                        raise RuntimeError(f"Screenshot {png.name} failed ASC processing: {status_res}")
                    time.sleep(2)
            chosen_set_id = set_id
            break
        except ASCHTTPError as e:
            print(f"Retrying next display type after {display_type} error: {e}")
            continue

    if not chosen_set_id:
        raise RuntimeError("Failed to upload screenshots into APP_IPHONE_67 or APP_IPHONE_69")


def stage_iap(
    client: ASCClient,
    app_id: str,
    product_id: str,
    reference_name: str,
    display_name: str,
    description: str,
    usd_price: str,
    review_screenshot: Path,
    territory_ids: list[str],
):
    _, existing = client.request("GET", f"/v1/apps/{app_id}/inAppPurchasesV2?limit=50")
    iap_id = None
    for item in existing.get("data", []):
        if item["attributes"].get("productId") == product_id:
            iap_id = item["id"]
            break

    if iap_id is None:
        _, created = client.request(
            "POST",
            "/v2/inAppPurchases",
            {
                "data": {
                    "type": "inAppPurchases",
                    "attributes": {
                        "name": reference_name,
                        "productId": product_id,
                        "inAppPurchaseType": "NON_CONSUMABLE",
                        "familySharable": True,
                        "reviewNote": "Local StoreKit 2 non-consumable unlock verified on-device.",
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}}
                    },
                }
            },
        )
        iap_id = created["data"]["id"]
        print(f"Created IAP draft: {product_id} (id={iap_id})")
    else:
        print(f"IAP draft already exists: {product_id} (id={iap_id})")

    _, locs = client.request("GET", f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations")
    loc_id = next(
        (l["id"] for l in locs.get("data", []) if l["attributes"].get("locale") == "en-US"),
        None,
    )
    if loc_id:
        client.request(
            "PATCH",
            f"/v1/inAppPurchaseLocalizations/{loc_id}",
            {
                "data": {
                    "type": "inAppPurchaseLocalizations",
                    "id": loc_id,
                    "attributes": {"name": display_name, "description": description},
                }
            },
        )
    else:
        client.request(
            "POST",
            "/v1/inAppPurchaseLocalizations",
            {
                "data": {
                    "type": "inAppPurchaseLocalizations",
                    "attributes": {"locale": "en-US", "name": display_name, "description": description},
                    "relationships": {
                        "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}
                    },
                }
            },
        )

    # Global IAP availability
    st_av, cur_av = client.request(
        "GET",
        f"/v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability",
        allow_statuses=(200, 404),
    )
    if st_av != 200 or not cur_av.get("data"):
        client.request(
            "POST",
            "/v1/inAppPurchaseAvailabilities",
            {
                "data": {
                    "type": "inAppPurchaseAvailabilities",
                    "attributes": {"availableInNewTerritories": True},
                    "relationships": {
                        "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                        "availableTerritories": {
                            "data": [{"type": "territories", "id": t} for t in territory_ids]
                        },
                    },
                }
            },
        )
        print(f"  Set global availability for IAP {product_id}")

    # IAP USA price schedule
    st_ps, cur_ps = client.request(
        "GET",
        f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule?include=manualPrices",
        allow_statuses=(200, 404),
    )
    has_iap_manual = (
        st_ps == 200
        and isinstance(cur_ps.get("data"), dict)
        and len(cur_ps["data"].get("relationships", {}).get("manualPrices", {}).get("data", [])) > 0
    )
    if not has_iap_manual:
        pps = client.get_paginated(f"/v2/inAppPurchases/{iap_id}/pricePoints?filter[territory]=USA&limit=200")
        target_pp = next(
            (p["id"] for p in pps if f"{float(p['attributes'].get('customerPrice', -1)):.2f}" == usd_price),
            None,
        )
        if not target_pp:
            raise RuntimeError(f"USA price point {usd_price} not found for IAP {product_id}")
        client.request(
            "POST",
            "/v1/inAppPurchasePriceSchedules",
            {
                "data": {
                    "type": "inAppPurchasePriceSchedules",
                    "relationships": {
                        "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                        "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                        "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${price0}"}]},
                    },
                },
                "included": [
                    {
                        "type": "inAppPurchasePrices",
                        "id": "${price0}",
                        "attributes": {"startDate": None},
                        "relationships": {
                            "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}},
                            "inAppPurchasePricePoint": {
                                "data": {"type": "inAppPurchasePricePoints", "id": target_pp}
                            },
                        },
                    }
                ],
            },
        )
        print(f"  Set USD ${usd_price} price schedule for IAP {product_id}")

    # Ensure IAP review screenshot is attached
    _, cur_rev = client.request(
        "GET",
        f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot",
        allow_statuses=(200, 404),
    )
    has_complete = False
    if isinstance(cur_rev, dict) and cur_rev.get("data"):
        st = cur_rev["data"]["attributes"].get("assetDeliveryState", {}).get("state")
        if st in ("COMPLETE", "AWAITING_UPLOAD", "UPLOAD_COMPLETE"):
            has_complete = (st == "COMPLETE")
        if not has_complete:
            old_id = cur_rev["data"]["id"]
            client.request(
                "DELETE",
                f"/v1/inAppPurchaseAppStoreReviewScreenshots/{old_id}",
                allow_statuses=(200, 204, 404),
            )

    if not has_complete and review_screenshot.exists():
        raw = review_screenshot.read_bytes()
        md5_hex = hashlib.md5(raw).hexdigest()
        _, resv = client.request(
            "POST",
            "/v1/inAppPurchaseAppStoreReviewScreenshots",
            {
                "data": {
                    "type": "inAppPurchaseAppStoreReviewScreenshots",
                    "attributes": {"fileSize": len(raw), "fileName": review_screenshot.name},
                    "relationships": {
                        "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}
                    },
                }
            },
        )
        rev_id = resv["data"]["id"]
        upload_asset_binary(resv["data"]["attributes"]["uploadOperations"], raw)
        client.request(
            "PATCH",
            f"/v1/inAppPurchaseAppStoreReviewScreenshots/{rev_id}",
            {
                "data": {
                    "type": "inAppPurchaseAppStoreReviewScreenshots",
                    "id": rev_id,
                    "attributes": {"sourceFileChecksum": md5_hex, "uploaded": True},
                }
            },
        )
        print(f"  Attached review screenshot to IAP {product_id}")

    _, final_iap = client.request("GET", f"/v2/inAppPurchases/{iap_id}")
    print(f"ASC_IAP_STATE[{product_id}]={final_iap['data']['attributes'].get('state')} (id={iap_id})")


def stage_draft(client: ASCClient, build_number: str):
    app = find_app(client)
    if app is None:
        raise RuntimeError(f"App record not found for {BUNDLE_ID}")
    app_id = app["id"]
    review_contact = load_review_contact()

    build = wait_for_valid_build(client, app_id, build_number)
    build_id = build["id"]
    print(f"ASC_BUILD_ID={build_id}")

    # Export compliance
    if build["attributes"].get("usesNonExemptEncryption") is not False:
        client.request(
            "PATCH",
            f"/v1/builds/{build_id}",
            {
                "data": {
                    "type": "builds",
                    "id": build_id,
                    "attributes": {"usesNonExemptEncryption": False},
                }
            },
        )
        print("Set build usesNonExemptEncryption = false")

    # Find existing draft version ("1.0" / "1.0.0") or create it, and set "1.0.0"
    version = find_or_update_ios_version(client, app_id)
    version_id = version["id"]
    print(f"ASC_VERSION_ID={version_id}")

    # Attach build to App Store Version
    client.request(
        "PATCH",
        f"/v1/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
    )
    print(f"Attached build {build_id} to version {VERSION_STRING}")

    # Stage TestFlight internal testing
    stage_testflight_internal(client, app_id, build_id, review_contact)

    # Version localization (en-US)
    _, vlocs = client.request("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    vloc_id = next(
        (l["id"] for l in vlocs.get("data", []) if l["attributes"].get("locale") == "en-US"),
        None,
    )
    vloc_attrs = {
        "description": DESCRIPTION,
        "promotionalText": PROMO_TEXT,
        "keywords": KEYWORDS,
        "supportUrl": SUPPORT_URL,
        "marketingUrl": MARKETING_URL,
    }
    if vloc_id:
        client.request(
            "PATCH",
            f"/v1/appStoreVersionLocalizations/{vloc_id}",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": vloc_id,
                    "attributes": vloc_attrs,
                }
            },
        )
    else:
        _, created_vloc = client.request(
            "POST",
            "/v1/appStoreVersionLocalizations",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {"locale": "en-US", **vloc_attrs},
                    "relationships": {
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
                    },
                }
            },
        )
        vloc_id = created_vloc["data"]["id"]
    print(f"Updated en-US version localization ({vloc_id})")

    # App Info (privacyPolicyUrl, subtitle, categories, Content Rights, Age Rating)
    _, app_infos = client.request("GET", f"/v1/apps/{app_id}/appInfos")
    if app_infos.get("data"):
        app_info_id = app_infos["data"][0]["id"]
        _, ailocs = client.request("GET", f"/v1/appInfos/{app_info_id}/appInfoLocalizations")
        ailoc_id = next(
            (l["id"] for l in ailocs.get("data", []) if l["attributes"].get("locale") == "en-US"),
            None,
        )
        if ailoc_id:
            client.request(
                "PATCH",
                f"/v1/appInfoLocalizations/{ailoc_id}",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "id": ailoc_id,
                        "attributes": {
                            "subtitle": "Ray-Traced Voxel Sandbox",
                            "privacyPolicyUrl": PRIVACY_URL,
                        },
                    }
                },
            )

        category_set = False
        for rels in (
            {
                "primaryCategory": {"data": {"type": "appCategories", "id": "GAMES"}},
                "primarySubcategoryOne": {"data": {"type": "appCategories", "id": "GAMES_SIMULATION"}},
            },
            {"primaryCategory": {"data": {"type": "appCategories", "id": "GAMES"}}},
            {"primaryCategory": {"data": {"type": "appCategories", "id": "ENTERTAINMENT"}}},
        ):
            try:
                client.request(
                    "PATCH",
                    f"/v1/appInfos/{app_info_id}",
                    {"data": {"type": "appInfos", "id": app_info_id, "relationships": rels}},
                )
                print(f"Set categories: {list(rels.keys())}")
                category_set = True
                break
            except ASCHTTPError as e:
                print(f"Category attempt note: {e}")
        if not category_set:
            print("Warning: Could not update primaryCategory via API")

        stage_content_rights_and_age_rating(client, app_id, app_info_id)

    territory_ids = stage_pricing_and_availability(client, app_id)
    stage_review_detail(client, version_id, review_contact)

    # Upload 6.9" landscape screenshots (all 5 verified PNGs)
    shot_dir = Path("artifacts/screenshots")
    stage_screenshots(client, vloc_id, shot_dir)

    # Stage both Non-Consumable IAPs with availability + pricing + screenshot
    paywall_shot = shot_dir / "05_studio_paywall.png"
    if not paywall_shot.exists():
        paywall_shot = shot_dir / "04_glass_cathedral_paywall.png"

    stage_iap(
        client,
        app_id=app_id,
        product_id=f"{BUNDLE_ID}.pro",
        reference_name="Architect Pro",
        display_name="Architect Pro",
        description="Unlock Neon Cavern, Glass Cathedral & clean 4K photos.",
        usd_price="4.99",
        review_screenshot=paywall_shot,
        territory_ids=territory_ids,
    )
    stage_iap(
        client,
        app_id=app_id,
        product_id=f"{BUNDLE_ID}.materials.crystal",
        reference_name="Prism Material Pack",
        display_name="Prism Material Pack",
        description="Unlock refractive Prism Crystal voxels for sculpting.",
        usd_price="1.99",
        review_screenshot=paywall_shot,
        territory_ids=territory_ids,
    )

    # Final assertion: PREPARE_FOR_SUBMISSION Draft state (HARD STOP)
    _, final_ver = client.request("GET", f"/v1/appStoreVersions/{version_id}")
    state = final_ver["data"]["attributes"].get("appStoreState")
    print(f"FINAL_APP_STORE_STATE={state}")
    if state != "PREPARE_FOR_SUBMISSION":
        raise RuntimeError(f"Expected PREPARE_FOR_SUBMISSION, got {state}")
    print("App Store Connect 1.0.0 Draft + TestFlight staged cleanly. HARD STOP (not submitted).")


def main():
    parser = argparse.ArgumentParser(description="Stage VoxelRay 1.0.0 Draft & TestFlight in App Store Connect")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--prepare-app", action="store_true", help="Ensure Bundle ID & App record exist")
    group.add_argument("--stage-draft", action="store_true", help="Attach build, TestFlight, checks, screenshots, IAPs")
    parser.add_argument("--build-number", help="CFBundleVersion uploaded to ASC")
    args = parser.parse_args()

    key_id, issuer_id, key_path = load_credentials()
    client = ASCClient(key_id, issuer_id, key_path)

    if args.prepare_app:
        prepare_app(client)
    elif args.stage_draft:
        if not args.build_number:
            parser.error("--build-number is required with --stage-draft")
        stage_draft(client, args.build_number)


if __name__ == "__main__":
    main()
