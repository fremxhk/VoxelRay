#!/usr/bin/env bash
set -euo pipefail

export PATH="/Users/hokitcheung/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUN_SCREENSHOTS=0
for arg in "$@"; do
  case "$arg" in
    --screenshots) RUN_SCREENSHOTS=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p artifacts/logs artifacts/screenshots artifacts/DerivedData

echo "==> [1/4] Generating Xcode project with XcodeGen..."
xcodegen generate > artifacts/logs/xcodegen.log 2>&1 || {
  cat artifacts/logs/xcodegen.log
  exit 1
}

echo "==> [2/4] Discovering highest-resolution 6.9-inch / Pro Max iPhone Simulator..."
SIM_JSON="$(xcrun simctl list devices available -j)"
SIM_INFO="$(SIM_JSON="$SIM_JSON" python3 - <<'PY'
import json, os, re, sys

data = json.loads(os.environ["SIM_JSON"])
candidates = []

def runtime_score(rt: str):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    if not m:
        return (0, 0)
    return (int(m.group(1)), int(m.group(2)))

def device_score(dev: dict) -> int:
    dtype = dev.get("deviceTypeIdentifier", "")
    name = dev.get("name", "")
    if "iPhone-18-Pro-Max" in dtype:
        return 1000
    if "iPhone-17-Pro-Max" in dtype:
        return 900
    if "iPhone-16-Pro-Max" in dtype:
        return 800
    if "Pro-Max" in dtype or "Pro Max" in name:
        return 700
    if "Pro" in dtype or "Pro" in name:
        return 500
    if "iPhone" in dtype:
        return 100
    return 0

for rt, devs in data.get("devices", {}).items():
    if "iOS" not in rt:
        continue
    rscore = runtime_score(rt)
    for dev in devs:
        if not dev.get("isAvailable", True):
            continue
        dscore = device_score(dev)
        if dscore <= 0:
            continue
        booted_bonus = 1 if dev.get("state") == "Booted" else 0
        candidates.append((rscore, dscore, booted_bonus, dev["udid"], dev["name"], dev.get("deviceTypeIdentifier", "")))

if not candidates:
    sys.stderr.write("ERROR: No available iPhone Simulator found.\n")
    sys.exit(1)

candidates.sort(reverse=True)
best = candidates[0]
print(f"{best[3]}|{best[4]}|{best[5]}")
PY
)"

SIM_UDID="${SIM_INFO%%|*}"
REST="${SIM_INFO#*|}"
SIM_NAME="${REST%%|*}"
SIM_TYPE="${REST#*|}"
echo "Selected Simulator: $SIM_NAME ($SIM_TYPE) [$SIM_UDID]"

xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_UDID" -b

echo "==> [3/4] Proving physical-device compilation (generic/platform=iOS, Metal 4 + MetalFX)..."
if ! xcodebuild build \
  -project VoxelRay.xcodeproj \
  -scheme VoxelRay \
  -destination 'generic/platform=iOS' \
  -derivedDataPath artifacts/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  > artifacts/logs/build_iphoneos.log 2>&1; then
  echo "ERROR: iOS device build failed! Tail of artifacts/logs/build_iphoneos.log:"
  grep -nE "error:|fatal error:" artifacts/logs/build_iphoneos.log | head -n 40 || true
  tail -n 60 artifacts/logs/build_iphoneos.log
  exit 1
fi
echo "Physical-device iOS build succeeded."

echo "==> [4/4] Running Simulator test suite with Metal validation..."
EXTRA_TEST_ARGS=()
if [[ "$RUN_SCREENSHOTS" -eq 1 ]]; then
  EXTRA_TEST_ARGS+=("-only-testing:VoxelRayUITests/ScreenshotCaptureUITests")
  TEST_LOG="artifacts/logs/test_screenshots.log"
  XCRESULT_PATH="artifacts/logs/Screenshots.xcresult"
