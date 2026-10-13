# kulhar builder image: a pinned SBCL on Debian 12 "bookworm", plus the
# C toolchain and dependency tools kulhar's builds need.
#
# Build one architecture natively (SBCL cannot cross-compile):
#   docker buildx build --build-arg SBCL_VERSION=2.6.9 -t kulhar-builder .
#
# Every download is pinned and verified against versions.json.

# debian:bookworm-slim (multi-arch index). Both stages use this digest.
ARG DEBIAN_DIGEST=sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

FROM debian:bookworm-slim@${DEBIAN_DIGEST} AS build

ARG SBCL_VERSION
ARG RUN_SBCL_TESTS=no

ENV XDG_CONFIG_DIRS=/usr/local/etc/xdg:/etc/xdg

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bzip2 ca-certificates curl gcc gnupg jq libc6-dev libzstd-dev make sbcl \
 && rm -rf /var/lib/apt/lists/*

COPY versions.json /src/versions.json
COPY keys/ /src/keys/
COPY build/fetch-sbcl.sh /src/build/
RUN test -n "$SBCL_VERSION" || { echo "SBCL_VERSION build arg is required" >&2; exit 1; } \
 && sh /src/build/fetch-sbcl.sh "$SBCL_VERSION" /tmp/sbcl

# Bootstrap with Debian's sbcl. --fancy enables :sb-core-compression (zstd),
# :sb-xref-for-internals, and threads on every platform that supports them.
RUN cd /tmp/sbcl \
 && SBCL_MAKE_JOBS=-j$(nproc) sh make.sh --fancy --prefix=/usr/local \
 && if [ "$RUN_SBCL_TESTS" = yes ]; then (cd tests && sh run-tests.sh); fi \
 && sh install.sh \
 && rm -rf /usr/local/share/doc/sbcl /usr/local/share/man /usr/local/share/info \
 && apt-get purge -y sbcl \
 && cd / && rm -rf /tmp/sbcl \
 && /usr/local/bin/sbcl --version | grep -qx "SBCL $SBCL_VERSION"

COPY build/asdf-output-translations.conf \
     /usr/local/etc/xdg/common-lisp/asdf-output-translations.conf.d/50-kulhar-builder.conf
COPY build/load-quicklisp.lisp /usr/local/share/kulhar-builder/load-quicklisp.lisp
COPY build/install-tools.sh /src/build/
RUN sh /src/build/install-tools.sh


FROM debian:bookworm-slim@${DEBIAN_DIGEST}

COPY --from=build /usr/local /usr/local

ARG TARGETARCH
ARG DEBIAN_DIGEST
# The workflow sets this to the build date. It only exists to change the
# cache key, so cached layers can't hide Debian security fixes.
ARG APT_REFRESH=

# Upgrade so rebuilds pick up Debian security fixes.
# gcc, libc6-dev, make and pkg-config: CFFI's groveller compiles C while
# loading some libraries. libzstd1: the sbcl runtime links it. libssl3: qlot
# fetches over HTTPS through cl+ssl. git: qlot and ocicl fetch git sources.
# jq is only needed to write the manifest, which records the versions of the
# packages installed here, and is removed again in the same layer.
RUN --mount=type=bind,source=versions.json,target=/src/versions.json \
    --mount=type=bind,source=build/write-manifest.sh,target=/src/build/write-manifest.sh \
    echo "apt refresh: ${APT_REFRESH:-none}" \
 && apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates gcc git libc6-dev libssl3 libzstd1 make pkg-config jq \
 && sh /src/build/write-manifest.sh "$TARGETARCH" "$DEBIAN_DIGEST" \
 && apt-get purge -y --autoremove jq \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/log/apt /var/log/dpkg.log

# kulhar runs this image as the host user's UID, which has no passwd entry.
# Everything a build writes goes under world-writable, sticky directories.
# Mount one host directory at /var/cache/kulhar to persist all caches, or
# point the variables below elsewhere.
RUN mkdir -p /home/kulhar /workspace \
      /var/cache/kulhar/xdg-cache /var/cache/kulhar/xdg-data \
      /var/cache/kulhar/quicklisp /var/cache/kulhar/qlot \
 && chmod 1777 /home/kulhar /workspace /var/cache/kulhar /var/cache/kulhar/*

ENV HOME=/home/kulhar \
    XDG_CONFIG_DIRS=/usr/local/etc/xdg:/etc/xdg \
    XDG_CACHE_HOME=/var/cache/kulhar/xdg-cache \
    XDG_DATA_HOME=/var/cache/kulhar/xdg-data \
    KULHAR_QUICKLISP_HOME=/var/cache/kulhar/quicklisp \
    QLOT_CACHE_DIRECTORY=/var/cache/kulhar/qlot

WORKDIR /workspace

ARG SBCL_VERSION
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
ARG IMAGE_SOURCE=https://github.com/crmsnbleyd/kulhar-builder
LABEL org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.description="kulhar builder image: SBCL ${SBCL_VERSION} on Debian 12 (bookworm) with a C toolchain, Quicklisp, qlot and ocicl" \
      org.opencontainers.image.licenses="MIT" \
      kulhar.builder.sbcl-version="${SBCL_VERSION}" \
      kulhar.builder.debian-release="bookworm"

CMD ["sbcl"]
