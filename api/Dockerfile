# Node.js API image for the Regional Health service.
#
# Two stages so npm never reaches the runtime image: npm bundles its own
# vulnerable deps (brace-expansion, ip-address, tar, minimatch, ...) that we
# cannot patch, and the app runs `node server.js` — it never needs npm.
FROM node:22-bookworm-slim AS build

WORKDIR /usr/src/app
COPY package.json ./
RUN npm install --omit=dev

FROM node:22-bookworm-slim

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

CMD ["node", "server.js"]
