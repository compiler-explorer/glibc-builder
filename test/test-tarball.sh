#!/usr/bin/env bash

## Extract a glibc tarball to its real /opt/compiler-explorer/glibc/... path inside a
## private user+mount namespace (an overlay over /opt/compiler-explorer), then run the tests.
## Nothing is written to the host's /opt/compiler-explorer.
## $1 : tarball (glibc-<triple>-<version>.tar.xz)
## $2 : gcc install dir (default /opt/compiler-explorer/gcc-14.2.0)
## $3 : clang install dir (optional)

set -euo pipefail
TARBALL=$(realpath "$1")
GCC_DIR="${2:-/opt/compiler-explorer/gcc-14.2.0}"
CLANG_DIR="${3-}"
HERE=$(cd "$(dirname "$0")" && pwd)

NAME=$(basename "${TARBALL}" .tar.xz)
NAME=${NAME#glibc-}
VERSION=${NAME##*-}
TRIPLE=${NAME%-*}
PREFIX=/opt/compiler-explorer/glibc/${VERSION}/${TRIPLE}

OVERLAY=$(mktemp -d)
trap 'rm -rf "${OVERLAY}"' EXIT
mkdir -p "${OVERLAY}/upper" "${OVERLAY}/work"

unshare --map-root-user --mount bash -euo pipefail -c '
    mount -t overlay overlay -o "lowerdir=/opt/compiler-explorer,upperdir=$1/upper,workdir=$1/work" /opt/compiler-explorer
    # A private tmpfs hides any glibc installed on the host (e.g. symlinks into read-only /cefs images)
    mkdir -p /opt/compiler-explorer/glibc
    mount -t tmpfs tmpfs /opt/compiler-explorer/glibc
    mkdir -p "$3"
    tar Jxf "$2" --no-same-owner --strip-components 2 -C "$3"
    "$4/run-tests.sh" "$3" "$5" "$6" "$7"
' _ "${OVERLAY}" "${TARBALL}" "${PREFIX}" "${HERE}" "${VERSION}" "${GCC_DIR}" "${CLANG_DIR}"
