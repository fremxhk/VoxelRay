#!/usr/bin/env bash
set -euo pipefail

export PATH="/Users/hokitcheung/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p artifacts/logs artifacts/Export

# Resolve ASC API credentials dynamically from environment, .env, or local config
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

eval "$(python3 - <<'PY'
import json, os, shlex
from pathlib import Path

key_id = os.environ.get("ASC_KEY_ID") or os.environ.get("APP_STORE_CONNECT_KEY_ID") or ""
issuer_id = os.environ.get("ASC_ISSUER_ID") or os.environ.get("APP_STORE_CONNECT_ISSUER_ID") or ""
key_path = os.environ.get("ASC_KEY_PATH") or os.environ.get("ASC_PRIVATE_KEY_PATH") or os.environ.get("APP_STORE_CONNECT_KEY_PATH") or ""

if not (key_id and issuer_id and key_path):
    cfg = Path.home() / ".config" / "cuiju-appstore" / "config.json"
    if cfg.exists():
        data = json.loads(cfg.read_text())
        key_id = key_id or data.get("key_id", "")
        issuer_id = issuer_id or data.get("issuer_id", "")
        key_path = key_path or data.get("private_key_path", "")

print(f"ASC_KEY_ID={shlex.quote(key_id)}")
print(f"ASC_ISSUER_ID={shlex.quote(issuer_id)}")
print(f"ASC_KEY_PATH={shlex.quote(key_path)}")
PY
)"

if [[ -z "$ASC_KEY_ID" || -z "$ASC_ISSUER_ID" || -z "$ASC_KEY_PATH" || ! -f "$ASC_KEY_PATH" ]]; then
  echo "ERROR: Missing ASC_KEY_ID, ASC_ISSUER_ID, or ASC_KEY_PATH (.p8)." >&2
  exit 1
fi

echo "==> [1/4] Verifying App Store Connect App record and next build number..."
PREP_OUT="$(python3 scripts/asc_stage_draft.py --prepare-app)"
echo "$PREP_OUT"
NEXT_BUILD="$(echo "$PREP_OUT" | awk -F= '/^NEXT_BUILD_NUMBER=/{print $2}')"
NEXT_BUILD="${NEXT_BUILD:-1}"
echo "Resolved NEXT_BUILD_NUMBER=$NEXT_BUILD"

echo "==> [2/4] Updating project.yml CURRENT_PROJECT_VERSION=$NEXT_BUILD and regenerating XcodeGen project..."
python3 - "$NEXT_BUILD" <<'PY'
import re, sys
from pathlib import Path
build_num = sys.argv[1]
p = Path("project.yml")
txt = p.read_text()
txt2 = re.sub(r'CURRENT_PROJECT_VERSION:\s*"?\d+"?', f'CURRENT_PROJECT_VERSION: "{build_num}"', txt)
p.write_text(txt2)
PY
xcodegen generate > artifacts/logs/xcodegen_release.log 2>&1

cat > artifacts/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>upload</string>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>3ZHSMUKPN8</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> [3/4] Archiving & uploading signed Release 1.0.0 ($NEXT_BUILD)..."
rm -rf artifacts/VoxelRay.xcarchive
xcodebuild archive \
  -project VoxelRay.xcodeproj \
  -scheme VoxelRay \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath artifacts/VoxelRay.xcarchive \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > artifacts/logs/archive_release.log 2>&1

xcodebuild -exportArchive \
  -archivePath artifacts/VoxelRay.xcarchive \
  -exportOptionsPlist artifacts/ExportOptions.plist \
  -exportPath artifacts/Export \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > artifacts/logs/export_upload.log 2>&1

echo "==> [4/4] Staging App Store Connect 1.0.0 Draft (PREPARE_FOR_SUBMISSION)..."
python3 scripts/asc_stage_draft.py --stage-draft --build-number "$NEXT_BUILD"
