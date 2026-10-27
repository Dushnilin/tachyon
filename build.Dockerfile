# The image the release build runs in.
#
# build.sh needs the OpenWrt SDK, and the SDK is a Linux tarball: on a
# Windows host the build has to happen inside a container. This image
# carries exactly the host tools build.sh asks for, so the build does not
# depend on what the machine happens to have installed.
#
#   docker build -t tachyon-build -f build.Dockerfile .
#   docker run --rm -v "$PWD:/work" -w /work tachyon-build bash build.sh 1.6.0
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    fakeroot \
    file \
    gawk \
    git \
    patch \
    python3 \
    rsync \
    tar \
    unzip \
    util-linux \
    wget \
    xz-utils \
    zstd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
