#!/usr/bin/env bash
# ReSONANCE PS4 cloud build: original sources and original game files are untouched.
set -Eeuo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$RUNNER_TEMP/resonance-run12"
OUT="$PROJECT/build-output"
LOG="$OUT/run12.log"
mkdir -p "$BASE" "$OUT"
exec > >(tee "$LOG") 2>&1
STEP=init
finish() {
    rc=$?
    trap - EXIT
    printf 'step=%s\nexit_code=%s\npkg_created=%s\n' "$STEP" "$rc" "$([[ -s "$OUT/pkg/Resonance-v01.42.pkg" ]] && echo true || echo false)" > "$OUT/status.txt"
    if [[ -d "$BASE/buildroot/logs" ]]; then
        mkdir -p "$OUT/logs"
        cp -a "$BASE/buildroot/logs/." "$OUT/logs/" || true
    fi
    if [[ -d "$BASE/buildroot/build/flycast/CMakeFiles" ]]; then
        find "$BASE/buildroot/build/flycast/CMakeFiles" -maxdepth 3 -iname '*Error*log' -exec cp {} "$OUT/logs/" \; 2>/dev/null || true
    fi
    echo "RUN12 RESULT: step=$STEP exit=$rc"
    exit "$rc"
}
trap finish EXIT
echo "RUN12: fully cloud-hosted; no user Ubuntu/WSL installation"

STEP=clone-official-repositories
git clone --quiet --depth 1 --branch v2.7 --recurse-submodules --jobs 4 https://github.com/flyinghead/flycast.git "$BASE/flycast"
git clone --quiet --depth 1 --branch v01.41 https://github.com/iHaiDeeZ/Resonance.git "$BASE/resonance"
git -C "$BASE/flycast" submodule status --recursive | tee "$OUT/submodules.txt"
git -C "$BASE/resonance" rev-parse HEAD | tee "$OUT/resonance-commit.txt"
test "$(cat "$OUT/resonance-commit.txt")" = "6b87389033d4f239e97d36c605bf7eea384d1e23"

STEP=reconstruct-exact-run8-port-patch
python3 - "$BASE/resonance/patches/flycast-ps4.patch" "$BASE/ps4_port.patch" <<'PYREBASE'
import hashlib,sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:])
s=src.read_text()
old='@@ -151,6 +160,9 @@ bool VulkanContext::InitInstance(const char** extensions, uint32_t extensions_co'
new='@@ -151,4 +160,7 @@ bool VulkanContext::InitInstance(const char** extensions, uint32_t extensions_co'
context=' \t\tvkGetInstanceProcAddr = loadVulkanDriver();\n #elif defined(__APPLE__) && defined(USE_SDL)\n \t\tvkGetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(SDL_Vulkan_GetVkGetInstanceProcAddr());\n'
assert s.count(old)==1 and s.count(context)==1, 'v01.41 patch differs from audited source'
s=s.replace(old,new).replace(context,' \t\tvkGetInstanceProcAddr = loadVulkanDriver();\n')
dst.write_text(s)
digest=hashlib.sha256(dst.read_bytes()).hexdigest()
assert digest=='b89d9c83310db68891046c6cf0cc8e0d8f83437bd7707b2739438985ca4a7774', digest
print('RUN8 port patch exact SHA256:',digest)
PYREBASE

STEP=apply-reviewed-patches
git -C "$BASE/flycast" apply --check "$BASE/ps4_port.patch"
git -C "$BASE/flycast" apply "$BASE/ps4_port.patch"
git -C "$BASE/resonance" apply --check "$PROJECT/ps4-resonance-patches/01_safe_rebuild.patch"
git -C "$BASE/resonance" apply "$PROJECT/ps4-resonance-patches/01_safe_rebuild.patch"
for p in 01_st2_diagnostics 03_fpcb_bounds 04_fpcb_map_fail 05_fpcb_reset 07_fpcb_failure_propagation; do
    git -C "$BASE/flycast" apply --check "$PROJECT/ps4-resonance-patches/$p.patch"
    git -C "$BASE/flycast" apply "$PROJECT/ps4-resonance-patches/$p.patch"
done
git -C "$BASE/flycast" diff --stat | tee "$OUT/patched-source-stat.txt"
echo "Sources patched; unchanged original game and PKG."

STEP=download-verified-ps4-sdk
SDK_URL="https://github.com/Phoenixx1202/PS4SX2-SDK/releases/download/sdk-v2/ps4sx2-sdk-v2.tar.gz"
SDK_SHA="0d7261c3e6c8e8d8e2e71d13ee9f39bcba8936fa1d50dbfce6e279c3c4e99822"
curl --fail --location --retry 3 --connect-timeout 30 --output "$BASE/ps4sx2-sdk-v2.tar.gz" "$SDK_URL"
echo "$SDK_SHA  $BASE/ps4sx2-sdk-v2.tar.gz" | sha256sum -c -
mkdir -p "$BASE/sdk"
tar -xzf "$BASE/ps4sx2-sdk-v2.tar.gz" -C "$BASE/sdk"

STEP=validate-sdk-and-mesa
export OPENORBIS="$BASE/sdk/linux/openorbis"
export PS4_BUILD_ROOT="$BASE/buildroot"
export FLYCAST_SRC="$BASE/flycast"
export JOBS=2
export RESONANCE_VERSION=01.42
mkdir -p "$PS4_BUILD_ROOT/build" "$PS4_BUILD_ROOT/logs" "$PS4_BUILD_ROOT/out" "$PS4_BUILD_ROOT/oelf"
for p in "$OPENORBIS/ps4vars.sh" "$OPENORBIS/cmake/ps4.cmake" "$BASE/sdk/linux/sysroot/lib/libc++.a" "$BASE/sdk/linux/mesa/src/amd/vulkan/libvulkan_radeon.a"; do
    if [[ ! -e "$p" ]]; then echo "MISSING PS4 SDK/Mesa dependency: $p" >&2; exit 45; fi
done
ln -s "$BASE/sdk/linux/sysroot" "$PS4_BUILD_ROOT/sysroot"
ln -s "$BASE/sdk/linux/mesa" "$PS4_BUILD_ROOT/build/mesa"

STEP=install-clang-21
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends curl ca-certificates gnupg cmake ninja-build python3 git pkg-config libxml2 libtinfo6
if ! command -v clang-21 >/dev/null 2>&1; then
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/llvm-run12.gpg
    echo 'deb [signed-by=/usr/share/keyrings/llvm-run12.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble-21 main' | sudo tee /etc/apt/sources.list.d/llvm-run12.list
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends clang-21 llvm-21 lld-21
fi
command -v clang++-21

STEP=actual-ps4-cmake-compile-link
bash "$BASE/resonance/scripts/rebuild-flycast.sh"

STEP=actually-package-ps4
bash "$BASE/resonance/scripts/package-resonance.sh"
EBOOT="$PS4_BUILD_ROOT/build/flycast/shell/ps4/flycast_eboot/eboot.bin"
PKG="$BASE/resonance/out/Resonance-v01.42.pkg"
test -s "$EBOOT"
test -s "$PKG"
mkdir -p "$OUT/pkg"
cp -n "$EBOOT" "$PKG" "$OUT/pkg/"
sha256sum "$OUT/pkg/"* > "$OUT/pkg/SHA256SUMS.txt"
STEP=pkg-created-hardware-untested
echo "PKG CANDIDATE CREATED. First battle remains UNTESTED on PS4."
