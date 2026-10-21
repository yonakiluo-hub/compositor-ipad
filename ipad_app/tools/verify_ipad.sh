#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${COMPOSITOR_BUILD_DIR:-${TMPDIR:-/tmp}/compositor-ipad-verify}"
simulator_id="${1:-}"
if [[ -z "$simulator_id" ]]; then
  simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import sys,json; print(next(d["udid"] for group in json.load(sys.stdin)["devices"].values() for d in group if "iPad" in d["name"]))')"
fi
python3 "$project_dir/tools/generate_project.py" --test-products "$build_dir/Build/Products"
xcodebuild -project "$project_dir/CompositorPad.xcodeproj" \
  -target CompositorPadTests -target CompositorPadUITests \
  -configuration Debug -sdk iphonesimulator \
  SYMROOT="$build_dir/Build/Products" OBJROOT="$build_dir/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
# Fresh CI simulators must finish booting before XCTest launches the app.
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild test-without-building \
  -xctestrun "$build_dir/Build/Products/CompositorPad.xctestrun" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -parallel-testing-enabled NO
