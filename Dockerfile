# مرحله اول: کلون و کامپایل سورس واقعی WhiteDNS/CottenDNS با Go
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git
WORKDIR /src

# دریافت مستقیم سورس رسمی از گیت‌هاب WhiteDNS/CottenDNS
RUN git clone https://github.com/WhiteDNS/CottenDNS.git .

# کامپایل باینری واقعی سرور CottenDNS
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /cottendns-server ./cmd/server

# مرحله دوم: اجرای سرور واقعی
FROM alpine:3.20

RUN apk add --no-cache ca-certificates bash curl
WORKDIR /app

COPY --from=builder /cottendns-server /app/cottendns-server
COPY --from=builder /src/server_config.toml.simple /app/server_config.toml

# اسکریپت استارتاپ برای تنظیم دامنه و کلید واقعی در server_config.toml
RUN printf '#!/bin/bash\n\
set -e\n\
DOMAIN="${COTTENDNS_DOMAIN:-v.example.com}"\n\
sed -i "s|DOMAIN = .*|DOMAIN = [\"$DOMAIN\"]|g" /app/server_config.toml\n\
exec /app/cottendns-server --config /app/server_config.toml --udp-port 5353\n' > /app/ start.sh && chmod +x /app/start.sh

EXPOSE 10000 5353

CMD ["/app/start.sh"]
