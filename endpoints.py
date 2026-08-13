#!/usr/bin/env python3
"""
QuickShare: проверка доступности точек обмена ИЗ ВАШЕЙ СЕТИ. Без VPN.

Для каждого кандидата выполняется настоящее TLS-рукопожатие и HTTP-upgrade
до WebSocket (ответ 101 = путь живой целиком, не только TCP). Для ntfy.sh —
полный круг: публикация 200 байт и чтение их обратно.

Ничего не публикует в чужие каналы, кроме одного случайного топика ntfy.
Результат -> endpoints_result.txt
"""

import base64
import json
import os
import socket
import ssl
import time
import urllib.request

OUT = []


def say(line=""):
    print(line)
    OUT.append(line)


def ws_probe(host, port, path="/", timeout=8):
    """TLS + HTTP Upgrade. Возвращает (код, мс) или (описание ошибки, None)."""
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Protocol: mqtt\r\n"
        "User-Agent: Mozilla/5.0\r\n"
        "\r\n"
    )
    ctx = ssl.create_default_context()
    t0 = time.time()
    try:
        raw = socket.create_connection((host, port), timeout=timeout)
        tls = ctx.wrap_socket(raw, server_hostname=host)   # SNI как у браузера
        tls.sendall(req.encode())
        resp = tls.recv(1024).decode(errors="replace")
        tls.close()
    except Exception as exc:
        return (f"{type(exc).__name__}: {exc}", None)
    ms = int((time.time() - t0) * 1000)
    first = resp.split("\r\n")[0] if resp else "<пустой ответ>"
    return (first.strip(), ms)


say("=" * 74)
say("Проверка точек обмена (без VPN)")
say("=" * 74)

say()
say("--- Nostr-релеи (эфемерные события, WSS:443) ---")
for host in ["relay.damus.io", "nos.lol", "relay.nostr.band",
             "relay.primal.net", "nostr.mom", "relay.snort.social"]:
    status, ms = ws_probe(host, 443, "/")
    say(f"  {host:24} {status[:44]:46} {(str(ms) + ' ms') if ms else ''}")

say()
say("--- MQTT-брокеры поверх WebSocket ---")
for host, port, path in [
    ("broker.emqx.io", 8084, "/mqtt"),
    ("broker.emqx.io", 443, "/mqtt"),
    ("test.mosquitto.org", 8081, "/mqtt"),
    ("test.mosquitto.org", 443, "/mqtt"),
    ("broker.hivemq.com", 8884, "/mqtt"),
    ("mqtt.flespi.io", 443, "/mqtt"),
]:
    status, ms = ws_probe(host, port, path)
    say(f"  {host + ':' + str(port):28} {status[:42]:44} {(str(ms) + ' ms') if ms else ''}")

say()
say("--- ntfy.sh: полный круг публикация -> чтение ---")
topic = "qs-" + base64.urlsafe_b64encode(os.urandom(9)).decode().rstrip("=")
payload = os.urandom(150)
blob = base64.b64encode(payload).decode()
try:
    t0 = time.time()
    req = urllib.request.Request(f"https://ntfy.sh/{topic}", data=blob.encode(), method="PUT")
    urllib.request.urlopen(req, timeout=10).read()
    put_ms = int((time.time() - t0) * 1000)
    say(f"  публикация 200 байт: {put_ms} ms, топик {topic}")

    t1 = time.time()
    got = urllib.request.urlopen(
        f"https://ntfy.sh/{topic}/json?poll=1", timeout=10).read().decode()
    get_ms = int((time.time() - t1) * 1000)
    ok = any(json.loads(l).get("message") == blob
             for l in got.strip().splitlines() if l.strip())
    say(f"  чтение обратно:      {get_ms} ms, данные {'совпали' if ok else 'НЕ совпали'}")
    say(f"  полный круг:         {put_ms + get_ms} ms")
except Exception as exc:
    say(f"  ntfy.sh недоступен: {type(exc).__name__}: {exc}")

say()
say("--- Публичные TURN (запасной путь для данных) ---")
for host, port in [("openrelay.metered.ca", 443), ("turn.cloudflare.com", 443),
                   ("relay.metered.ca", 443)]:
    try:
        t0 = time.time()
        s = socket.create_connection((host, port), timeout=6)
        s.close()
        say(f"  {host + ':' + str(port):30} доступен, {int((time.time() - t0) * 1000)} ms")
    except Exception as exc:
        say(f"  {host + ':' + str(port):30} недоступен ({type(exc).__name__})")

say()
say("Строка вида 'HTTP/1.1 101' = путь живой целиком.")
say("Отдайте endpoints_result.txt обратно в чат.")

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "endpoints_result.txt")
with open(path, "w") as fh:
    fh.write("\n".join(OUT) + "\n")
print(f"\nСохранено: {path}")
