FROM node:26-slim AS builder

WORKDIR /build
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.27-alpine

# Pick up upstream Alpine security patches released after this base image
# tag was built, rather than relying on the tag being re-pulled/rebuilt.
RUN apk update && apk upgrade --no-cache

RUN addgroup -S -g 10001 app && adduser -S -u 10001 appuser -G app \
    && chown -R appuser:app /var/cache/nginx /var/log/nginx /etc/nginx \
    && touch /var/run/nginx.pid \
    && chown appuser:app /var/run/nginx.pid

COPY --from=builder /build/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

USER 10001:10001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:8080/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
