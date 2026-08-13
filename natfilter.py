#!/usr/bin/env python3
"""
QuickShare: тест ФИЛЬТРАЦИИ NAT (RFC 5780). Запускать при ВЫКЛЮЧЕННОМ VPN.

Отображение (mapping) уже измерено — endpoint-independent (cone).
Здесь проверяется вторая, независимая характеристика: пропустит ли NAT
входящий UDP-пакет от хоста, которому мы ничего не отправляли.

Если да (full cone) — телефон сможет отправить SDP Answer напрямую на
внешний адрес Mac, и односторонний QR заработает без сервера.

Ничего не меняет: только STUN Binding Requests. Результат -> natfilter_result.txt
"""

import os
import socket
import struct
import sys

OUT = []


def say(line=""):
    print(line)
    OUT.append(line)


MAGIC = 0x2112A442
CHANGE_REQUEST = 0x0003
MAPPED_ADDRESS = 0x0001
CHANGED_ADDRESS = 0x0005      # RFC 3489
XOR_MAPPED_ADDRESS = 0x0020
OTHER_ADDRESS = 0x802C        # RFC 5780


def build(change_ip=False, change_port=False):
    tid = os.urandom(12)
    attrs = b""
    if change_ip or change_port:
        flags = (0x04 if change_ip else 0) | (0x02 if change_port else 0)
        attrs += struct.pack(">HHI", CHANGE_REQUEST, 4, flags)
    return struct.pack(">HHI12s", 0x0001, len(attrs), MAGIC, tid) + attrs, tid


def parse(data):
    out = {}
    if len(data) < 20:
        return out
    length = struct.unpack(">H", data[2:4])[0]
    off, end = 20, 20 + length
    while off + 4 <= end and off + 4 <= len(data):
        atype, alen = struct.unpack(">HH", data[off:off + 4])
        val = data[off + 4:off + 4 + alen]
        if atype in (MAPPED_ADDRESS, CHANGED_ADDRESS, OTHER_ADDRESS) and len(val) >= 8:
            out[atype] = (socket.inet_ntoa(val[4:8]), struct.unpack(">H", val[2:4])[0])
        elif atype == XOR_MAPPED_ADDRESS and len(val) >= 8:
            port = struct.unpack(">H", val[2:4])[0] ^ (MAGIC >> 16)
            ip = bytes(b ^ c for b, c in zip(val[4:8], struct.pack(">I", MAGIC)))
            out[atype] = (socket.inet_ntoa(ip), port)
        off += 4 + alen + ((4 - alen % 4) % 4)
    return out


def ask(sock, addr, change_ip=False, change_port=False, timeout=3.0):
    """Возвращает (attrs, from_addr) или (None, None)."""
    pkt, _ = build(change_ip, change_port)
    sock.settimeout(timeout)
    try:
        sock.sendto(pkt, addr)
    except Exception as exc:
        say(f"    ошибка отправки: {exc}")
        return None, None
    try:
        data, src = sock.recvfrom(2048)
    except socket.timeout:
        return None, None
    return parse(data), src


def mapped_of(attrs):
    return attrs.get(XOR_MAPPED_ADDRESS) or attrs.get(MAPPED_ADDRESS)


CANDIDATES = [
    ("stun.sipnet.ru", 3478),
    ("stun.fitauto.ru", 3478),
    ("stun.ru-brides.com", 3478),
    ("stun.voipgate.com", 3478),
    ("stun.voip.blackberry.com", 3478),
    ("stun.cloudflare.com", 3478),
]

say("=" * 70)
say("Тест фильтрации NAT (RFC 5780)")
say("=" * 70)

server = None
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", 0))
say(f"локальный порт: {sock.getsockname()[1]}")
say()

# --- Тест 1: обычный Binding Request. Нужен сервер, который отдаёт OTHER/CHANGED-ADDRESS
say("Тест 1 — базовый Binding Request, ищем сервер с двумя адресами:")
primary = None
other = None
for host, port in CANDIDATES:
    try:
        addr = (socket.gethostbyname(host), port)
    except Exception as exc:
        say(f"  {host:28} DNS не резолвится")
        continue
    attrs, src = ask(sock, addr)
    if not attrs:
        say(f"  {host:28} нет ответа")
        continue
    m = mapped_of(attrs)
    alt = attrs.get(OTHER_ADDRESS) or attrs.get(CHANGED_ADDRESS)
    say(f"  {host:28} внешний адрес {m[0]}:{m[1]}" + (f", второй адрес сервера {alt[0]}:{alt[1]}" if alt else ", второго адреса НЕТ"))
    if alt and not server:
        server, primary, other = host, addr, alt

if not server:
    say()
    say("Ни один сервер не отдал второй адрес — тест фильтрации выполнить нечем.")
    say("ВЕРДИКТ: не определено.")
else:
    say()
    say(f"Используем {server}: основной {primary[0]}:{primary[1]}, второй {other[0]}:{other[1]}")
    say()

    # --- Тест 2: ответ с ДРУГОГО IP и ДРУГОГО порта
    say("Тест 2 — просим ответить с другого IP и порта (change-ip + change-port):")
    attrs2, src2 = ask(sock, primary, change_ip=True, change_port=True, timeout=4.0)
    if attrs2:
        say(f"  ОТВЕТ ПОЛУЧЕН от {src2[0]}:{src2[1]}")
        say()
        say("  ВЕРДИКТ: Endpoint-Independent Filtering (FULL CONE).")
        say("           На внешний порт может писать ЛЮБОЙ хост.")
        say("           => Односторонний QR РАБОТАЕТ: телефон отправит Answer")
        say("              напрямую на внешний адрес Mac, сервер не нужен.")
    else:
        say("  ответа нет")
        say()
        # --- Тест 3: ответ с того же IP, но другого порта
        say("Тест 3 — просим ответить с того же IP, но другого порта (change-port):")
        attrs3, src3 = ask(sock, primary, change_ip=False, change_port=True, timeout=4.0)
        if attrs3:
            say(f"  ОТВЕТ ПОЛУЧЕН от {src3[0]}:{src3[1]}")
            say()
            say("  ВЕРДИКТ: Address-Dependent Filtering.")
            say("           NAT пропускает пакеты с любого порта хоста, которому мы уже писали,")
            say("           но не от незнакомых хостов.")
            say("           => Прямая доставка Answer от телефона НЕ пройдёт.")
        else:
            say("  ответа нет")
            say()
            say("  ВЕРДИКТ: Address-and-Port-Dependent Filtering (port-restricted cone).")
            say("           NAT пропускает только от тех, кому мы уже отправляли пакет.")
            say("           => Прямая доставка Answer от телефона НЕ пройдёт.")

sock.close()

say()
say("Отдайте natfilter_result.txt обратно в чат.")

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "natfilter_result.txt")
with open(path, "w") as fh:
    fh.write("\n".join(OUT) + "\n")
print(f"\nСохранено: {path}")
