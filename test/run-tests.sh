#!/usr/bin/env bash

## Compile and run test programs against an installed glibc.
## $1 : glibc prefix (e.g. /opt/compiler-explorer/glibc/2.42/x86_64-linux-gnu)
## $2 : expected version (e.g. 2.42)
## $3 : gcc install dir (e.g. /opt/compiler-explorer/gcc-14.2.0)
## $4 : clang install dir (optional)

set -uo pipefail
PREFIX="$1"
EXPECTED="$2"
GCC_DIR="$3"
CLANG_DIR="${4-}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
# All locales from locales.txt, by name
TEST_LOCALES=$(grep -v -e '^#' -e '^$' "${HERE}/../locales.txt" | cut -d' ' -f1 | tr '\n' ' ')
FAILURES=0

LINK_FLAGS=(-L"${PREFIX}/lib" -Wl,-rpath="${PREFIX}/lib"
    -Wl,--dynamic-linker="${PREFIX}/lib/ld-linux-x86-64.so.2")
# gcc: -isysroot replaces /usr/include (via the <prefix>/usr symlink) so libstdc++'s
# #include_next finds these headers; include-overrides beats gcc's include-fixed copies.
GCC_FLAGS=(-isystem "${PREFIX}/include-overrides" -isysroot "${PREFIX}" -B"${PREFIX}/lib" "${LINK_FLAGS[@]}")
# clang ignores -isysroot on Linux. --sysroot moves both headers and crt files to the prefix;
# libstdc++ has to be found explicitly because clang no longer looks outside the sysroot.
CLANG_FLAGS=(--gcc-toolchain="${GCC_DIR}" --sysroot="${PREFIX}" -L"${GCC_DIR}/lib64" "${LINK_FLAGS[@]}")
# gcc with a full --sysroot, as CE PR #8719 does. The linker scripts use bare names, so ld finds
# the libraries through -L/<sysroot>/lib rather than prefixing the sysroot to absolute paths.
GCC_SYSROOT_FLAGS=(--sysroot="${PREFIX}" -isystem "${PREFIX}/include-overrides" "${LINK_FLAGS[@]}")
# libstdc++/libgcc_s come from the compiler, as CE already does
GCC_RPATH=(-Wl,-rpath="${GCC_DIR}/lib64")

check() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: ${name}"
    else
        echo "FAIL: ${name}"
        FAILURES=$((FAILURES + 1))
    fi
}

run_expect() {
    local exe="$1"
    local output
    output=$(TEST_LOCALES="${TEST_LOCALES}" "${exe}") || { echo "${exe} exited non-zero:"; echo "${output}"; return 1; }
    echo "${output}" | sed 's/^/    /'
    echo "${output}" | grep -qx "version=${EXPECTED}" || return 1
    # C programs report the libc they mapped; it must be the prefix's (or none, if static)
    if echo "${output}" | grep -q '^libc='; then
        echo "${output}" | grep -qE "^libc=(static|${PREFIX}/lib/libc\.so\.6)$"
    fi
}

interp_is_prefix() {
    readelf -l "$1" | grep -q "interpreter: ${PREFIX}/lib/ld-linux-x86-64.so.2"
}

# Every glibc header must come from the prefix: not the host's /usr/include (e.g. via
# libstdc++'s #include_next <stdlib.h>) and not gcc's include-fixed copies.
headers_from_prefix() {
    local compiler="$1" source="$2"
    shift 2
    local leaks
    leaks=$("${compiler}" "$@" -M "${source}" | tr ' ' '\n' \
        | grep -E '^/usr/include/|include-fixed/.*(pthread|floatn|statx)')
    if [[ -n "${leaks}" ]]; then
        echo "${leaks}" | sed 's/^/    leaked: /'
        return 1
    fi
}

test_compiler() {
    local label="$1" cc="$2" cxx="$3"
    shift 3
    local GLIBC_FLAGS=("$@")
    echo "=== ${label}"
    check "${label}: C dynamic build" \
        "${cc}" "${GLIBC_FLAGS[@]}" -o "${OUT}/${label}-c" "${HERE}/test.c"
    check "${label}: C dynamic interpreter" interp_is_prefix "${OUT}/${label}-c"
    check "${label}: C dynamic run" run_expect "${OUT}/${label}-c"
    check "${label}: C headers all from prefix" headers_from_prefix "${cc}" "${HERE}/test.c" "${GLIBC_FLAGS[@]}"

    check "${label}: C static build" \
        "${cc}" "${GLIBC_FLAGS[@]}" -static -o "${OUT}/${label}-c-static" "${HERE}/test.c"
    check "${label}: C static run" run_expect "${OUT}/${label}-c-static"

    check "${label}: C++ build" \
        "${cxx}" "${GLIBC_FLAGS[@]}" "${GCC_RPATH[@]}" -o "${OUT}/${label}-cxx" "${HERE}/test.cpp"
    check "${label}: C++ interpreter" interp_is_prefix "${OUT}/${label}-cxx"
    check "${label}: C++ run" run_expect "${OUT}/${label}-cxx"
    check "${label}: C++ headers all from prefix" headers_from_prefix "${cxx}" "${HERE}/test.cpp" "${GLIBC_FLAGS[@]}"

    check "${label}: C++ static build" \
        "${cxx}" "${GLIBC_FLAGS[@]}" -static -o "${OUT}/${label}-cxx-static" "${HERE}/test.cpp"
    check "${label}: C++ static run" run_expect "${OUT}/${label}-cxx-static"

    # A host library with no rpath: found through the host dirs baked into ld.so. The sysroot
    # flags hide /usr/include, so the host's zlib.h needs -idirafter (after the prefix headers).
    check "${label}: host libz without rpath build" \
        "${cc}" "${GLIBC_FLAGS[@]}" -idirafter /usr/include -DUSE_ZLIB -o "${OUT}/${label}-zlib" "${HERE}/test.c" \
        -L/usr/lib/x86_64-linux-gnu -lz
    check "${label}: host libz without rpath run" run_expect "${OUT}/${label}-zlib"
}

test_compiler gcc "${GCC_DIR}/bin/gcc" "${GCC_DIR}/bin/g++" "${GCC_FLAGS[@]}"
test_compiler gcc-sysroot "${GCC_DIR}/bin/gcc" "${GCC_DIR}/bin/g++" "${GCC_SYSROOT_FLAGS[@]}"
if [[ -n "${CLANG_DIR}" ]]; then
    test_compiler clang "${CLANG_DIR}/bin/clang" "${CLANG_DIR}/bin/clang++" "${CLANG_FLAGS[@]}"
fi

rm -rf "${OUT}"
echo "failures: ${FAILURES}"
exit $((FAILURES > 0))
