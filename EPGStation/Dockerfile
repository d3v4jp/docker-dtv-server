# EPGStation + tsreplace + VA-API (Intel iGPU) エンコード環境
# v3 系の Debian 版の最新を使う (v2 系は今後更新されない見込み)
ARG EPGSTATION_IMAGE=l3tnun/epgstation:debian
FROM ${EPGSTATION_IMAGE}

# tsreplace の .deb は FFmpeg を静的リンクしており、依存は libc6 / libgcc-s1 だけなので
# Debian ベースのイメージにもそのまま入る。
# 使えるバージョンと CPU は https://github.com/rigaya/tsreplace/releases で確認する
#   TSREPLACE_VERSION: tsreplace のバージョン
#   TSREPLACE_ARCH   : ターゲット CPU (amd64 など)。未指定ならビルドするマシンの CPU (TARGETARCH) を使う
ARG TARGETARCH
ARG TSREPLACE_VERSION=0.22
ARG TSREPLACE_ARCH=${TARGETARCH:-amd64}

ENV DEBIAN_FRONTEND=noninteractive

# HEVC の VA-API エンコードには non-free の Intel Media Driver (iHD) が必要
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i -E 's/^(Components:.*main)$/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl \
        ffmpeg \
        intel-media-va-driver-non-free \
        vainfo; \
    curl -fsSL -o /tmp/tsreplace.deb \
        "https://github.com/rigaya/tsreplace/releases/download/${TSREPLACE_VERSION}/tsreplace_${TSREPLACE_VERSION}_${TSREPLACE_ARCH}.deb"; \
    apt-get install -y --no-install-recommends /tmp/tsreplace.deb; \
    rm -f /tmp/tsreplace.deb; \
    rm -rf /var/lib/apt/lists/*

ENV LIBVA_DRIVER_NAME=iHD

# ログ設定ファイル (*LogConfig.yml) が無いと「log file is not found」で起動できない
# compose.yaml では config.yml と tsreplace.sh だけをマウントするので、イメージ内のサンプルから作っておく
RUN cd /app/config \
 && for f in *LogConfig.sample.yml; do cp "$f" "${f%.sample.yml}.yml"; done
