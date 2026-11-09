#!/usr/bin/env bash
# Build socket.ext.so for CS:S v34 servers on SourceMod 1.13 (fmu1337/sourcemod-css34),
# extension API of that SourceMod. Runs inside manylinux2014_i686 (devtoolset-10 GCC
# 10.2.1, glibc 2.17): see .github/workflows/css34.yml.
# Output: dist/socket-<ver>-sm13-css34-linux.tar.gz (cstrike/ layout) + SHA256SUMS.
#
# Changes to the upstream sources, made here on a copy so the tree stays upstream:
#   - sdk/smsdk_ext.h / .cpp come from SourceMod 1.13 public/ (upstream ships an old
#     smsdk_ext.cpp; its smsdk_config.h is kept), so the extension API matches.
#   - boost::thread / mutex / shared_mutex and their locks become C++17 std:: types,
#     so no boost library is compiled or linked; asio stays header-only.
# (Moved here from fmu1337/sourcemod-css34 builder/third-party/socket.sh.)
#
#   ci/build.sh [SRC=repo root] [DIST=SRC/dist]
set -euo pipefail

SRC0="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
DIST="${2:-$SRC0/dist}"
DEPS="${DEPS:-/tmp/socket-deps}"
CC="${CC:-gcc}"
CXX="${CXX:-g++}"

CSS34_TAG="1.13.0.7478-mm1.12.0-r7"
BOOST_VERSION="1.83.0"
BOOST_URL="https://archives.boost.io/release/1.83.0/source/boost_1_83_0.tar.bz2"
BOOST_SHA256="6478edfe2f3305127cffe8caf73ea0176c53769f4bf1585be237eb30798c3b8e"

die() { echo "FAIL: $*" >&2; exit 1; }
gcc_line="$("$CXX" --version | head -1)"
[[ "$(uname -m)" == i686 && "$("$CXX" -dumpmachine)" == i686-* ]] ||
  die "must build for i686 (uname=$(uname -m) dumpmachine=$("$CXX" -dumpmachine))"
