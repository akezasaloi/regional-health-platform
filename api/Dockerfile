# Node.js API image for the Regional Health service.
#
# Two stages so npm never reaches the runtime image.
# Base pinned by digest, not tag — a tag can be re-pointed. Dependabot bumps it.
FROM node:25-bookworm-slim@sha256:81db02c4b671288a03915da9534dbd54f96d0e7c24d80ccc54f5b36b2e684370 AS build

WORKDIR /usr/src/app
COPY package.json ./
RUN npm install --omit=dev

FROM node:25-bookworm-slim@sha256:81db02c4b671288a03915da9534dbd54f96d0e7c24d80ccc54f5b36b2e684370

# apt-get upgrade picks up patched OS packages; removing npm drops the rest.
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

# node rather than curl/wget: no extra packages, no extra CVE surface.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3000/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

CMD ["node", "server.js"]
