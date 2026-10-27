# Single-process deploy: the Node server serves client/dist and hosts Socket.IO.
# Build:  docker build -t starfarers .     (from starfarers-online/)
# Run:    docker run -p 3000:3000 -v starfarers-data:/data starfarers
# Rooms are persisted as one JSON file each under DATA_DIR (/data, a volume).
FROM node:22-alpine AS build
RUN corepack enable && corepack prepare pnpm@10.28.0 --activate
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY shared/package.json shared/
COPY server/package.json server/
COPY client/package.json client/
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm --filter @starfarers/client build && pnpm --filter @starfarers/server build

FROM node:22-alpine
RUN corepack enable && corepack prepare pnpm@10.28.0 --activate
WORKDIR /app
ENV NODE_ENV=production PORT=3000 DATA_DIR=/data
VOLUME /data
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY shared/package.json shared/
COPY server/package.json server/
COPY client/package.json client/
RUN pnpm install --frozen-lockfile --prod
COPY --from=build /app/server/dist server/dist
COPY --from=build /app/client/dist client/dist
EXPOSE 3000
CMD ["node", "server/dist/index.js"]
