# Node.js API image for the Regional Health service.
FROM node:20-slim

# The seed script (run inside this container) needs the mysql CLI.
RUN apt-get update \
    && apt-get install -y --no-install-recommends default-mysql-client bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

COPY --chown=node:node package.json ./
RUN npm install --omit=dev

COPY --chown=node:node . .

# The seed script lives in ../data-seed and is bind-mounted at runtime by
# docker-compose to /usr/local/bin/seed.sh (it is outside this build context,
# so it cannot be COPYed here).

# DS-0002: drop root for the runtime process. node:20-slim ships a non-root
# `node` user. This sits after npm install (which needs root to write into
# the image) and before CMD, so only the running app is unprivileged.
USER node

EXPOSE 3000

CMD ["node", "server.js"]
