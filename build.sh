#!/usr/bin/env bash

## $1 : <triple>-<version> (e.g. x86_64-linux-gnu-2.42, aarch64-linux-gnu-2.42)
## $2 : output directory
## $3 : last revision successfully built (optional)
##
## Builds glibc for installation at /opt/compiler-explorer/glibc/<version>/<triple>.
## The prefix is baked into ld.so, gconv and locale lookups, so the tarball must be
## extracted to exactly that path.

set -euxo pipefail
ROOT=$(pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
source "${HERE}/common.sh"
TARGET="${1-}"
DEST="${2-}"
LAST_REVISION="${3-}"

VERSION=${TARGET##*-}
TRIPLE=${TARGET%-*}
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ || -z "${TRIPLE}" || "${TRIPLE}" == "${TARGET}" || ! -d "${DEST}" ]]; then
    echo "Usage: $0 <triple>-<version> <output directory> [last revision]"
    echo "  e.g. $0 x86_64-linux-gnu-2.42 /build"
    exit 1
fi

BUILD_TRIPLE=$(gcc -dumpmachine)
PREFIX=/opt/compiler-explorer/glibc/${VERSION}/${TRIPLE}
LOCALES_FILE=${HERE}/locales.txt

# Kernel headers come from Ubuntu's linux-libc-dev (native) or linux-libc-dev-<arch>-cross.
# They are bundled into the tarball so the include dir is self-contained.
if [[ "${TRIPLE}" == "${BUILD_TRIPLE}" ]]; then
    CC=gcc
    CXX=g++
    STRIP=strip
    KERNEL_HEADERS_PKG=linux-libc-dev
    KERNEL_HEADERS_ROOT=/usr/include
    KERNEL_ASM_DIR=/usr/include/${TRIPLE}/asm
else
    CC=${TRIPLE}-gcc
    CXX=${TRIPLE}-g++
    STRIP=${TRIPLE}-strip
    case "${TRIPLE}" in
        aarch64-linux-gnu) DEB_ARCH=arm64 ;;
        arm-linux-gnueabihf) DEB_ARCH=armhf ;;
        riscv64-linux-gnu) DEB_ARCH=riscv64 ;;
        powerpc64le-linux-gnu) DEB_ARCH=ppc64el ;;
        s390x-linux-gnu) DEB_ARCH=s390x ;;
        *) echo "Unsupported triple ${TRIPLE}"; exit 1 ;;
    esac
    KERNEL_HEADERS_PKG=linux-libc-dev-${DEB_ARCH}-cross
    KERNEL_HEADERS_ROOT=/usr/${TRIPLE}/include
    KERNEL_ASM_DIR=/usr/${TRIPLE}/include/asm
fi
KERNEL_HEADERS_VERSION=$(dpkg-query -W -f='${Version}' "${KERNEL_HEADERS_PKG}")
LOCALES_HASH=$(grep -v '^#' "${LOCALES_FILE}" | sha256sum | cut -c1-8)

FULLNAME=glibc-${TRIPLE}-${VERSION}
OUTPUT=${DEST}/${FULLNAME}.tar.xz
REVISION="${FULLNAME}-linux-headers-${KERNEL_HEADERS_VERSION}-locales-${LOCALES_HASH}"

initialise "${REVISION}" "${OUTPUT}" "${LAST_REVISION}"

SRC_DIR=${ROOT}/glibc-${VERSION}
BUILD_DIR=${ROOT}/build-${TRIPLE}
NATIVE_BUILD_DIR=${ROOT}/build-${BUILD_TRIPLE}
NATIVE_PREFIX=/opt/compiler-explorer/glibc/${VERSION}/${BUILD_TRIPLE}
HEADERS_DIR=${ROOT}/kernel-headers-${TRIPLE}
STAGING_DIR=${ROOT}/staging-${TRIPLE}
LOCALES_STAGING_DIR=${ROOT}/staging-locales
INSTALL_DIR=${STAGING_DIR}${PREFIX}

