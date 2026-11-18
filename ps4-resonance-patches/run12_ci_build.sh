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

STEP=inventory-sdk-layout
python3 - "$BASE/sdk" "$OUT/sdk-layout.txt" <<'PYINV'
from pathlib import Path
import sys
root=Path(sys.argv[1]); dest=Path(sys.argv[2])
patterns=['**/ps4vars.sh','**/ps4.cmake','**/PkgTool.Core','**/create-fself','**/libc++.a','**/libc++abi.a','**/libvulkan_radeon.a','**/clang*','**/*.prx']
with dest.open('w') as o:
    for pattern in patterns:
        found=list(root.glob(pattern))
        print(f'{pattern}: {len(found)}',file=o)
        for path in found[:25]: print('  '+str(path.relative_to(root)),file=o)
    print('Top-level SDK entries:',file=o)
    for path in sorted(root.iterdir()): print('  '+str(path.relative_to(root)),file=o)
print(dest.read_text())
PYINV
STEP=adapt-sdk-build-environment
export OPENORBIS="$BASE/sdk/linux/openorbis"
export PS4_BUILD_ROOT="$BASE/buildroot"
export FLYCAST_SRC="$BASE/flycast"
export JOBS=2
export RESONANCE_VERSION=01.42
export PS4_SYSROOT="$PS4_BUILD_ROOT/sysroot"
mkdir -p "$PS4_BUILD_ROOT/build" "$PS4_BUILD_ROOT/logs" "$PS4_BUILD_ROOT/out" "$PS4_BUILD_ROOT/oelf"
for p in "$OPENORBIS/cmake/ps4.cmake" "$OPENORBIS/bin/create-fself" "$BASE/sdk/linux/sysroot/lib/libc++.a" "$BASE/sdk/linux/mesa/src/amd/vulkan/libvulkan_radeon.a"; do
    if [[ ! -e "$p" ]]; then echo "MISSING PS4 SDK/Mesa dependency: $p" >&2; exit 45; fi
done
if [[ ! -f "$OPENORBIS/ps4vars.sh" ]]; then
    # The SDK-v2 snapshot omits PacBrew ps4vars.sh. Only provide its env setup,
    # never invent a missing compiler, linker or PS4 library.
    printf '%s\n' 'export OO_PS4_TOOLCHAIN="$OPENORBIS"' 'export PATH="$OPENORBIS/bin:$OPENORBIS/bin/linux:$PATH"' > "$OPENORBIS/ps4vars.sh"
    echo 'Created build-only environment adapter for missing ps4vars.sh'
fi
ln -s "$BASE/sdk/linux/sysroot" "$PS4_BUILD_ROOT/sysroot"
ln -s "$BASE/sdk/linux/mesa" "$PS4_BUILD_ROOT/build/mesa"
if [[ ! -e "$OPENORBIS/bin/linux/PkgTool.Core" ]]; then
    echo 'Packaging tool absent: will still attempt actual PS4 compilation; PKG needs separate packaging backend.'
fi

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

STEP=rebuild-ps4-nfs-and-smb-libraries
# These static libraries are missing from the 127MB SDK v2 snapshot.
# Use the exact commits specified by upstream ReSONANCE patches/BASE.txt.
if [[ ! -s "$PS4_BUILD_ROOT/sysroot/lib/libnfs.a" || ! -s "$PS4_BUILD_ROOT/sysroot/lib/libsmb2.a" ]]; then
  mkdir -p "$PS4_BUILD_ROOT/src"
  git clone --quiet https://github.com/sahlberg/libnfs.git "$PS4_BUILD_ROOT/src/libnfs"
  git -C "$PS4_BUILD_ROOT/src/libnfs" checkout --quiet 7613236464317bee2d9636f087f995148de4db27
  git clone --quiet https://github.com/sahlberg/libsmb2.git "$PS4_BUILD_ROOT/src/libsmb2"
  git -C "$PS4_BUILD_ROOT/src/libsmb2" checkout --quiet e94eee9465d55ed094ace2c038a8705b4822dada
  STEP=patch-target-specific-ipv6-sockaddr-guard
  python3 - "$PS4_BUILD_ROOT/src/libnfs/lib/socket.c" <<'PYNET'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]);s=p.read_text()
targets=('sin6->sin6_len', '((struct sockaddr_in6 *)&rpc->s)->sin6_len')
for target in targets:
    patt=r'(?m)^([ \t]*)#ifdef HAVE_SOCKADDR_LEN(?=\n[ \t]*'+re.escape(target)+')'
    s,n=re.subn(patt, lambda m:m.group(1)+'#if defined(HAVE_SOCKADDR_LEN) && !defined(__ORBIS__)', s)
    assert n==1,(target,n)
