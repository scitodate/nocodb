# syntax=docker/dockerfile:1

# This Dockerfile combines steps from two sources:
# 1. build-local-docker-image.sh: A script that automates building a local Docker image for NocoDB.
# 2. packages/nocodb/Dockerfile.local: A Dockerfile specifically for building and running the NocoDB application.

###########
# Builder
###########
FROM node:22-alpine as builder
WORKDIR /usr/src/app

# ======================================
# Section: Steps from build-local-docker-image.sh
# ======================================

# Install necessary dependencies
RUN apk add --no-cache python3 make g++ py3-setuptools

# Install pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

# Copy the entire project to the container
COPY . .

# Install dependencies
RUN pnpm bootstrap

# Build nc-gui
WORKDIR /usr/src/app/packages/nc-gui
ENV NODE_OPTIONS="--max_old_space_size=16384"
RUN pnpm run generate

# Copy nc-gui artifacts to the nocodb directory
WORKDIR /usr/src/app/packages/nocodb
RUN mkdir -p ./docker/nc-gui \
    && rsync -rvzh --delete /usr/src/app/packages/nc-gui/dist/ ./docker/nc-gui/

# Package nocodb
RUN EE=true /usr/src/app/node_modules/@rspack/cli/bin/rspack.js --config /usr/src/app/packages/nocodb/rspack.config.js

# ======================================
# Section: Steps from packages/nocodb/Dockerfile.local
# ======================================

# Prepare the final production build
WORKDIR /usr/src/app

# Copy necessary files for Dockerfile.local
COPY --link ./package.json ./package.json
COPY --link ./docker/nc-gui/ ./docker/nc-gui/
COPY --link ./docker/main.js ./docker/index.js
COPY --link ./docker/start-local.sh /usr/src/appEntry/start.sh
COPY --link src/public/ ./docker/public/

# Configure pnpm for flat node_modules
RUN echo "node-linker=hoisted" > .npmrc

# Install production dependencies, clean up, and set permissions
RUN pnpm uninstall nocodb-sdk
RUN pnpm install --prod --shamefully-hoist --reporter=silent \
    && pnpm dlx modclean --patterns="default:*" --ignore="nc-lib-gui/**,dayjs/**,express-status-monitor/**,@azure/msal-node/dist/**" --run \
    && rm -rf ./node_modules/sqlite3/deps \
    && chmod +x /usr/src/appEntry/start.sh

##########
# Runner
##########
FROM alpine:3.20
WORKDIR /usr/src/app

# Steps from packages/nocodb/Dockerfile.local
ENV NC_DOCKER=0.6 \
    NC_TOOL_DIR=/usr/app/data/ \
    NODE_ENV=production \
    PORT=8080

RUN apk add --update --no-cache \
    nodejs \
    dumb-init \
    curl \
    jq

# Copy production code & main entry file
COPY --link --from=builder /usr/src/app/ /usr/src/app/
COPY --link --from=builder /usr/src/appEntry/ /usr/src/appEntry/

EXPOSE 8080
ENTRYPOINT ["/usr/bin/dumb-init", "--"]

# Start Nocodb
CMD ["/usr/src/appEntry/start.sh"]
