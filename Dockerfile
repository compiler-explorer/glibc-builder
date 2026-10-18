FROM ubuntu:24.04

# Ubuntu 24.04: gcc 13 and binutils 2.42, new enough for current glibc (needs gcc >= 12,
# binutils >= 2.39). gcc-9 is for glibc < 2.28 (build.sh picks the gcc per version). The output
# is self-contained, so it runs on older CE hosts.
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y -q && apt-get upgrade -y -q && \
    apt-get install -y -q --no-install-recommends \
    bison \
    build-essential \
    ca-certificates \
    curl \
    file \
    gawk \
    gettext \
    git \
    gpgv \
    make \
    python3 \
    texinfo \
    xz-utils \
    linux-libc-dev \
    gcc-9 \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu linux-libc-dev-arm64-cross \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf linux-libc-dev-armhf-cross \
    gcc-riscv64-linux-gnu g++-riscv64-linux-gnu linux-libc-dev-riscv64-cross \
    gcc-powerpc64le-linux-gnu g++-powerpc64le-linux-gnu linux-libc-dev-ppc64el-cross \
    gcc-s390x-linux-gnu g++-s390x-linux-gnu linux-libc-dev-s390x-cross \
    qemu-user && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/compiler-explorer
COPY common.sh /root/
COPY build.sh locales.txt glibc-keyring.gpg /root/
COPY patches /root/patches

WORKDIR /root
