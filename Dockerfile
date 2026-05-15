# Stage 0: Common Zig Base
FROM debian:bookworm-slim AS zig-base
RUN apt-get update && apt-get install -y curl xz-utils patch && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.16.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY zig-pkg/ zig-pkg/
COPY patches/ patches/
RUN patch -p0 < patches/httpz-unix-socket-tcp-nodelay.patch && \
    patch -p0 < patches/httpz-fix-eventfd-et-bug.patch

# Stage 1: Build Preprocessing Tool
# This stage only copies the domain logic and tools, but NOT main.zig or proxy.zig
FROM zig-base AS tools-builder
COPY src/domain/ src/domain/
COPY src/ports/ src/ports/
COPY src/adapters/ src/adapters/
COPY src/application/ src/application/
COPY src/domain.zig src/
COPY tools/ tools/
RUN zig build preprocess -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl -Dtarget_cpu=haswell

# Stage 2: Data Preprocessing (Only rebuilds if reference data or tools change)
FROM debian:bookworm-slim AS data-processor
COPY resources/references.json.gz /resources/references.json.gz
COPY --from=tools-builder /app/zig-out/bin/preprocess /preprocess
RUN mkdir -p /data && \
    /preprocess /resources/references.json.gz /data/ivf_index.bin

# Stage 3: Build APIs (Rebuilds on any src/ change)
FROM zig-base AS api-builder
COPY src/ src/
RUN zig build api -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl -Dtarget_cpu=x86_64_v3

# Stage 4: Combined Runtime
FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY --from=data-processor /data/ivf_index.bin /data/ivf_index.bin
COPY --from=api-builder /app/zig-out/bin/fraud-api /fraud-api
COPY --from=api-builder /app/zig-out/bin/zig-proxy /zig-proxy
COPY resources/mcc_risk.json /resources/mcc_risk.json
EXPOSE 8080 9999
ENTRYPOINT ["/fraud-api"]