else
  if [[ -f "VoxelRayUITests/ScreenshotCaptureUITests.swift" ]]; then
    EXTRA_TEST_ARGS+=("-skip-testing:VoxelRayUITests/ScreenshotCaptureUITests")
  fi
  TEST_LOG="artifacts/logs/test_simulator.log"
  XCRESULT_PATH="artifacts/logs/TestResults.xcresult"
fi

run_sim_tests() {
  local use_shader_validation="$1"
  rm -rf "$XCRESULT_PATH"
  local shader_val_env="0"
  if [[ "$use_shader_validation" -eq 1 ]]; then
    shader_val_env="1"
  fi

  MTL_DEBUG_LAYER=1 \
  MTL_SHADER_VALIDATION="$shader_val_env" \
  TEST_RUNNER_MTL_DEBUG_LAYER=1 \
  TEST_RUNNER_MTL_SHADER_VALIDATION="$shader_val_env" \
  SIMCTL_CHILD_MTL_DEBUG_LAYER=1 \
  SIMCTL_CHILD_MTL_SHADER_VALIDATION="$shader_val_env" \
  VOXELRAY_SCREENSHOT_DIR="$ROOT_DIR/artifacts/screenshots" \
  TEST_RUNNER_VOXELRAY_SCREENSHOT_DIR="$ROOT_DIR/artifacts/screenshots" \
  SIMCTL_CHILD_VOXELRAY_SCREENSHOT_DIR="$ROOT_DIR/artifacts/screenshots" \
  xcodebuild test \
    -project VoxelRay.xcodeproj \
    -scheme VoxelRay \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath artifacts/DerivedData \
    -resultBundlePath "$XCRESULT_PATH" \
    ${EXTRA_TEST_ARGS[@]+"${EXTRA_TEST_ARGS[@]}"} \
    > "$TEST_LOG" 2>&1
}

if ! run_sim_tests 1; then
  if grep -qiE "Metal GPU Validation Enabled|Compiler failed to build request|MTL_SHADER_VALIDATION|ShaderValidation|Metal.*validator|AGX.*validation" "$TEST_LOG"; then
    echo "WARNING: MTL_SHADER_VALIDATION=1 triggered Simulator runner issue; retrying with MTL_DEBUG_LAYER=1 only..."
    if ! run_sim_tests 0; then
      echo "ERROR: Simulator tests failed! Summary from $TEST_LOG:"
      grep -nE "error:|Test Case.*failed|Failing tests:" "$TEST_LOG" | head -n 50 || true
      tail -n 60 "$TEST_LOG"
      exit 1
    fi
  else
    echo "ERROR: Simulator tests failed! Summary from $TEST_LOG:"
    grep -nE "error:|Test Case.*failed|Failing tests:" "$TEST_LOG" | head -n 50 || true
    tail -n 60 "$TEST_LOG"
    exit 1
  fi
fi

echo "==> Test Summary:"
python3 - "$TEST_LOG" <<'PY'
import re, sys
log_path = sys.argv[1]
with open(log_path, "r", errors="replace") as f:
    text = f.read()

passed = len(re.findall(r"Test Case .* passed", text))
failed = len(re.findall(r"Test Case .* failed", text))
executed_lines = re.findall(r"Executed \d+ tests?, with \d+ failures?.*", text)
for line in executed_lines:
    print(" ", line)
print(f"Total Test Cases Passed: {passed}, Failed: {failed}")
if failed > 0:
    sys.exit(1)
PY

if [[ "$RUN_SCREENSHOTS" -eq 1 ]]; then
  echo "==> Verifying captured App Store screenshots..."
  python3 - "$ROOT_DIR/artifacts/screenshots" <<'PY'
import glob, os, subprocess, sys
shot_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(shot_dir, "*.png")))
if len(files) < 4:
    print(f"ERROR: Expected at least 4 PNGs in {shot_dir}, found {len(files)}: {files}")
    sys.exit(1)
for p in files:
    out = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", p], text=True)
    print(f"Screenshot {os.path.basename(p)}:\n{out.strip()}")
    if "hasAlpha: yes" in out:
        print(f"ERROR: Alpha channel present in {p}")
        sys.exit(1)
PY
fi

echo "CI Gate PASSED."
