#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

RELEASE_VERSION="${1:-}"
RELEASE_VERSION="${RELEASE_VERSION#v}"
OUTPUT_DIR="${2:-$ROOT_DIR/dist/release-final}"
ALL_TACHYON_TARGETS="x86_64-unknown-linux-musl:x86_64 i686-unknown-linux-musl:i386_pentium4 aarch64-unknown-linux-musl:aarch64 armv7-unknown-linux-musleabihf:armv7 arm-unknown-linux-musleabi:armv6 riscv64gc-unknown-linux-musl:riscv64 mipsel-unknown-linux-musl:mipsel mips-unknown-linux-musl:mips"
TACHYON_TARGETS="${TACHYON_TARGETS:-aarch64-unknown-linux-musl:aarch64 x86_64-unknown-linux-musl:x86_64}"
if [[ "$TACHYON_TARGETS" == "all" ]]; then
  TACHYON_TARGETS="$ALL_TACHYON_TARGETS"
fi

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: $0 <x.y.z[-prerelease]> [output_dir]" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [[ "${SKIP_FE_BUILD:-0}" != "1" ]]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm is required to build fe-app-tachyon (set SKIP_FE_BUILD=1 to use prebuilt assets)" >&2
    exit 1
  fi
  echo "Building LuCI frontend assets..."
  pushd "$ROOT_DIR/fe-app-tachyon" >/dev/null
  if [[ ! -d node_modules ]]; then
    npm ci
  fi
  npm run build
  popd >/dev/null
fi

for pair in $TACHYON_TARGETS; do
  triple="${pair%%:*}"
  arch="${pair#*:}"
  if [[ -z "$triple" || -z "$arch" || "$triple" == "$arch" ]]; then
    echo "Invalid TACHYON_TARGETS entry: $pair (expected <rust-triple>:<openwrt-arch>)" >&2
    exit 1
  fi

  echo "Building tachyon for $arch ($triple)..."
  extra_args=()
  if [[ -n "${TACHYON_CARGO_EXTRA_ARGS:-}" ]]; then
    read -r -a extra_args <<< "${TACHYON_CARGO_EXTRA_ARGS}"
  fi
  TACHYON_BUILD_STD="${TACHYON_BUILD_STD:-1}"
  TACHYON_BUILD_COMMIT="${TACHYON_BUILD_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)}"
  build_env=(TACHYON_BUILD_VERSION="$RELEASE_VERSION" TACHYON_BUILD_COMMIT="$TACHYON_BUILD_COMMIT")
  if [[ "$TACHYON_BUILD_STD" == "1" && " ${TACHYON_CARGO_EXTRA_ARGS:-} " != *"build-std"* ]]; then
    build_env+=(RUSTC_BOOTSTRAP=1 CARGO_PROFILE_RELEASE_PANIC=immediate-abort)
    extra_args+=(-Z panic-immediate-abort -Z build-std=std,panic_abort -Z build-std-features=optimize_for_size)
  fi
  (
    cd "$ROOT_DIR"
    env "${build_env[@]}" cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release --target "$triple" ${extra_args[@]+"${extra_args[@]}"}
  )

  bin_path="$ROOT_DIR/target/$triple/release/tachyon"
  if [[ ! -f "$bin_path" ]]; then
    echo "Missing built binary: $bin_path" >&2
    exit 1
  fi

  base_name="tachyon-${arch}-v${RELEASE_VERSION}"
  python3 "$ROOT_DIR/tools/build_openwrt_pkg.py" \
    --bin "$bin_path" \
    --arch "$arch" \
    --version "$RELEASE_VERSION" \
    --init "$ROOT_DIR/openwrt/tachyon.init" \
    --hotplug "$ROOT_DIR/openwrt/99-tachyon-wan-monitor" \
    --views-dir "$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon" \
    --launcher-js "$ROOT_DIR/openwrt/launcher.js" \
    --launcher-menu "$ROOT_DIR/openwrt/tachyon-launcher.menu.json" \
    --launcher-acl "$ROOT_DIR/openwrt/tachyon-launcher.acl.json" \
    --out-ipk "$OUTPUT_DIR/${base_name}.ipk" \
    --out-apk "$OUTPUT_DIR/${base_name}.apk"
done

echo "Copying installer scripts and generating SHA256SUMS..."
cp -f "$ROOT_DIR/install.sh" "$ROOT_DIR/uninstall.sh" "$OUTPUT_DIR/"
(
  cd "$OUTPUT_DIR"
  rm -f SHA256SUMS
  sha256_files=()
  for f in tachyon-*.ipk tachyon-*.apk install.sh uninstall.sh; do
    [[ -e "$f" ]] && sha256_files+=("$f")
  done
  if [[ ${#sha256_files[@]} -gt 0 ]]; then
    sha256sum "${sha256_files[@]}" > SHA256SUMS
  fi
)

echo "Release artifacts ready in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