VERSION="$(sed -nE 's/^#define SMEXT_CONF_VERSION[[:space:]]+"([^"]+)".*/\1/p' "$SRC0/sdk/smsdk_config.h")"
[[ -n "$VERSION" ]] || die "no SMEXT_CONF_VERSION in sdk/smsdk_config.h"
SRC_COMMIT="$(git -C "$SRC0" rev-parse HEAD 2>/dev/null || echo unknown)"
mkdir -p "$DEPS"

echo "==> SourceMod 1.13 of sourcemod-css34 ${CSS34_TAG}" >&2
CSS34="$DEPS/sourcemod-css34"
rm -rf "$CSS34"
git clone -q --depth 1 -b "$CSS34_TAG" https://github.com/fmu1337/sourcemod-css34 "$CSS34"
SERIES="$CSS34/builder/patches/series/sm13-latest"
SOURCEMOD_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$SERIES/series.json")"
SM="$DEPS/sourcemod-1.13"
bash "$CSS34/builder/fetch-sourcemod.sh" "$SM" "$SOURCEMOD_COMMIT"
bash "$CSS34/builder/patches/apply-series.sh" "$SERIES" "$SM"
api="$(sed -nE 's/^[[:space:]]*#define[[:space:]]+SMINTERFACE_EXTENSIONAPI_VERSION[[:space:]]+([0-9]+).*/\1/p' "$SM/public/IExtensionSys.h")"

echo "==> boost ${BOOST_VERSION} headers" >&2
BOOST="$DEPS/boost_${BOOST_VERSION//./_}"
if [[ ! -d "$BOOST/boost" ]]; then
  curl -fsSL --retry 3 -o "$BOOST.tar.bz2" "$BOOST_URL"
  [[ "$(sha256sum "$BOOST.tar.bz2" | awk '{print $1}')" == "$BOOST_SHA256" ]] || die "boost sha256 mismatch"
  tar -xjf "$BOOST.tar.bz2" -C "$DEPS" "boost_${BOOST_VERSION//./_}/boost"
  rm -f "$BOOST.tar.bz2"
fi

# Work on a copy: SDK files and the C++17 rewrite.
SRC="$DEPS/src"
rm -rf "$SRC"; mkdir -p "$SRC"
cp -r "$SRC0"/*.cpp "$SRC0"/*.h "$SRC0/sdk" "$SRC0/scripting" "$SRC0/LICENSE" "$SRC"/
cp -f "$SM/public/smsdk_ext.h" "$SM/public/smsdk_ext.cpp" "$SRC/sdk/"
(
  cd "$SRC"
  sed -i -E \
    -e 's@#include <boost/thread\.hpp>@#include <thread>\n#include <mutex>\n#include <shared_mutex>@' \
    -e '/#include <boost\/thread\/shared_mutex\.hpp>/d' \
    -e 's/boost::mutex::scoped_lock/std::unique_lock<std::mutex>/g' \
    -e 's/boost::(thread|mutex|shared_mutex|shared_lock|unique_lock)\b/std::\1/g' \
    ./*.cpp ./*.h
  if grep -nE 'boost::(thread|mutex|shared_mutex|shared_lock|unique_lock|this_thread)|boost/thread' ./*.cpp ./*.h; then
    die "boost thread types left after the C++17 rewrite"
  fi
)

echo "==> Compiling socket.ext.so ${VERSION} (extension API ${api})" >&2
OBJ="$DEPS/obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"
CXXFLAGS=(
  -std=c++17 -O2 -fPIC -pipe -m32 -msse -mfpmath=sse
  -fvisibility=hidden -fvisibility-inlines-hidden -fno-strict-aliasing
  -Wall -Wno-unused -Wno-switch -Wno-deprecated-declarations
  -DLINUX -D_LINUX -DPOSIX -DGNUC -DCOMPILER_GCC -DHAVE_STDINT_H -DNDEBUG
  -DBOOST_BIND_GLOBAL_PLACEHOLDERS -DBOOST_ASIO_NO_TS_EXECUTORS
  -DBOOST_ERROR_CODE_HEADER_ONLY -DBOOST_SYSTEM_NO_DEPRECATED
  -I"$SRC" -I"$SRC/sdk"
  -I"$SM/public" -I"$SM/public/extensions" -I"$SM/sourcepawn/include"
  -I"$SM/public/amtl" -I"$SM/public/amtl/amtl"
  -isystem "$BOOST"
)
objs=()
for s in Extension.cpp Socket.cpp SocketHandler.cpp Callback.cpp CallbackHandler.cpp sdk/smsdk_ext.cpp; do
  o="$OBJ/$(basename "${s%.cpp}").o"
  "$CXX" "${CXXFLAGS[@]}" -c "$SRC/$s" -o "$o"
  objs+=("$o")
done
# Static libstdc++/libgcc; only GetSMExtAPI exported; -z defs: nothing outside libc/libpthread/libm.
printf '{\n  global: GetSMExtAPI;\n  local: *;\n};\n' >"$OBJ/exports.map"
"$CXX" -m32 -shared -o "$OBJ/socket.ext.so" "${objs[@]}" \
  -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL -Wl,--version-script="$OBJ/exports.map" \
  -Wl,-z,defs -Wl,--as-needed -lpthread -lm

so="$OBJ/socket.ext.so"
readelf -h "$so" | grep -q 'Machine:.*80386' || die "not i386"
if readelf -d "$so" | grep -E 'NEEDED.*(libstdc\+\+|libgcc_s)'; then die "needs libstdc++/libgcc_s"; fi
exports="$(readelf -W --dyn-syms "$so" | awk '$5=="GLOBAL" && $7!="UND" {print $8}' | sed 's/@.*//' | sort -u | tr '\n' ' ')"
[[ "$exports" == "GetSMExtAPI " ]] || die "exports [${exports}], want only GetSMExtAPI"
maxg="$(readelf -W --dyn-syms "$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)"
[[ "$(printf '%s\n2.17\n' "$maxg" | sort -V | tail -1)" == 2.17 ]] || die "needs GLIBC_${maxg} > 2.17"
echo "OK: socket.ext.so: i386, exports GetSMExtAPI only, glibc <= 2.17" >&2

rm -rf "$DIST"; mkdir -p "$DIST"
st="$DEPS/stage"; smd="$st/addons/sourcemod"
rm -rf "$st"; mkdir -p "$smd"/{extensions,scripting/include,licenses/socket}
install -m 0755 "$so" "$smd/extensions/socket.ext.so"
install -m 0644 "$SRC/scripting/include/socket.inc" "$smd/scripting/include/socket.inc"
install -m 0644 "$SRC/LICENSE" "$smd/licenses/socket/LICENSE"
python3 - "$smd/licenses/socket/build.json" "$VERSION" "$SRC_COMMIT" "$SOURCEMOD_COMMIT ($CSS34_TAG)" "$api" "$gcc_line" <<'PY'
import json, sys
out, ver, commit, smc, api, cc = sys.argv[1:7]
json.dump({"name": "Socket", "version": ver, "source": "https://github.com/fmu1337/sm-ext-socket",
           "source_commit": commit, "boost": "1.83.0 (headers)", "sm_commit": smc,
           "extension_api": int(api), "compiler": cc}, open(out, "w"), indent=2, sort_keys=True)
PY
tar --owner=0 --group=0 -czf "$DIST/socket-${VERSION}-sm13-css34-linux.tar.gz" -C "$st" addons
cp "$so" "$DIST/socket.ext.so"
(cd "$DIST" && sha256sum -- * > SHA256SUMS && cat SHA256SUMS)
