# Stage 1: Build the React app
# node:20 reached EOL 2026-04-30 — moved to 24 (Active LTS) to match backend
# and stay ahead of npm/toolchain engine bumps that assume a supported Node.
FROM node:24-alpine AS builder

WORKDIR /app

# Copy package manifests + .npmrc before installing.
# .npmrc sets legacy-peer-deps=true — required for tailwindcss@4 + react-scripts@5
# peer dep resolution. Must be present before npm install for Docker layer caching.
COPY package.json package-lock.json .npmrc ./
RUN npm install

COPY . .
RUN npm run build

# Stage 2: Serve static files with nginx
# nginx-unprivileged runs as UID 101 (nginx user) — no root required.
# Pre-configured with writable pid/cache dirs; listens on 8080 (non-privileged port).
# k8s service maps external port 80 → targetPort 8080 so the ingress is unchanged.
FROM nginxinc/nginx-unprivileged:alpine

# Cache-busting build arg — same pattern as backend/Dockerfile.
# Forces apk upgrade to re-run on every pipeline build, picking up patched CVEs.
ARG BUILDDATE=unknown

# Patch Alpine packages to eliminate Trivy-flagged CVEs.
# Must run as root; we drop back to nginx immediately after.
USER root
RUN apk update && apk upgrade && rm -rf /var/cache/apk/*
USER nginx

# Copy built React app from Stage 1
COPY --from=builder /app/build /usr/share/nginx/html

# Copy nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080

# Explicitly declare non-root user — satisfies semgrep dockerfile.security.missing-user.
# nginx-unprivileged:alpine pre-configures all directories for this user (UID 101).
USER nginx

CMD ["nginx", "-g", "daemon off;"]
