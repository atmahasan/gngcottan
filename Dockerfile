FROM python:3.11-slim

WORKDIR /app

# نصب کتابخانه‌های وب‌سوکت ناهمگام و DNS
RUN pip install --no-cache-dir aiohttp dnslib

# بازنویسی کامل هسته سرور برای Render (پشتیبانی همزمان از WS Tunnel + DoH + Auto Config Generator)
RUN cat << 'EOF' > /app/render_gateway.py
import os
import json
import socket
import struct
import base64
import asyncio
from aiohttp import web, WSMsgType
from dnslib import DNSRecord, RR, A, QTYPE

PORT = int(os.environ.get("PORT", 10000))
SECRET_KEY = os.environ.get("ENCRYPTION_KEY", "cotten-secret-key-2026")
UUID_HEX = os.environ.get("UUID", "11111111-1111-1111-1111-111111111111").replace("-", "")
SNI_PROXY = os.environ.get("SNI_PROXY", "50.7.85.220")

# لیست دامنه‌های ضدتحریم WhiteDNS
SPOOF_DOMAINS = {
    "openai.com": SNI_PROXY,
    "chatgpt.com": SNI_PROXY,
    "gemini.google.com": SNI_PROXY,
    "ai.google.dev": SNI_PROXY,
    "generativelanguage.googleapis.com": SNI_PROXY,
    "claude.ai": SNI_PROXY,
    "docker.io": SNI_PROXY,
    "docker.com": SNI_PROXY,
    "developer.android.com": SNI_PROXY,
    "dl.google.com": SNI_PROXY,
    "epicgames.com": SNI_PROXY,
    "ea.com": SNI_PROXY,
    "riotgames.com": SNI_PROXY,
    "spotify.com": SNI_PROXY
}

def match_spoof(qname: str):
    qname = qname.rstrip(".").lower()
    for dom, ip in SPOOF_DOMAINS.items():
        if qname == dom or qname.endswith("." + dom):
            return ip
    return None

def resolve_dns_packet(raw_query: bytes) -> bytes:
    try:
        req = DNSRecord.parse(raw_query)
        qname = str(req.q.qname)
        if req.q.qtype == QTYPE.A:
            ip = match_spoof(qname)
            if ip:
                reply = req.reply()
                reply.add_answer(RR(req.q.qname, QTYPE.A, rdata=A(ip), ttl=120))
                return reply.pack()
        elif req.q.qtype == QTYPE.AAAA and match_spoof(qname):
            return req.reply().pack()
    except Exception:
        pass

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.5)
    try:
        sock.sendto(raw_query, ("1.1.1.1", 53))
        data, _ = sock.recvfrom(4096)
        return data
    except Exception:
        return b""
    finally:
        sock.close()

async def handle_index(request):
    host = request.headers.get("Host", "YOUR-APP.onrender.com")
    return web.json_response({
        "status": "online",
        "service": "WhiteDNS-CottenDNS Render Core",
        "clipboard_configs_url": f"https://{host}/clip",
        "doh_url": f"https://{host}/dns-query",
        "ws_tunnel": f"wss://{host}/ws"
    })

async def handle_clip(request):
    """صفحه تولید خودکار کانفیگ برای کپی مستقیم در کلیپ‌بورد"""
    host = request.headers.get("Host", "YOUR-APP.onrender.com")
    vless_link = f"vless://11111111-1111-1111-1111-111111111111@104.18.18.25:443?encryption=none&security=tls&sni={host}&type=ws&host={host}&path=%2Fws#WhiteDNS-Render"
    cotten_uri = f"cottendns://{SECRET_KEY}@{host}:443/?path=%2Fws&security=tls&type=ws&sni={host}&socks_port=18000#WhiteDNS-Render"
    cotten_json = json.dumps({
        "remarks": "WhiteDNS - Render",
        "server": host,
        "server_port": 443,
        "ws_path": "/ws",
        "doh_url": f"https://{host}/dns-query",
        "encryption_key": SECRET_KEY,
        "local_socks5_port": 18000
    }, indent=2)

    text = (
        f"=== 1. WhiteDNS / CottenDNS URI (Copy to Clipboard) ===\n{cotten_uri}\n\n"
        f"=== 2. V2Ray / Hiddify VLESS Link (Copy to Clipboard) ===\n{vless_link}\n\n"
        f"=== 3. WhiteDNS JSON Config (Copy to Clipboard) ===\n{cotten_json}\n"
    )
    return web.Response(text=text, content_type="text/plain; charset=utf-8")

