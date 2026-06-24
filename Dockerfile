# Self-contained build: `docker build -t babelhub .` needs no host toolchain.
# Three stages — bundle the frontend, compile the Nim server (embedding it),
# then ship just the binary on a minimal runtime.

# 1. Frontend -> dist/
FROM node:22-slim AS web
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --no-audit --no-fund
COPY . .
RUN npm run build

# 2. Compile the server; dist/ is embedded at compile time (needs `find`).
FROM nimlang/nim:2.2.6 AS server
WORKDIR /app
COPY server ./server
COPY --from=web /app/dist ./dist
RUN nim c -d:release --hints:off -o:/babelhub server/babelhub.nim

# 3. Minimal runtime — the binary links glibc + libm and shells out to git.
FROM debian:stable-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data && chown nobody:nogroup /data
COPY --from=server /babelhub /usr/local/bin/babelhub
ENV PORT=8080 BABELHUB_DATA=/data
EXPOSE 8080
VOLUME /data
USER nobody
CMD ["babelhub"]
