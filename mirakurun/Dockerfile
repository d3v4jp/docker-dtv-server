FROM chinachu/mirakurun

# recisdb-rs
ARG RECISDB_VERSION=1.3.2
ARG TARGETARCH=amd64
ADD https://github.com/kazuki0824/recisdb-rs/releases/download/${RECISDB_VERSION}/recisdb_${RECISDB_VERSION}-1_${TARGETARCH}.deb /tmp/recisdb.deb
RUN apt-get update \
 && apt-get install -y --no-install-recommends /tmp/recisdb.deb \
 && rm -f /tmp/recisdb.deb \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
