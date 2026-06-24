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

# 3. Minimal runtime — the binary only links glibc + libm.
FROM debian:stable-slim
COPY --from=server /babelhub /usr/local/bin/babelhub
ENV PORT=8080
EXPOSE 8080
USER nobody
CMD ["babelhub"]
