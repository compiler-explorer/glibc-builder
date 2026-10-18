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

version_older_than() {
    [[ "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

# The gcc that can build this glibc version: Ubuntu's gcc-<major> (native) or
# <triple>-gcc-<major> (cross), which the Dockerfile installs. Old glibc doesn't build with new
# gcc (2.17's configure only accepts gcc 4.3-9.x), and future glibc may need a newer one.
if version_older_than "${VERSION}" 2.28; then
    GCC_MAJOR=9
else
    GCC_MAJOR=13
fi

BUILD_TRIPLE=$(gcc -dumpmachine)
NATIVE_CC=gcc-${GCC_MAJOR}
PREFIX=/opt/compiler-explorer/glibc/${VERSION}/${TRIPLE}
LOCALES_FILE=${HERE}/locales.txt

# Kernel headers come from Ubuntu's linux-libc-dev (native) or linux-libc-dev-<arch>-cross.
# They are bundled into the tarball so the include dir is self-contained.
if [[ "${TRIPLE}" == "${BUILD_TRIPLE}" ]]; then
    CC=${NATIVE_CC}
    STRIP=strip
    KERNEL_HEADERS_PKG=linux-libc-dev
    KERNEL_HEADERS_ROOT=/usr/include
    KERNEL_ASM_DIR=/usr/include/${TRIPLE}/asm
else
    CC=${TRIPLE}-gcc-${GCC_MAJOR}
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
NATIVE_HEADERS_DIR=${ROOT}/kernel-headers-${BUILD_TRIPLE}
STAGING_DIR=${ROOT}/staging-${TRIPLE}
LOCALES_STAGING_DIR=${ROOT}/staging-locales
INSTALL_DIR=${STAGING_DIR}${PREFIX}

rm -rf "${SRC_DIR}" "${BUILD_DIR}" "${NATIVE_BUILD_DIR}" "${HEADERS_DIR}" "${NATIVE_HEADERS_DIR}" "${STAGING_DIR}" "${LOCALES_STAGING_DIR}"
mkdir -p "${SRC_DIR}" "${STAGING_DIR}" "${LOCALES_STAGING_DIR}"

# Verify the release signature against the glibc release managers' keys in glibc-keyring.gpg
# (exported from https://ftp.gnu.org/gnu/gnu-keyring.gpg). A release signed by anyone else
# fails here until their key is added.
SOURCE_TARBALL=${ROOT}/glibc-${VERSION}.tar.xz
curl -sSfL -o "${SOURCE_TARBALL}" "https://ftp.gnu.org/gnu/glibc/glibc-${VERSION}.tar.xz"
curl -sSfL -o "${SOURCE_TARBALL}.sig" "https://ftp.gnu.org/gnu/glibc/glibc-${VERSION}.tar.xz.sig"
gpgv --keyring "${HERE}/glibc-keyring.gpg" "${SOURCE_TARBALL}.sig" "${SOURCE_TARBALL}"
tar Jxf "${SOURCE_TARBALL}" --strip-components 1 -C "${SRC_DIR}"
# Fixes for building old releases with today's toolchain, from patches/<version>/
if [[ -d "${HERE}/patches/${VERSION}" ]]; then
    for patch in "${HERE}/patches/${VERSION}"/*.patch; do
        patch -p1 -d "${SRC_DIR}" < "${patch}"
    done
fi
# glibc < 2.18's configure only accepts make 3.79-3.8x; later releases also accept make 4.
sed -i 's/^\( *\)3\.79\* | 3\.\[89\]\*)/\13.79* | 3.[89]* | [4-9].*)/' "${SRC_DIR}/configure"

# gather_kernel_headers <package> <include root> <asm dir> <triple> <dest>
# Gathers a package's kernel headers into one tree (linux/, asm/, asm-generic/, ...), as
# glibc's --with-headers expects. On a native multiarch system asm/ lives under
# /usr/include/<triple>/asm (/usr/include/asm only exists with gcc-multilib), so it's copied
# separately.
gather_kernel_headers() {
    local pkg="$1" root="$2" asm_dir="$3" triple="$4" dest="$5"
    mkdir -p "${dest}"
    dpkg -L "${pkg}" | grep -E "^${root}/.+\.h$" | grep -v "^${root}/${triple}/" \
        | sed "s,^${root}/,," \
        | (cd "${root}" && xargs cp --parents -t "${dest}")
    if [[ ! -d "${dest}/asm" ]]; then
        cp -r "${asm_dir}" "${dest}/asm"
    fi
}

gather_kernel_headers "${KERNEL_HEADERS_PKG}" "${KERNEL_HEADERS_ROOT}" "${KERNEL_ASM_DIR}" "${TRIPLE}" "${HEADERS_DIR}"

# Older glibc needs workarounds for Ubuntu 24.04's gcc defaults.
EXTRA_CFLAGS=
if version_older_than "${VERSION}" 2.31; then
    # Ubuntu's gcc enables -fcf-protection by default, which makes glibc < 2.31 reference CET
    # functions it doesn't build (undefined _dl_cet_open_check when linking ld.so).
    EXTRA_CFLAGS=-fcf-protection=none
fi
if version_older_than "${VERSION}" 2.28; then
    # Ubuntu's gcc builds PIE by default; old glibc's crt1.o isn't PIC (R_X86_64_32S against
    # __libc_csu_fini when linking its programs).
    EXTRA_CFLAGS="${EXTRA_CFLAGS} -no-pie -fno-PIE"
fi

# configure_and_make <triple> <cc> <kernel headers> <build dir> <prefix>
configure_and_make() {
    local triple="$1" cc="$2" headers="$3" build_dir="$4" prefix="$5"
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
    # -U_TIME_BITS -U_FILE_OFFSET_BITS: likewise, Ubuntu's 32-bit gcc (armhf) defaults to 64-bit
    # time_t/off_t, which glibc < 2.41 can't build with (conflicting types for fgetpos).
    # CXX=false: glibc only uses C++ for its tests (support/links-dso-program etc.), and linking
    # those against the build host's libstdc++ fails when that was built for a newer glibc. (An
    # empty CXX doesn't work: AC_PROG_CXX then finds g++ itself. With false, configure's "can
    # $CXX link programs" check fails and glibc builds without C++.)
    # --without-gd: don't build memusagestat against whatever libgd the build host has.
    "${SRC_DIR}/configure" \
        CC="${cc} -U_FORTIFY_SOURCE -U_TIME_BITS -U_FILE_OFFSET_BITS ${EXTRA_CFLAGS}" \
        CXX=false \
        --prefix="${prefix}" \
        --build="${BUILD_TRIPLE}" \
        --host="${triple}" \
        --with-headers="${headers}" \
        --disable-werror \
        --without-selinux \
        --without-gd \
        --enable-stack-protector=strong
    make "-j$(nproc)"
    popd
}

configure_and_make "${TRIPLE}" "${CC}" "${HEADERS_DIR}" "${BUILD_DIR}" "${PREFIX}"
make -C "${BUILD_DIR}" install DESTDIR="${STAGING_DIR}"

# Locales are compiled with the localedef of a native build of the same glibc version (the
# compiled format isn't guaranteed to be stable across versions, so the host's localedef or
# /usr/lib/locale won't do). A cross build therefore also builds glibc natively, which isn't
# installed. Compiled locales only depend on the target's endianness.
if [[ "${TRIPLE}" != "${BUILD_TRIPLE}" ]]; then
    gather_kernel_headers linux-libc-dev /usr/include "/usr/include/${BUILD_TRIPLE}/asm" "${BUILD_TRIPLE}" "${NATIVE_HEADERS_DIR}"
    configure_and_make "${BUILD_TRIPLE}" "${NATIVE_CC}" "${NATIVE_HEADERS_DIR}" "${NATIVE_BUILD_DIR}" "${NATIVE_PREFIX}"
fi
if echo | "${CC}" -dM -E - | grep -q '__BYTE_ORDER__ __ORDER_BIG_ENDIAN__'; then
    ENDIAN=--big-endian
else
    ENDIAN=--little-endian
fi
LOCALEDEF=("${NATIVE_BUILD_DIR}/testrun.sh" "${NATIVE_BUILD_DIR}/locale/localedef")
if ! "${LOCALEDEF[@]}" --help | grep -q -- "${ENDIAN}"; then
    # localedef < 2.21 has no endianness options and writes the host's (little-endian) format
    if [[ "${ENDIAN}" != --little-endian ]]; then
        echo "localedef for glibc ${VERSION} can't write ${ENDIAN} locales"
        exit 1
    fi
    ENDIAN=
fi
# Mirrors build-one-locale in glibc's localedata/Makefile. Any localedef warning or error
# (non-zero exit) fails the build. localedef writes to <its own prefix>/lib/locale under
# --prefix, and doesn't create that directory itself.
mkdir -p "${LOCALES_STAGING_DIR}${NATIVE_PREFIX}/lib/locale"
# --no-hard-links needs glibc >= 2.29; without it identical files are hard links, which is fine.
LOCALEDEF_FLAGS=(--no-archive ${ENDIAN} --alias-file="${SRC_DIR}/intl/locale.alias")
if "${LOCALEDEF[@]}" --help | grep -q -- --no-hard-links; then
    LOCALEDEF_FLAGS+=(--no-hard-links)
fi
grep -v -e '^#' -e '^$' "${LOCALES_FILE}" | while read -r NAME CHARSET; do
    INPUT=$(echo "${NAME}" | sed 's/\([^.]*\)[^@]*\(.*\)/\1\2/')
    if [[ "${NAME}" == C.UTF-8 ]] && version_older_than "${VERSION}" 2.36; then
        # Added in 2.35, but 2.35's own localedef rejects it (empty mon_decimal_point)
        echo "glibc ${VERSION} has no usable C.UTF-8 locale source; skipping it"
        continue
    fi
    FLAGS=("${LOCALEDEF_FLAGS[@]}")
    if [[ "${CHARSET}" == SHIFT_JIS* ]] && "${LOCALEDEF[@]}" --help | grep -q -- --no-warnings; then
        # Not ASCII compatible; glibc's own locale install disables this warning too. (Older
        # localedef has no --no-warnings, and only prints a notice for it.)
        FLAGS+=(--no-warnings=ascii)
    fi
    (cd "${SRC_DIR}/localedata" && I18NPATH=. "${LOCALEDEF[@]}" "${FLAGS[@]}" \
        -i "locales/${INPUT}" -f "charmaps/${CHARSET}" --prefix="${LOCALES_STAGING_DIR}" "${NAME}") \
        || { echo "localedef failed for ${NAME} ${CHARSET}"; exit 1; }
done
mkdir -p "${INSTALL_DIR}/lib/locale"
cp -r "${LOCALES_STAGING_DIR}${NATIVE_PREFIX}/lib/locale/." "${INSTALL_DIR}/lib/locale/"
du -sh "${INSTALL_DIR}/lib/locale"

# The linker scripts (libc.so, libm.so, libm.a) name their libraries by absolute path, and ld
# prepends the sysroot to those when the script is inside --sysroot, so a --sysroot=<prefix> link
# can't find them. Bare names are looked up in the library search path (-L<prefix>/lib, or
# <sysroot>/lib), which works with and without --sysroot. (Sysroot-relative /lib/... paths
# would make a link without --sysroot pick up the host's libc.)
LD_SCRIPTS=$(find "${INSTALL_DIR}/lib" -maxdepth 1 -type f -exec grep -lI 'GNU ld script' {} +)
sed -i "s,${PREFIX}/lib/,,g" ${LD_SCRIPTS}
if grep "${PREFIX}/lib/" ${LD_SCRIPTS}; then
    echo "Linker scripts still contain absolute paths"
    exit 1
fi

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
    # Older glibc doesn't have all of them
    [[ -f "${INSTALL_DIR}/include/${header}" ]] || continue
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