rm -rf "${SRC_DIR}" "${BUILD_DIR}" "${NATIVE_BUILD_DIR}" "${HEADERS_DIR}" "${STAGING_DIR}" "${LOCALES_STAGING_DIR}"
mkdir -p "${SRC_DIR}" "${HEADERS_DIR}" "${STAGING_DIR}" "${LOCALES_STAGING_DIR}"

# Verify the release signature against the glibc release managers' keys in glibc-keyring.gpg
# (exported from https://ftp.gnu.org/gnu/gnu-keyring.gpg). A release signed by anyone else
# fails here until their key is added.
SOURCE_TARBALL=${ROOT}/glibc-${VERSION}.tar.xz
curl -sSfL -o "${SOURCE_TARBALL}" "https://ftp.gnu.org/gnu/glibc/glibc-${VERSION}.tar.xz"
curl -sSfL -o "${SOURCE_TARBALL}.sig" "https://ftp.gnu.org/gnu/glibc/glibc-${VERSION}.tar.xz.sig"
gpgv --keyring "${HERE}/glibc-keyring.gpg" "${SOURCE_TARBALL}.sig" "${SOURCE_TARBALL}"
tar Jxf "${SOURCE_TARBALL}" --strip-components 1 -C "${SRC_DIR}"

# Gather the kernel headers into one tree (linux/, asm/, asm-generic/, ...). On a native
# multiarch system asm/ lives under /usr/include/<triple>/asm, so it's copied separately.
dpkg -L "${KERNEL_HEADERS_PKG}" | grep -E "^${KERNEL_HEADERS_ROOT}/.+\.h$" | grep -v "^${KERNEL_HEADERS_ROOT}/${TRIPLE}/" \
    | sed "s,^${KERNEL_HEADERS_ROOT}/,," \
    | (cd "${KERNEL_HEADERS_ROOT}" && xargs cp --parents -t "${HEADERS_DIR}")
if [[ ! -d "${HEADERS_DIR}/asm" ]]; then
    cp -r "${KERNEL_ASM_DIR}" "${HEADERS_DIR}/asm"
fi

# configure_and_make <triple> <cc> <cxx> <kernel headers> <build dir> <prefix>
configure_and_make() {
    local triple="$1" cc="$2" cxx="$3" headers="$4" build_dir="$5" prefix="$6"
    mkdir -p "${build_dir}"
    # zonedir: glibc doesn't ship tzdata, so look up zones in the host's tzdata rather than
    # under the prefix.
    # user-defined-trusted-dirs: sysconfdir stays inside the prefix, so ld.so never reads the
    # host's /etc/ld.so.cache. If it did, a static binary that dlopens (iconv/gconv, NSS) would
    # get the host's libc.so.6 from the cache and crash. Instead the host's library dirs are
    # baked into ld.so's default search path, after the prefix's own lib dir.
    cat > "${build_dir}/configparms" <<EOF
zonedir=/usr/share/zoneinfo
user-defined-trusted-dirs=/lib/${triple}:/usr/lib/${triple}:/lib:/usr/lib
EOF
    pushd "${build_dir}"
    # -U_FORTIFY_SOURCE: Ubuntu's gcc defines _FORTIFY_SOURCE=3 unless the command line has a
    # plain -U/-D_FORTIFY_SOURCE. glibc < 2.41 only passes -Wp,-U_FORTIFY_SOURCE, which the
    # driver doesn't see, and then fails to build misc/syslog.c.
    "${SRC_DIR}/configure" \
        CC="${cc} -U_FORTIFY_SOURCE" \
        CXX="${cxx} -U_FORTIFY_SOURCE" \
        --prefix="${prefix}" \
        --build="${BUILD_TRIPLE}" \
        --host="${triple}" \
        --with-headers="${headers}" \
        --disable-werror \
        --without-selinux \
        --enable-stack-protector=strong
    make "-j$(nproc)"
    popd
}

configure_and_make "${TRIPLE}" "${CC}" "${CXX}" "${HEADERS_DIR}" "${BUILD_DIR}" "${PREFIX}"
make -C "${BUILD_DIR}" install DESTDIR="${STAGING_DIR}"

