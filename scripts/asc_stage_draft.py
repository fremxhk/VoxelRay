#!/usr/bin/env python3
"""
Idempotent App Store Connect Draft Staging Utility for VoxelRay.
Strictly prepares App metadata, Build attachment, Screenshots, and IAP drafts
up to PREPARE_FOR_SUBMISSION. Never submits for App Review.
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
    "Tap to blast craters through sunlit travertine colonnades, sculpt glowing cyan and magenta "
    "caverns, or build with refractive dielectric glass and prism crystal. Powered by hardware-accelerated "
    "Metal ray tracing and thermally adaptive MetalFX upscaling, every bounce of sunlight, shadow, "
    "glass refraction, and neon emission converges right on your iPhone with zero servers or tracking.\n\n"
    "Key Features:\n"
    "- Multi-bounce Monte Carlo global illumination with analytical atmospheric sky\n"
    "- Tap-to-carve spherical destruction with tactile haptic feedback and instant world reset\n"
    "- Virtual thumbstick flight and intuitive touch pan-look camera\n"
    "- 64-sample Photo Mode convergence with instant iOS Share Sheet export\n"
    "- Optional Architect Pro and Prism Material Pack unlocks via StoreKit 2"
)

PROMO_TEXT = "Real-time Metal ray-traced destructible voxel worlds on iPhone."


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
        cfg_path = Path.home() / ".config" / "cuiju-appstore" / "config.json"
        if cfg_path.exists():
            cfg = json.loads(cfg_path.read_text())
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
    _, builds = client.request("GET", f"/v1/apps/{app_id}/builds?sort=-version&limit=10")
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


def stage_screenshots(client: ASCClient, loc_id: str, screenshot_dir: Path):
    pngs = sorted(screenshot_dir.glob("*.png"))
    if len(pngs) < 4:
        raise RuntimeError(f"Expected >=4 PNG screenshots in {screenshot_dir}, found {len(pngs)}")

    _, sets_res = client.request(
        "GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets"
    )
    existing_sets = {s["attributes"].get("screenshotDisplayType"): s["id"] for s in sets_res.get("data", [])}

    # Try APP_IPHONE_67 (standard 6.7"/6.9" slot) or APP_IPHONE_69 if required by 2868x1320
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

        # Clear any existing screenshots in this set so re-runs are idempotent
        _, old_shots = client.request("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots")
        for s in old_shots.get("data", []):
            client.request("DELETE", f"/v1/appScreenshots/{s['id']}", allow_statuses=(200, 204, 404))

        try:
            for png in pngs[:4]:
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
                # Poll until COMPLETE
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
    review_screenshot: Path,
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
                        "reviewNote": "Local StoreKit 2 non-consumable unlock tested on-device.",
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
    loc_id = None
    for l in locs.get("data", []):
        if l["attributes"].get("locale") == "en-US":
            loc_id = l["id"]
            break
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

    # Ensure IAP review screenshot is attached
    _, cur_rev = client.request(
        "GET",
        f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot",
        allow_statuses=(200, 404),
    )
    has_complete = False
    if isinstance(cur_rev, dict) and cur_rev.get("data"):
        st = cur_rev["data"]["attributes"].get("assetDeliveryState", {}).get("state")
        if st == "COMPLETE":
            has_complete = True
        else:
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


def stage_draft(client: ASCClient, build_number: str):
    app = find_app(client)
    if app is None:
        raise RuntimeError(f"App record not found for {BUNDLE_ID}")
    app_id = app["id"]

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

    # Find or create iOS 1.0.0 App Store Version
    _, vers = client.request(
        "GET",
        f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&filter[versionString]={VERSION_STRING}",
    )
    if vers.get("data"):
        version = vers["data"][0]
    else:
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
                        "copyright": "2026 VoxelRay",
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )
        version = created_ver["data"]
    version_id = version["id"]
    print(f"ASC_VERSION_ID={version_id}")

    # Attach build
    client.request(
        "PATCH",
        f"/v1/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
    )
    print(f"Attached build {build_id} to version {VERSION_STRING}")

    # Version localization (en-US)
    _, vlocs = client.request("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    vloc_id = None
    for l in vlocs.get("data", []):
        if l["attributes"].get("locale") == "en-US":
            vloc_id = l["id"]
            break
    if vloc_id:
        client.request(
            "PATCH",
            f"/v1/appStoreVersionLocalizations/{vloc_id}",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": vloc_id,
                    "attributes": {
                        "description": DESCRIPTION,
                        "promotionalText": PROMO_TEXT,
                        "keywords": KEYWORDS,
                        "supportUrl": SUPPORT_URL,
                        "marketingUrl": MARKETING_URL,
                    },
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
                    "attributes": {
                        "locale": "en-US",
                        "description": DESCRIPTION,
                        "promotionalText": PROMO_TEXT,
                        "keywords": KEYWORDS,
                        "supportUrl": SUPPORT_URL,
                        "marketingUrl": MARKETING_URL,
                    },
                    "relationships": {
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
                    },
                }
            },
        )
        vloc_id = created_vloc["data"]["id"]
    print(f"Updated en-US version localization ({vloc_id})")

    # App Info (privacyPolicyUrl + primary category)
    _, app_infos = client.request("GET", f"/v1/apps/{app_id}/appInfos")
    if app_infos.get("data"):
        app_info_id = app_infos["data"][0]["id"]
        _, ailocs = client.request("GET", f"/v1/appInfos/{app_info_id}/appInfoLocalizations")
        ailoc_id = None
        for l in ailocs.get("data", []):
            if l["attributes"].get("locale") == "en-US":
                ailoc_id = l["id"]
                break
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
        for cat_id in ("GAMES", "ENTERTAINMENT"):
            try:
                client.request(
                    "PATCH",
                    f"/v1/appInfos/{app_info_id}",
                    {
                        "data": {
                            "type": "appInfos",
                            "id": app_info_id,
                            "relationships": {
                                "primaryCategory": {"data": {"type": "appCategories", "id": cat_id}}
                            },
                        }
                    },
                )
                print(f"Set primary category: {cat_id}")
                break
            except ASCHTTPError as e:
                print(f"Category {cat_id} note: {e}")

    # Upload 6.9" landscape screenshots
    shot_dir = Path("artifacts/screenshots")
    stage_screenshots(client, vloc_id, shot_dir)

    # Stage both Non-Consumable IAPs
    paywall_shot = shot_dir / "04_glass_cathedral_paywall.png"
    stage_iap(
        client,
        app_id=app_id,
        product_id=f"{BUNDLE_ID}.pro",
        reference_name="Architect Pro",
        display_name="Architect Pro",
        description="Unlock Neon Cavern & Glass Cathedral biomes and watermark-free 4K Photo Mode.",
        review_screenshot=paywall_shot,
    )
    stage_iap(
        client,
        app_id=app_id,
        product_id=f"{BUNDLE_ID}.materials.crystal",
        reference_name="Prism Material Pack",
        display_name="Prism Material Pack",
        description="Unlock the refractive Prism Crystal brush for sculpting glowing glass voxels.",
        review_screenshot=paywall_shot,
    )

    # Final assertion: PREPARE_FOR_SUBMISSION Draft state (HARD STOP)
    _, final_ver = client.request("GET", f"/v1/appStoreVersions/{version_id}")
    state = final_ver["data"]["attributes"].get("appStoreState")
    print(f"FINAL_APP_STORE_STATE={state}")
    if state != "PREPARE_FOR_SUBMISSION":
        raise RuntimeError(f"Expected PREPARE_FOR_SUBMISSION, got {state}")
    print("App Store Connect 1.0.0 Draft staged cleanly. HARD STOP (not submitted).")


def main():
    parser = argparse.ArgumentParser(description="Stage VoxelRay 1.0.0 Draft in App Store Connect")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--prepare-app", action="store_true", help="Ensure Bundle ID & App record exist")
    group.add_argument("--stage-draft", action="store_true", help="Attach build, metadata, screenshots, IAPs")
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
