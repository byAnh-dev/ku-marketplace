FROM swift:6.3-noble AS base
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends libvips-dev libheif-plugin-libde265 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Package.* ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests

FROM base AS test
RUN swift test --jobs 4

FROM base AS runtime
RUN swift build -c release --jobs 4
EXPOSE 8080
CMD [".build/release/Marketplace", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
