#!/usr/bin/env bash
# ReSONANCE/Sakura Taisen 2 experimental PS4 homebrew build, sourced from public upstreams.
# No copyrighted Dreamcast BIOS, game files, or original PKG are used or uploaded.
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/run13_build.log") 2>&1
say(){ echo "[RUN13] $*"; }
WORK="$HOME/resonance-build"
FLY="$WORK/src/flycast"
RES="$WORK/Resonance"
SDK="$WORK/sdk-v2"
mkdir -p "$WORK/src" "$WORK/build" "$WORK/logs" "$WORK/out"
say "Clone tagged sources (no user's game files)"
git clone --depth 1 --branch v2.7 --recurse-submodules --jobs 4 https://github.com/flyinghead/flycast.git "$FLY"
git clone --depth 1 --branch v01.41 https://github.com/iHaiDeeZ/Resonance.git "$RES"
say "Apply ReSONANCE PS4 patch with Flycast 2.7 Vulkan hunk compatibility"
cp "$RES/patches/flycast-ps4.patch" "$WORK/ps4-port.patch"
python3 - "$WORK/ps4-port.patch" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='''@@ -151,6 +160,9 @@ bool VulkanContext::InitInstance(const char** extensions, uint32_t extensions_co
 \t\tvkGetInstanceProcAddr = loadVulkanDriver();
 #elif defined(__APPLE__) && defined(USE_SDL)
 \t\tvkGetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(SDL_Vulkan_GetVkGetInstanceProcAddr());
+#elif defined(__ORBIS__)
+\t\t// RADV is linked in: no loader to open
+\t\tvkGetInstanceProcAddr = ps4_vk_get_instance_proc_addr();
'''
new='''@@ -151,4 +160,7 @@ bool VulkanContext::InitInstance(const char** extensions, uint32_t extensions_co
 \t\tvkGetInstanceProcAddr = loadVulkanDriver();
+#elif defined(__ORBIS__)
+\t\t// RADV is linked in: no loader to open
+\t\tvkGetInstanceProcAddr = ps4_vk_get_instance_proc_addr();
'''
if s.count(old)!=1: raise SystemExit("Upstream PS4 Vulkan hunk changed; refusing unsafe patch")
p.write_text(s.replace(old,new))
PY
git -C "$FLY" apply --check "$WORK/ps4-port.patch"
git -C "$FLY" apply "$WORK/ps4-port.patch"
python3 "$GITHUB_WORKSPACE/resonance/run13_patch.py" "$FLY"
say "PS4 source ready, install Clang 21 and SDK prerequisites"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl git cmake ninja-build python3 unzip xz-utils tar pkg-config make build-essential libxml2 libtinfo6 zlib1g gnupg
if ! command -v clang-21 >/dev/null; then
  . /etc/os-release
  [[ "$VERSION_CODENAME" == noble ]] || { say "Ubuntu noble required for LLVM 21"; exit 70; }
  curl --retry 3 -fLsS https://apt.llvm.org/llvm-snapshot.gpg.key -o "$WORK/llvm.asc"
  gpg --dearmor < "$WORK/llvm.asc" > "$WORK/llvm.gpg"
  sudo install -m644 "$WORK/llvm.gpg" /usr/share/keyrings/llvm-run13.gpg
  echo 'deb [signed-by=/usr/share/keyrings/llvm-run13.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble-21 main' | sudo tee /etc/apt/sources.list.d/llvm-run13.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y clang-21 llvm-21 lld-21
fi
say "Fetch pinned public SDK snapshot"
curl -fL --retry 4 --retry-all-errors --connect-timeout 25 \
  -o "$WORK/ps4sx2-sdk-v2.tar.gz" \
  https://github.com/Phoenixx1202/PS4SX2-SDK/releases/download/sdk-v2/ps4sx2-sdk-v2.tar.gz
printf '%s  %s\n' \
  0d7261c3e6c8e8d8e2e71d13ee9f39bcba8936fa1d50dbfce6e279c3c4e99822 \
  "$WORK/ps4sx2-sdk-v2.tar.gz" | sha256sum -c -
mkdir -p "$SDK"
tar -xzf "$WORK/ps4sx2-sdk-v2.tar.gz" -C "$SDK"
export OPENORBIS="$SDK/linux/openorbis"
export PS4_BUILD_ROOT="$WORK"
export PS4_SYSROOT="$WORK/sysroot"
export FLYCAST_SRC="$FLY"
export CRM="$WORK/no-crema"
export JOBS=2
# SDK v2 is a curated export; it omits ps4vars.sh and Linux PkgTool.
# Create a transparent environment shim for CMake; real PKG packaging is a separate Windows job.
cat > "$OPENORBIS/ps4vars.sh" <<'EOENV'
export OO_PS4_TOOLCHAIN="$OPENORBIS"
export PATH="$OPENORBIS/bin:$PATH"
EOENV
for path in "$OPENORBIS/cmake/ps4.cmake" "$OPENORBIS/bin/create-fself" "$SDK/linux/sysroot/lib/libc++.a" "$SDK/linux/mesa/src/amd/vulkan/libvulkan_radeon.a"; do
  test -f "$path" || { say "MISSING SDK: $path"; exit 71; }
done
ln -s "$SDK/linux/sysroot" "$WORK/sysroot"
ln -s "$SDK/linux/mesa" "$WORK/build/mesa"
mkdir -p "$WORK/logs" "$WORK/oelf" "$WORK/out"
say "Inspect PS4 sysroot dependencies before compiling"
for dep in libnfs.a libsmb2.a libcurl.a libssl.a libcrypto.a libdolphinps4_rt.a libzstd.a liblz4.a; do
  test -e "$WORK/sysroot/lib/$dep" && echo "PRESENT $dep" || echo "MISSING $dep"
done
say "Build pinned PS4 netfs libs from their public source repositories"
git clone https://github.com/sahlberg/libnfs.git "$WORK/src/libnfs"
git -C "$WORK/src/libnfs" checkout 7613236464317bee2d9636f087f995148de4db27
git clone https://github.com/sahlberg/libsmb2.git "$WORK/src/libsmb2"
git -C "$WORK/src/libsmb2" checkout e94eee9465d55ed094ace2c038a8705b4822dada
bash "$RES/scripts/build-netfs.sh"
say "Netfs cross-compile complete"
say "Compile Flycast for PS4/FreeBSD ABI"
bash "$RES/scripts/configure-flycast.sh"
bash "$RES/scripts/build-flycast.sh" -k 0
EBOOT="$WORK/build/flycast/shell/ps4/flycast_eboot/eboot.bin"
test -s "$EBOOT" || { say "MISSING eboot.bin"; exit 72; }
mkdir -p "$GITHUB_WORKSPACE/run13_output"
cp "$EBOOT" "$GITHUB_WORKSPACE/run13_output/eboot.bin"
sha256sum "$GITHUB_WORKSPACE/run13_output/eboot.bin" | tee "$GITHUB_WORKSPACE/run13_output/SHA256SUMS.txt"
say "EBOOT_COMPILED; Linux SDK v2 has no PkgTool, Windows PKG packaging required."