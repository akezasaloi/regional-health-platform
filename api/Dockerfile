# Node.js API image for the Regional Health service.
#
# Two stages so npm never reaches the runtime image: npm bundles its own
# vulnerable deps (brace-expansion, ip-address, tar, minimatch, ...) that we
# cannot patch, and the app runs `node server.js` — it never needs npm.
# Base pinned by digest, not tag: a tag can be re-pointed at a different image
# under the same name. Dependabot bumps the digest through a reviewed PR.
FROM node:22-bookworm-slim@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436 AS build

WORKDIR /usr/src/app
COPY package.json ./
RUN npm install --omit=dev

FROM node:22-bookworm-slim@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436

# apt-get upgrade pulls the security-patched OS packages trivy flags in the
# base image; without it the image ships CVEs that already have fixes.
# Removing npm/npx drops the last vulnerable node packages from the image.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends default-mysql-client bash \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

WORKDIR /usr/src/app

COPY --from=build --chown=node:node /usr/src/app/node_modules ./node_modules
COPY --chown=node:node . .

# The seed script lives in ../data-seed and is bind-mounted at runtime by
# docker-compose to /usr/local/bin/seed.sh (it is outside this build context,
# so it cannot be COPYed here).

# DS-0002: drop root for the runtime process.
USER node

EXPOSE 3000

# Liveness from inside the container. Uses node rather than curl/wget so the
# runtime image needs no extra packages (each one is more CVE surface).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3000/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

CMD ["node", "server.js"]
