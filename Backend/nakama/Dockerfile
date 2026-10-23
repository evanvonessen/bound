FROM node:22.21.1-alpine3.22 AS builder
WORKDIR /backend
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY types ./types
COPY src ./src
RUN npm run build

FROM heroiclabs/nakama:3.41.0
COPY --from=builder /backend/build/index.js /nakama/data/modules/index.js
COPY heroic/nakama-config.yml /nakama/data/bound.yml
# Supply database/auth secrets and runtime.env through the deployment's secret
# manager or CLI. This image deliberately contains no credentials or app data.
