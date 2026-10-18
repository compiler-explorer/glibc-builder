# glibc builder for Compiler Explorer

Builds glibc tarballs that install to `/opt/compiler-explorer/glibc/<version>/<triple>`, so
users can compile against a newer glibc than the host's (compiler-explorer/compiler-explorer#3103).

Repository: https://github.com/compiler-explorer/glibc-builder. Proof of concept; nothing is published yet.

## Building

```bash
docker build -t glibc-builder .
mkdir -p dist && chmod og+w dist
docker run --rm -v "$(pwd)/dist:/dist" glibc-builder bash build.sh x86_64-linux-gnu-2.42 /dist
docker run --rm -v "$(pwd)/dist:/dist" glibc-builder bash build.sh aarch64-linux-gnu-2.42 /dist
```

`build.sh <triple>-<version> <output dir> [last revision]` follows the misc-builder conventions:
it sources `common.sh` (a copy of misc-builder's) and uses its `initialise`/`complete` helpers,
which print `ce-build-revision` / `ce-build-output` / `ce-build-status` (`OK`, or `SKIPPED`
when the revision equals the 3rd argument). The target is in the version string, like
heaptrack's `x86_64-v1.3.0`. Triples other than the build machine's (x86_64-linux-gnu) are cross
compiled with Ubuntu's `<triple>-gcc` packages: aarch64-linux-gnu, arm-linux-gnueabihf,
riscv64-linux-gnu, powerpc64le-linux-gnu, s390x-linux-gnu. A native build takes about 3.5
minutes on 12 cores, a cross build about 5 (it also builds glibc natively, for the locales).

Output: `<output dir>/glibc-<triple>-<version>.tar.xz`, with contents under
`./glibc-<triple>-<version>/` (extract with `--strip-components 2` to the prefix). The
container never uploads anything; the CI host copies the output to S3.

The build runs as root, like the other CE builder images (the workflows run `docker run`
without `--user`). It builds in the working directory (`/root`), and writes only the tarball to
the output dir, which the workflow makes world-writable.

### CI

`.github/workflows/build.yml` builds the image on every push to main and pushes it as
`compilerexplorer/glibc-builder:latest` (same as go-builder/clang-builder), using the
compiler-explorer org-level `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` secrets. Docker Hub
creates the repo on the first push if that account may create repos in the `compilerexplorer`
org; otherwise the push step fails with "denied" and the repo has to be created by hand once.

To use it from CE's build workflows, infra `.github/workflows/bespoke-build.yaml` needs `glibc`
added to the `image` input's `options`. That workflow then runs

```bash
docker run -v"$(pwd)/dist:/dist" --rm compilerexplorer/glibc-builder \
  bash build.sh x86_64-linux-gnu-2.42 /dist
```

(inputs: image `glibc`, command `build.sh`, version `x86_64-linux-gnu-2.42`), parses the
`ce-build-*` lines and copies the tarball to
`s3://compiler-explorer/opt/glibc-x86_64-linux-gnu-2.42.tar.xz`. All targets, cross ones
included, build on the x64 runner, so the arm64 variant of the workflow isn't needed.

## Design notes

- `--prefix` is the final install path. glibc bakes it into ld.so, gconv and locale lookups, so
  the tarball only works at that path. It is installed with `DESTDIR` and the prefix is tarred up.
- `sysconfdir` stays at its default (`<prefix>/etc`). With `--sysconfdir=/etc` ld.so reads the
  host's `/etc/ld.so.cache`, and a static binary that dlopens (iconv, NSS) then loads the
  host's `libc.so.6` and crashes. Instead the host's library dirs (`/lib/<triple>`,
  `/usr/lib/<triple>`, `/lib`, `/usr/lib`) are compiled into ld.so's default search path
  (`user-defined-trusted-dirs`), after the prefix's own `lib`.
- `zonedir=/usr/share/zoneinfo`: glibc doesn't ship tzdata, so it uses the host's.
- Kernel headers (from Ubuntu's `linux-libc-dev` / `linux-libc-dev-<arch>-cross`) are copied
  into `<prefix>/include`, so the include dir is self-contained.
- The source tarball's GPG signature is checked against `glibc-keyring.gpg`, which holds the
  glibc release managers' keys exported from `https://ftp.gnu.org/gnu/gnu-keyring.gpg`
  (Andreas Schwab signed 2.17, Carlos O'Donell 2.28/2.30/2.32-2.40, Siddhesh Poyarekar 2.29/2.31, Andreas K. Huettel
  2.41/2.42). A release signed by someone else fails the build until their key is added.
- build.sh picks the gcc per glibc version (`GCC_MAJOR`): Ubuntu's `gcc-9` for glibc < 2.28
  (2.17's configure only accepts gcc 4.3-9.x), `gcc-13` otherwise. Newer glibc needing a newer gcc
  means adding a branch there and the package to the Dockerfile (Ubuntu 24.04 has gcc 9-14,
  native and cross). Only native gcc-9 is installed, so old versions are x86_64 only for now.
- `patches/<version>/*.patch` are applied to that version's source. 2.17 needs one
  (`_obstack_compat` as a common symbol, which binutils >= 2.26 won't version), and its configure
  is patched to accept make 4.
- Ubuntu 24.04's gcc defaults need overriding for older glibc: `-U_FORTIFY_SOURCE` (< 2.41,
  syslog.c), `-U_TIME_BITS -U_FILE_OFFSET_BITS` (32-bit armhf < 2.41) and `-fcf-protection=none`
  (< 2.31), `-no-pie -fno-PIE` (< 2.28). glibc is configured with `CXX=false`, `--without-gd` and `MAKEINFO=:` (no info manual), so nothing links against the
  build host's libstdc++/libgd (which fails when those were built for a newer glibc).
- Versions built and tested: 2.39-2.42 for all six triples, and x86_64 2.17, 2.28, 2.31, 2.35,
  2.36. CE's gcc >= 12 runtimes need glibc 2.35 (libgcc_s GLIBC_2.35, libstdc++ GLIBC_2.34,
  libgcc_eh `_dl_find_object`), so with those compilers glibc < 2.35 is only usable for
  dynamically linked C; with gcc <= 11 C works fully and C++ needs `-pthread` (< 2.34).
- Older localedef lacks some options (`--no-hard-links` < 2.29, `--no-warnings`, endianness
  < 2.21); they're only passed when supported.
- The locales in `locales.txt` (`/etc/locale.gen` format, the same list as infra's
  setup-common.sh plus C.UTF-8, which isn't built in to glibc) are compiled into
  `<prefix>/lib/locale`. They're compiled with the localedef of a native build of the same glibc
  version, because the compiled format isn't guaranteed stable across versions. A cross build
  therefore also builds glibc natively. Compiled locales only depend on endianness, so they get
  `--little-endian` or `--big-endian` to match the target. Any localedef warning fails the build.
  C.UTF-8 is skipped before 2.36 (no source before 2.35; 2.35's localedef rejects its own).
  `ja_JP.SHIFT_JIS` needs `--no-warnings=ascii`, as in glibc's own locale install.
- Everything is stripped with `--strip-debug` (not `--strip-all`, so gdb and valgrind still get
  ld.so's symbol table). Static libs are kept.
- `<prefix>/usr -> .` lets gcc's `-isysroot <prefix>` work, and `<prefix>/include-overrides/`
  holds symlinks to the few headers that gcc fixincludes (see below).

## Using it

With `P=/opt/compiler-explorer/glibc/2.42/x86_64-linux-gnu`:

gcc, either of:

```
--sysroot=$P -isystem $P/include-overrides -L$P/lib -Wl,-rpath=$P/lib -Wl,--dynamic-linker=$P/lib/ld-linux-x86-64.so.2
-isysroot $P -isystem $P/include-overrides -B$P/lib -L$P/lib -Wl,-rpath=$P/lib -Wl,--dynamic-linker=$P/lib/ld-linux-x86-64.so.2
```

clang:

```
--sysroot=$P -L<gcc>/lib64 -L$P/lib -Wl,-rpath=$P/lib -Wl,--dynamic-linker=$P/lib/ld-linux-x86-64.so.2
```

plus CE's usual `-Wl,-rpath=<gcc>/lib64` for libstdc++/libgcc_s.

Why a sysroot: libstdc++'s `<cstdlib>`/`<cmath>` do `#include_next <stdlib.h>`, which skips
`-I`/`-isystem` dirs and lands in `/usr/include` (the host's older glibc) unless the system
include dir is replaced. `--sysroot` (or gcc's header-only `-isysroot`; clang ignores
`-isysroot` on Linux) does that, via the `<prefix>/usr -> .` symlink.

Why `include-overrides` (gcc only): gcc's `include-fixed` dir is searched before the sysroot
and has fixincluded copies of `pthread.h`, `bits/floatn*.h` and `bits/statx.h` taken from the
glibc gcc was built against (every CE x86 gcc has some of these; e.g. its `pthread.h` has the
old `PTHREAD_COND_INITIALIZER` for the previous `pthread_cond_t` layout). `include-overrides`
holds symlinks to just those headers, and `-isystem` puts them first. clang doesn't use gcc's
`include-fixed`, so it doesn't need it (harmless if passed). Adding the whole `$P/include` with
`-I`/`-isystem` doesn't work: gcc drops it as a duplicate of the sysroot dir, and it would also
bypass libstdc++'s `math.h`/`stdlib.h` wrappers.

The linker scripts (`lib/libc.so`, `lib/libm.so`, `lib/libm.a`) name their libraries without a
path, so ld finds them through `-L$P/lib` or `<sysroot>/lib`. With absolute paths ld would
prefix the sysroot to them under `--sysroot` and fail; with sysroot-relative `/lib/...` paths a
link without `--sysroot` would silently use the host's libc.

The sysroot flags hide the host's `/usr/include`, so third-party headers that live there (e.g.
`zlib.h`) need `-idirafter /usr/include`. With `--sysroot`, clang also stops looking for
libstdc++ outside the sysroot, hence `-L<gcc>/lib64`.

## Testing

`test/test-tarball.sh <tarball> [gcc dir] [clang dir]` extracts the tarball to its real prefix
inside a private user+mount namespace (an overlay over `/opt/compiler-explorer`, so nothing is
written to the host, and a private tmpfs hides any glibc already installed there). It then
builds and runs C/C++ tests, dynamic and static, with gcc (`-isysroot` and `--sysroot`) and
optionally clang.

It runs on a host with CE's compilers installed (it needs unprivileged user namespaces and the
compilers under `/opt/compiler-explorer`), not in the builder image, so `test/` isn't copied
into the image.
