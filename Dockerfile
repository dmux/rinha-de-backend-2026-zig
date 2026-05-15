# Stage 1: Compile Zig binaries (fraud-api + preprocess)
FROM debian:bookworm-slim AS zig-builder
RUN apt-get update && apt-get install -y curl xz-utils patch && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.16.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY zig-pkg/ zig-pkg/
COPY patches/ patches/
COPY src/ src/
COPY tools/ tools/
RUN patch -p0 < patches/httpz-unix-socket-tcp-nodelay.patch && \
    patch -p0 < patches/httpz-fix-eventfd-et-bug.patch
RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl -Dtarget_cpu=x86_64_v3

# Stage 2: Build the IVF index from references.json.gz
FROM debian:bookworm-slim AS preprocessor
COPY resources/ /resources/
COPY --from=zig-builder /app/zig-out/bin/preprocess /preprocess
RUN mkdir -p /data && \
    /preprocess /resources/references.json.gz /data/ivf_index.bin

# Stage 3: Runtime for APIs
FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY --from=preprocessor /data/ivf_index.bin /data/ivf_index.bin
COPY --from=zig-builder /app/zig-out/bin/fraud-api /fraud-api
COPY resources/mcc_risk.json /resources/mcc_risk.json
EXPOSE 8080
ENTRYPOINT ["/fraud-api"]

# Stage 4: Runtime for Proxy
FROM scratch AS proxy
COPY --from=zig-builder /app/zig-out/bin/zig-proxy /zig-proxy
EXPOSE 9999
ENTRYPOINT ["/zig-proxy"]
