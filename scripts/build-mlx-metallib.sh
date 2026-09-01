#!/bin/bash
# Compile mlx-swift's default Metal library. `swift build` links Cmlx but does
# not emit default.metallib; without it the assembled app dies at launch:
#   Failed to load the default metallib. library not found
#
# MLX looks next to the executable first, then in mlx-swift_Cmlx.bundle.
# The app assembler installs the bundle under Contents/Resources (not MacOS —
# a loose metallib next to the binary fails codesign as unsigned nested code).
#
#   scripts/build-mlx-metallib.sh .build/release/mlx.metallib
set -euo pipefail

OUTPUT="${1:?usage: scripts/build-mlx-metallib.sh <output.metallib> [Parrot.app]}"
APP="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="$ROOT/.build/checkouts/mlx-swift"
KERNELS="$CHECKOUT/Source/Cmlx/mlx/mlx/backend/metal/kernels"

if [[ ! -d "$KERNELS" ]]; then
  echo "mlx-swift checkout missing at $CHECKOUT — run swift build first." >&2
  exit 1
fi

METAL=$(xcrun -sdk macosx -find metal)
METALLIB=$(xcrun -sdk macosx -find metallib)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

metal_version=$(
  printf '%s\n' '__METAL_VERSION__' |
    "${METAL}" "-mmacosx-version-min=${DEPLOYMENT_TARGET}" -E -x metal -P - |
    tail -1 |
    tr -d '[:space:]'
)
metal_version=${metal_version:-0}

# Same JIT kernel set mlx-swift ships in default.metallib (CMake MLX_METAL_JIT=ON).
kernels=(
  arg_reduce
  conv
  gemv
  layer_norm
  random
  rms_norm
  rope
  scaled_dot_product_attention
)
if (( metal_version >= 320 )); then
  kernels+=(fence)
fi

if (( metal_version >= 310 )); then
  VERSION_INCLUDES="$KERNELS/metal_3_1"
else
  VERSION_INCLUDES="$KERNELS/metal_3_0"
fi

metal_flags=(
  -x metal
  -Wall
  -Wextra
  -fno-fast-math
  -Wno-c++17-extensions
  -Wno-c++20-extensions
  -mmacosx-version-min="${DEPLOYMENT_TARGET}"
  -I "$CHECKOUT/Source/Cmlx/mlx"
  -I "$VERSION_INCLUDES"
)

if (( metal_version >= 400 )); then
  metal_flags+=(-std=metal4.0)
elif (( metal_version >= 320 )); then
  metal_flags+=(-std=metal3.2)
elif (( metal_version >= 310 )); then
  metal_flags+=(-std=metal3.1)
elif (( metal_version >= 300 )); then
  metal_flags+=(-std=metal3.0)
fi

air_files=()
for kernel in "${kernels[@]}"; do
  source="${KERNELS}/${kernel}.metal"
  air="${TMP_DIR}/${kernel}.air"
  "${METAL}" "${metal_flags[@]}" -c "${source}" -o "${air}"
  air_files+=("${air}")
done

mkdir -p "$(dirname "${OUTPUT}")"
"${METALLIB}" "${air_files[@]}" -o "${TMP_DIR}/mlx.metallib"
mv "${TMP_DIR}/mlx.metallib" "${OUTPUT}"

if [[ -n "$APP" ]]; then
  BUNDLE="$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
  mkdir -p "$BUNDLE/Contents/Resources"
  cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>com.uygar.parrot.mlx-swift-cmlx</string>
	<key>CFBundleName</key><string>mlx-swift_Cmlx</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
  cp "${OUTPUT}" "$BUNDLE/Contents/Resources/default.metallib"
fi
