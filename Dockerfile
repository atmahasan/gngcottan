FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git bash
WORKDIR /src

# کلون کردن مخزن اصلی
RUN git clone https://github.com/WhiteDNS/CottenDNS.git .

# کامپایل هوشمند: پیدا کردن فایل اصلی (main.go) در هر کجای پروژه و ساخت باینری نهایی
RUN set -ex; \
    MAIN_FILE=$(find . -name "main.go" | head -n 1); \
    if [ -z "$MAIN_FILE" ]; then MAIN_FILE=$(find . -name "*.go" | head -n 1); fi; \
    echo "Building from: $MAIN_FILE"; \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /cottendns-server $(dirname "$MAIN_FILE")

FROM alpine:3.20

RUN apk add --no-cache ca-certificates bash curl
WORKDIR /app

COPY --from=builder /cottendns-server /app/cottendns-server

# اسکریپت راه‌اندازی برای Render
RUN printf '#!/bin/bash\n\
set -e\n\
PORT="${PORT:-10000}"\n\
echo "[*] Starting CottenDNS Server on port $PORT..."\n\
exec /app/cottendns-server --port "$PORT"\n' > /app/start.sh && chmod +x /app/start.sh

EXPOSE 10000

CMD ["/app/start.sh"]
