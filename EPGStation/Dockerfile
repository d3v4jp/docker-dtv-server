# EPGStation
# v3 系の Debian 版の最新を使う (v2 系は今後更新されない見込み)
ARG EPGSTATION_IMAGE=l3tnun/epgstation:debian
FROM ${EPGSTATION_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# サムネイルの作成などに使う FFmpeg
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ffmpeg; \
    rm -rf /var/lib/apt/lists/*

# ログ設定ファイル (*LogConfig.yml) が無いと「log file is not found」で起動できない
# compose.yaml では config.yml と tsreplace.sh だけをマウントするので、イメージ内のサンプルから作っておく
RUN cd /app/config \
 && for f in *LogConfig.sample.yml; do cp "$f" "${f%.sample.yml}.yml"; done
