# Debian 11 keeps the release ABI ceiling at glibc 2.31.
FROM ghcr.io/astral-sh/uv:0.13.7 AS uv
FROM debian:bullseye-slim
COPY --from=uv /uv /usr/local/bin/uv
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PATH=/opt/flutter/bin:/opt/python/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    FLUTTER=/opt/flutter/bin/flutter \
    PYTHON=/opt/python/bin/python3 \
    TAL_MAX_GLIBC=2.31
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/* \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip rsync clang cmake ninja-build \
    pkg-config libgtk-3-dev liblzma-dev libusb-1.0-0-dev libgl1-mesa-dev \
    libglu1-mesa libegl1-mesa libasound2 binutils gzip tar \
    && rm -rf /var/lib/apt/lists/*
RUN uv python install 3.11.17 --install-dir /opt/uv-python \
    && mkdir -p /opt/python/bin \
    && ln -s /opt/uv-python/cpython-3.11.17-linux-x86_64-gnu/bin/python3.11 /opt/python/bin/python3 \
    && /opt/python/bin/python3 --version
ARG FLUTTER_VERSION=3.44.9
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /opt/flutter \
    && flutter config --no-analytics --enable-linux-desktop \
    && flutter precache --linux \
    && flutter --version
WORKDIR /workspace