p.write_text(s)
print('PS4 IPv6 sockaddr structure compatibility guards applied: 2')
PYNET
  STEP=rebuild-ps4-nfs-and-smb-libraries
  bash "$BASE/resonance/scripts/build-netfs.sh"
  test -s "$PS4_BUILD_ROOT/sysroot/lib/libnfs.a"
  test -s "$PS4_BUILD_ROOT/sysroot/lib/libsmb2.a"
fi
echo 'PS4 static NFS and SMB libraries ready'

STEP=build-missing-ps4-openssl-and-curl
if [[ ! -s "$PS4_SYSROOT/lib/libssl.a" || ! -s "$PS4_SYSROOT/lib/libcrypto.a" ]]; then
  echo 'Missing PS4 OpenSSL archives: compiling OpenSSL 1.1.1w for x86_64 FreeBSD PS4 target'
  git clone --quiet --depth 1 --branch OpenSSL_1_1_1w https://github.com/openssl/openssl.git "$PS4_BUILD_ROOT/src/openssl"
  python3 - "$PS4_BUILD_ROOT/src/openssl/crypto/bio/bss_dgram.c" <<'PYSSL'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
old='# if defined(__FreeBSD__) && defined(IN6_IS_ADDR_V4MAPPED)'
new=old+' && !defined(__ORBIS__)'
assert s.count(old)==1
p.write_text(s.replace(old,new))
print('OpenSSL PS4 IPv6 in6_addr compatibility guard installed')
PYSSL
  (
    cd "$PS4_BUILD_ROOT/src/openssl"
    export CC=clang-21 AR=llvm-ar-21 RANLIB=llvm-ranlib-21
    export CFLAGS="-target x86_64-pc-freebsd12-elf -D__ORBIS__ -D__PS4__ -D__OPENORBIS__ -fPIC --sysroot=$OPENORBIS -I$OPENORBIS/include -I$PS4_SYSROOT/include"
    ./Configure BSD-x86_64 no-shared no-asm no-tests no-dso no-threads no-idea no-md2 --prefix="$PS4_SYSROOT" --openssldir="$PS4_SYSROOT/etc/ssl"
    make -j2 build_libs
    make install_sw
  )
fi
test -s "$PS4_SYSROOT/lib/libssl.a"
test -s "$PS4_SYSROOT/lib/libcrypto.a"
if [[ ! -s "$PS4_SYSROOT/lib/libcurl.a" ]]; then
  echo 'Missing PS4 libcurl archive: compiling curl with OpenSSL and minimal protocols'
  git clone --quiet --depth 1 --branch curl-8_10_1 https://github.com/curl/curl.git "$PS4_BUILD_ROOT/src/curl"
  cmake -S "$PS4_BUILD_ROOT/src/curl" -B "$PS4_BUILD_ROOT/build/curl" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$BASE/resonance/toolchain/ps4-deps.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PS4_SYSROOT" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
    -DCURL_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$PS4_SYSROOT" \
    -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
    -DCURL_USE_LIBIDN2=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
    -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_GOPHER=ON -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_SMTP=ON -DCURL_DISABLE_TELNET=ON \
    -DCURL_DISABLE_TFTP=ON -DCURL_DISABLE_RTSP=ON -DCURL_DISABLE_MQTT=ON
  ninja -C "$PS4_BUILD_ROOT/build/curl" -j2
  ninja -C "$PS4_BUILD_ROOT/build/curl" install
fi
for archive in libcurl.a libssl.a libcrypto.a; do
  test -s "$PS4_SYSROOT/lib/$archive" || { echo "MISSING: $archive after source build"; exit 48; }
  ls -lh "$PS4_SYSROOT/lib/$archive"
done

STEP=fix-original-logrun-path
# ReSONANCE logrun.sh always writes under $HOME/resonance-build/logs,
# while our ephemeral GitHub build uses $PS4_BUILD_ROOT/logs.
# Point both to one location so errors are retained and printed.
if [[ -e "$HOME/resonance-build" && ! -L "$HOME/resonance-build" ]]; then
  echo "ERROR: refusing to replace existing $HOME/resonance-build" >&2; exit 47
fi
ln -sfn "$PS4_BUILD_ROOT" "$HOME/resonance-build"
echo "Merged ReSONANCE logrun output path into ephemeral PS4_BUILD_ROOT"

STEP=actual-ps4-cmake-compile-link
# Explicitly use the extracted Mesa static build, not a nonexisting HOME/resonance-build copy.
sed -i 's|-DUSE_VULKAN=ON|-DPS4_MESA_BUILD="$PS4_BUILD_ROOT/build/mesa" -DUSE_VULKAN=ON|' "$BASE/resonance/scripts/configure-flycast.sh"
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
