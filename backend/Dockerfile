# Use Node.js 24 (Active LTS) on Alpine — smaller surface area, actively supported.
# node:20 reached EOL 2026-04-30; npm@latest now refuses to install on it
# (engine requires ^22.22.2 || ^24.15.0 || >=26.0.0), which broke this build.
FROM node:24-alpine

# Set the working directory inside the container
WORKDIR /app

# Cache-busting build arg — forces the apk upgrade layer to rebuild on every
# pipeline run so newly patched Alpine CVEs are always applied.
# The ARG value (github.run_id) is passed from the pipeline. Because Docker
# includes ARG values in the layer cache key, this layer never hits cache.
# Layers BELOW this (npm ci etc.) still cache normally since they depend on
# COPY instructions, not on BUILDDATE.
ARG BUILDDATE=unknown

# Patch Alpine base packages before installing app deps.
# Eliminates Trivy-flagged CVEs in musl, libssl, etc. that ship with the base image.
RUN apk update && apk upgrade && rm -rf /var/cache/apk/*

# Upgrade npm itself to patch CVEs in npm-bundled packages:
#   node-tar  < 6.2.1  — path traversal, symlink, hardlink (6x HIGH)
#   minimatch < 3.0.5  — ReDoS catastrophic backtracking (3x HIGH)
#   glob               — command injection via malicious filenames (1x HIGH)
#   cross-spawn < 7.0.5 — ReDoS (1x HIGH)
# These live at /usr/local/lib/node_modules/npm/node_modules/ — not in the
# app's own node_modules — so npm update / package.json overrides don't reach them.
# npm@latest ships node-tar 6.2.1+, minimatch 9.x, glob 10.x, cross-spawn 7.0.5+.
RUN npm install -g npm@latest && npm cache clean --force

# Copy package manifests + .npmrc before installing.
# .npmrc sets legacy-peer-deps=true — required because express-graphql@0.12
# (graphql peer ^15) conflicts with @apollo/server@4 (graphql peer ^16).
# Must be copied here (not after npm ci) to benefit Docker layer caching.
COPY package.json package-lock.json .npmrc ./

# Install production dependencies
RUN npm ci --omit=dev

# Add tools for troubleshooting (must run as root before switching user).
# Alpine equivalents: iputils → iputils, postgresql-client → postgresql-client, net-tools → net-tools.
RUN apk add --no-cache iputils postgresql-client net-tools

# Copy the remaining project files and set ownership to the built-in node user (UID 1000)
COPY --chown=node:node . .

# Expose the port your backend runs on (5001)
EXPOSE 5001

# Switch to non-root user — node:24-alpine image includes this user at UID 1000
USER node

# Command to start your backend
CMD ["node", "/app/index.js"]
