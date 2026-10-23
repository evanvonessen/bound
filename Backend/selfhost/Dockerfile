FROM node:22.21.1-alpine3.22
WORKDIR /app/selfhost
COPY selfhost/package.json selfhost/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund
COPY --chown=node:node . /app
RUN mkdir -p /var/lib/bound/files && chown node:node /var/lib/bound/files
USER node
EXPOSE 8080
CMD ["node", "server.mjs"]