async def handle_doh(request):
    if request.method == "GET":
        b64_dns = request.query.get("dns", "")
        if not b64_dns:
            return web.Response(status=400, text="Missing dns param")
        b64_dns += "=" * ((4 - len(b64_dns) % 4) % 4)
        raw_query = base64.urlsafe_b64decode(b64_dns)
    else:
        raw_query = await request.read()

    loop = asyncio.get_event_loop()
    resp_data = await loop.run_in_executor(None, resolve_dns_packet, raw_query)
    return web.Response(body=resp_data, content_type="application/dns-message")

async def handle_ws(request):
    """تانل ترکیبی WebSocket: هم بسته‌های DNS/CottenDNS را جواب می‌دهد و هم ترافیک VLESS را تانل می‌کند"""
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    remote_reader = None
    remote_writer = None

    async def pipe_remote_to_ws(reader, websocket):
        try:
            while not reader.at_eof():
                data = await reader.read(8192)
                if not data:
                    break
                await websocket.send_bytes(data)
        except Exception:
            pass
        finally:
            await websocket.close()

    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                buf = msg.data

                # اگر اتصال TCP از قبل برقرار شده، دیتا را مستقیم بفرست
                if remote_writer:
                    remote_writer.write(buf)
                    await remote_writer.drain()
                    continue

                # بررسی هدر VLESS برای تانل کامل (پورت 18000 یا تانل کلی)
                if len(buf) > 24 and buf[1:17].hex() == UUID_HEX:
                    addons_len = buf[17]
                    cmd = buf[18 + addons_len]
                    port_idx = 19 + addons_len
                    dst_port = struct.unpack("!H", buf[port_idx:port_idx+2])[0]
                    atype = buf[port_idx+2]
                    addr_idx = port_idx + 3

                    if atype == 1: # IPv4
                        dst_addr = socket.inet_ntoa(buf[addr_idx:addr_idx+4])
                        payload_idx = addr_idx + 4
                    elif atype == 2: # Domain
                        dlen = buf[addr_idx]
                        dst_addr = buf[addr_idx+1:addr_idx+1+dlen].decode("utf-8", errors="ignore")
                        payload_idx = addr_idx + 1 + dlen
                    elif atype == 3: # IPv6
                        dst_addr = socket.inet_ntop(socket.AF_INET6, buf[addr_idx:addr_idx+16])
                        payload_idx = addr_idx + 16
                    else:
                        break

                    if cmd == 1: # TCP Tunnel
                        remote_reader, remote_writer = await asyncio.open_connection(dst_addr, dst_port)
                        await ws.send_bytes(bytes([buf[0], 0]))
                        if len(buf) > payload_idx:
                            remote_writer.write(buf[payload_idx:])
                            await remote_writer.drain()
                        asyncio.create_task(pipe_remote_to_ws(remote_reader, ws))
                    elif cmd == 2: # UDP / DNS
                        await ws.send_bytes(bytes([buf[0], 0]))
                        dns_payload = buf[payload_idx+2:]
                        loop = asyncio.get_event_loop()
                        ans = await loop.run_in_executor(None, resolve_dns_packet, dns_payload)
                        await ws.send_bytes(struct.pack("!H", len(ans)) + ans)
                else:
                    # حالت اختصاصی CottenDNS (بسته مستقیم DNS روی WebSocket)
                    loop = asyncio.get_event_loop()
                    ans = await loop.run_in_executor(None, resolve_dns_packet, buf)
                    await ws.send_bytes(ans)

            elif msg.type == WSMsgType.TEXT:
                # پشتیبانی از فرمت JSON-over-WS در کلاینت‌های WhiteDNS
                try:
                    data = json.loads(msg.data)
                    if "dns" in data:
                        raw_q = base64.b64decode(data["dns"])
                        loop = asyncio.get_event_loop()
                        ans = await loop.run_in_executor(None, resolve_dns_packet, raw_q)
                        await ws.send_str(json.dumps({"dns": base64.b64encode(ans).decode()}))
                except Exception:
                    pass
    finally:
        if remote_writer:
            remote_writer.close()
    return ws

app = web.Application()
app.router.add_get("/", handle_index)
app.router.add_get("/health", handle_index)
app.router.add_get("/clip", handle_clip)
app.router.add_get("/dns-query", handle_doh)
app.router.add_post("/dns-query", handle_doh)
app.router.add_get("/ws", handle_ws)

if __name__ == "__main__":
    print(f"[*] WhiteDNS Ready on port {PORT}", flush=True)
    web.run_app(app, host="0.0.0.0", port=PORT)
EOF

# ساخت لینک‌های کمکی برای اینکه هر دستوری در پنل Render بود بدون خطا اجرا شود
RUN ln -sf /app/render_gateway.py /app/render_gateway && \
    printf '#!/bin/sh\nexec python3 /app/render_gateway.py\n' > /app/entrypoint.sh && \
    
