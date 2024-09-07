FROM node:20-slim AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
LABEL fly_launch_runtime="Node.js"
RUN corepack enable
COPY ./apps/api /app
WORKDIR /app
ENV redis-les.zeabur.internal:6379
ENV REDIS_RATE_LIMIT_URL=redis-les.zeabur.internal:6379
ENV PLAYWRIGHT_MICROSERVICE_URL=${PLAYWRIGHT_MICROSERVICE_URL:-http://playwright-service:3000}
ENV USE_DB_AUTHENTICATION=FALSE

ENV NUM_WORKERS_PER_QUEUE=2
ENV OPENAI_API_KEY=sk-sxs1OsIBdzH8OqgdDc03C8D8E15545E58f002b09747b0645
ENV OPENAI_BASE_URL=https://api.oneabc.org/v1
ENV MODEL_NAME=${MODEL_NAME:-gpt-4o-mini}




FROM base AS prod-deps
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --prod --frozen-lockfile

FROM base AS build
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile

RUN apt-get update -qq && apt-get install -y ca-certificates && update-ca-certificates
RUN pnpm install
RUN --mount=type=secret,id=SENTRY_AUTH_TOKEN \
    bash -c 'export SENTRY_AUTH_TOKEN="$(cat /run/secrets/SENTRY_AUTH_TOKEN)"; if [ -z $SENTRY_AUTH_TOKEN ]; then pnpm run build:nosentry; else pnpm run build; fi'

# Install Go
FROM golang:1.19 AS go-base
COPY ./apps/api/src/lib/go-html-to-md /app/src/lib/go-html-to-md

# Install Go dependencies and build parser lib
RUN cd /app/src/lib/go-html-to-md && \
    go mod tidy && \
    go build -o html-to-markdown.so -buildmode=c-shared html-to-markdown.go && \
    chmod +x html-to-markdown.so

FROM base
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y chromium chromium-sandbox && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
COPY --from=prod-deps /app/node_modules /app/node_modules
COPY --from=build /app /app
COPY --from=go-base /app/src/lib/go-html-to-md/html-to-markdown.so /app/dist/src/lib/go-html-to-md/html-to-markdown.so

# Start the server by default, this can be overwritten at runtime
EXPOSE 3002
ENV PUPPETEER_EXECUTABLE_PATH="/usr/bin/chromium"
CMD [ "pnpm", "run", "start:production" ]