FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ghc libghc-warp-dev libghc-wai-dev libghc-http-client-tls-dev libghc-aeson-dev libghc-lucid-dev libghc-network-uri-dev libghc-cryptonite-dev ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY haskell ./haskell
COPY scripts/build-haskell.sh ./scripts/build-haskell.sh
RUN ./scripts/build-haskell.sh
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libgmp10 libffi8 zlib1g && rm -rf /var/lib/apt/lists/* && useradd --system --uid 10001 app
WORKDIR /app
COPY --from=builder /src/build/douyin-download ./douyin-download
COPY static ./static
USER app
ENV BIND_ADDRESS=0.0.0.0 PORT=8187
EXPOSE 8187
CMD ["./douyin-download", "+RTS", "-N1", "-M192m", "-RTS"]