# Locales are compiled with the localedef of a native build of the same glibc version (the
# compiled format isn't guaranteed to be stable across versions, so the host's localedef or
# /usr/lib/locale won't do). A cross build therefore also builds glibc natively, which isn't
# installed. Compiled locales only depend on the target's endianness.
if [[ "${TRIPLE}" != "${BUILD_TRIPLE}" ]]; then
    configure_and_make "${BUILD_TRIPLE}" gcc g++ /usr/include "${NATIVE_BUILD_DIR}" "${NATIVE_PREFIX}"
fi
if echo | "${CC}" -dM -E - | grep -q '__BYTE_ORDER__ __ORDER_BIG_ENDIAN__'; then
    ENDIAN=--big-endian
else
    ENDIAN=--little-endian
fi
LOCALEDEF=("${NATIVE_BUILD_DIR}/testrun.sh" "${NATIVE_BUILD_DIR}/locale/localedef")
if ! "${LOCALEDEF[@]}" --help | grep -q -- "${ENDIAN}"; then
    echo "localedef for glibc ${VERSION} doesn't support ${ENDIAN}"
    exit 1
fi
# Mirrors build-one-locale in glibc's localedata/Makefile. Any localedef warning or error
# (non-zero exit) fails the build. localedef writes to <its own prefix>/lib/locale under
# --prefix, and doesn't create that directory itself.
mkdir -p "${LOCALES_STAGING_DIR}${NATIVE_PREFIX}/lib/locale"
grep -v -e '^#' -e '^$' "${LOCALES_FILE}" | while read -r NAME CHARSET; do
    INPUT=$(echo "${NAME}" | sed 's/\([^.]*\)[^@]*\(.*\)/\1\2/')
    FLAGS=(--no-archive --no-hard-links "${ENDIAN}" --alias-file="${SRC_DIR}/intl/locale.alias")
    if [[ "${CHARSET}" == SHIFT_JIS* ]]; then
        # Not ASCII compatible; glibc's own locale install disables this warning too.
        FLAGS+=(--no-warnings=ascii)
    fi
    (cd "${SRC_DIR}/localedata" && I18NPATH=. "${LOCALEDEF[@]}" "${FLAGS[@]}" \
        -i "locales/${INPUT}" -f "charmaps/${CHARSET}" --prefix="${LOCALES_STAGING_DIR}" "${NAME}") \
        || { echo "localedef failed for ${NAME} ${CHARSET}"; exit 1; }
done
mkdir -p "${INSTALL_DIR}/lib/locale"
cp -r "${LOCALES_STAGING_DIR}${NATIVE_PREFIX}/lib/locale/." "${INSTALL_DIR}/lib/locale/"
du -sh "${INSTALL_DIR}/lib/locale"

# The ld.so.cache from make install only lists the prefix's libs, which ld.so searches first anyway.
rm -f "${INSTALL_DIR}/etc/ld.so.cache"
cp -rn "${HEADERS_DIR}/." "${INSTALL_DIR}/include/"
# Lets gcc use -isysroot <prefix> (it looks in <sysroot>/usr/include), so libstdc++'s
# #include_next <stdlib.h> finds these headers rather than the host's /usr/include.
ln -s . "${INSTALL_DIR}/usr"
# gcc's include-fixed has fixincluded copies of these headers from the glibc gcc was built
# against, and searches them before the sysroot. Passing this dir with -isystem puts the real
# ones first. (Passing all of include/ that way would also bypass libstdc++'s math.h/stdlib.h
# wrappers.)
for header in pthread.h bits/floatn.h bits/floatn-common.h bits/statx.h; do
    mkdir -p "$(dirname "${INSTALL_DIR}/include-overrides/${header}")"
    ln -sr "${INSTALL_DIR}/include/${header}" "${INSTALL_DIR}/include-overrides/${header}"
done

# --strip-debug rather than --strip-all: gdb and valgrind need ld.so's symbol table.
du -sh "${INSTALL_DIR}"
find "${INSTALL_DIR}" -type f -print0 | xargs -0 file -N --no-pad \
    | grep -E ': (ELF|current ar archive)' | cut -d: -f1 \
    | xargs "${STRIP}" --strip-debug
du -sh "${INSTALL_DIR}"

complete "${INSTALL_DIR}" "${FULLNAME}" "${OUTPUT}"
