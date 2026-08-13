#!/usr/bin/env python3
"""
QuickShare: диагностика сети БЕЗ VPN.

Запускать при выключенном VPN. Ничего не меняет в системе и на роутере:
только читает маршруты, интерфейсы и шлёт read-only запросы (STUN Binding,
SSDP M-SEARCH, UPnP GetExternalIPAddress). Порты не пробрасывает.

Результат пишется в netcheck_result.txt рядом со скриптом.
"""

import os
import re
import socket
import struct
import subprocess
import sys
import urllib.request

OUT = []


def say(line=""):
    print(line)
    OUT.append(line)


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15).stdout
    except Exception as exc:
        return f"<ошибка: {exc}>"


def section(title):
    say()
    say("=" * 70)
    say(title)
    say("=" * 70)


# ---------------------------------------------------------------- 1. VPN off?
section("1. Проверка, что VPN действительно выключен")

default_routes = [l for l in run(["netstat", "-rn", "-f", "inet"]).splitlines()
                  if l.startswith("default")]
for line in default_routes:
    say("  " + line.strip())

tunnel_default = any(re.search(r"\b(utun|tun|ppp|ipsec)\d*", l) for l in default_routes)
if tunnel_default:
    say()
    say("  !! Маршрут по умолчанию всё ещё идёт через туннель.")
    say("  !! Выключите VPN полностью и запустите скрипт заново — иначе замеры недостоверны.")
else:
    say()
    say("  OK: маршрут по умолчанию идёт через физический интерфейс.")

primary_if = ""
m = re.search(r"interface:\s*(\S+)", run(["route", "-n", "get", "default"]))
if m:
    primary_if = m.group(1)
say(f"  Интерфейс по умолчанию: {primary_if or '?'}")

local_ip = ""
for iface in ([primary_if] if primary_if else []) + ["en0", "en1"]:
    if not iface:
        continue
    got = run(["ipconfig", "getifaddr", iface]).strip()
    if got:
        local_ip, primary_if = got, iface
        break
say(f"  Локальный IPv4: {local_ip or 'не определён'} ({primary_if})")


# --------------------------------------------------------------- 2. Public IP
section("2. Публичный IPv4 и наличие IPv6")

public_ip = ""
for url in ("https://api.ipify.org", "https://icanhazip.com"):
    try:
        public_ip = urllib.request.urlopen(url, timeout=6).read().decode().strip()
        say(f"  Публичный IPv4 ({url}): {public_ip}")
        break
    except Exception as exc:
        say(f"  {url}: ошибка {exc}")

if public_ip.startswith("100.") :
    o2 = int(public_ip.split(".")[1])
    if 64 <= o2 <= 127:
        say("  -> адрес из 100.64.0.0/10: это CGNAT провайдера, входящие невозможны")

v6 = [l.strip() for l in run(["ifconfig"]).splitlines()
      if l.strip().startswith("inet6") and re.search(r"inet6 [23]", l)]
if v6:
    say("  Глобальные IPv6-адреса на интерфейсах:")
    for a in v6:
        say("    " + a)
else:
    say("  Глобальных IPv6-адресов на интерфейсах нет")

try:
    got6 = urllib.request.urlopen("https://api64.ipify.org", timeout=6).read().decode().strip()
    say(f"  IPv6-связность наружу: {got6}" if ":" in got6
        else f"  IPv6-связность наружу отсутствует (получен IPv4 {got6})")
except Exception as exc:
    say(f"  IPv6-связность наружу отсутствует ({exc})")


# ------------------------------------------------------------- 3. STUN / NAT
section("3. Тип NAT (один сокет опрашивает разные STUN-серверы)")

STUN_SERVERS = [
    ("stun.l.google.com", 19302),
    ("stun.cloudflare.com", 3478),
    ("stun.fitauto.ru", 3478),
    ("stun.sipnet.ru", 3478),
    ("stun.ru-brides.com", 3478),
]


def stun_binding(sock, host, port):
    tid = os.urandom(12)
    sock.sendto(struct.pack(">HHI12s", 0x0001, 0, 0x2112A442, tid),
                (socket.gethostbyname(host), port))
    data, _ = sock.recvfrom(1024)
    off, end = 20, 20 + struct.unpack(">H", data[2:4])[0]
    while off + 4 <= end:
        atype, alen = struct.unpack(">HH", data[off:off + 4])
        val = data[off + 4:off + 4 + alen]
        if atype == 0x0020:
            p = struct.unpack(">H", val[2:4])[0] ^ 0x2112
            ip = bytes(b ^ c for b, c in zip(val[4:8], b"\x21\x12\xa4\x42"))
            return socket.inet_ntoa(ip), p
        off += 4 + alen + ((4 - alen % 4) % 4)
    raise RuntimeError("нет XOR-MAPPED-ADDRESS")


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3)
sock.bind(("0.0.0.0", 0))
say(f"  Локальный порт сокета: {sock.getsockname()[1]}")

mapped_ports, mapped_ip = [], ""
for host, port in STUN_SERVERS:
    try:
        ip, p = stun_binding(sock, host, port)
        mapped_ip = ip
        mapped_ports.append(p)
        say(f"    через {host:24} -> {ip}:{p}")
    except Exception as exc:
        say(f"    через {host:24} -> нет ответа ({exc})")
sock.close()

say()
if len(mapped_ports) < 2:
    say("  ВЕРДИКТ: недостаточно ответов, тип NAT не определён")
elif len(set(mapped_ports)) == 1:
    say("  ВЕРДИКТ: Endpoint-Independent Mapping (cone NAT).")
    say("           Hole punching возможен — прямое P2P без relay реально.")
else:
    say("  ВЕРДИКТ: Endpoint-Dependent Mapping (симметричный NAT / CGNAT).")
    say("           Прямое P2P между двумя такими сторонами не устанавливается.")

if mapped_ip and public_ip and mapped_ip != public_ip:
    say(f"  Внимание: STUN видит {mapped_ip}, а HTTP-сервис {public_ip} — разные выходы.")


# ------------------------------------------------------------------ 4. UPnP
section("4. UPnP / IGD на роутере (read-only, порт НЕ пробрасывается)")

igd_location = ""
if not local_ip:
    say("  Пропущено: локальный IP не определён")
else:
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
           'MAN: "ssdp:discover"\r\nMX: 2\r\n'
           "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # привязка к физическому интерфейсу, иначе запрос уйдёт не туда
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(local_ip))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.bind((local_ip, 0))
    s.settimeout(4)
    try:
        s.sendto(msg.encode(), ("239.255.255.250", 1900))
        while True:
            data, addr = s.recvfrom(2048)
            for line in data.decode(errors="replace").splitlines():
                if line.upper().startswith("LOCATION"):
                    igd_location = line.split(":", 1)[1].strip()
                    say(f"  IGD ответил: {addr[0]}  {igd_location}")
    except socket.timeout:
        pass
    except Exception as exc:
        say(f"  ошибка SSDP: {exc}")
    s.close()

    if not igd_location:
        say("  IGD не ответил — UPnP на роутере недоступен или выключен.")

# read-only SOAP: спросить у роутера его внешний IP (маппинг не создаётся)
if igd_location:
    try:
        xml = urllib.request.urlopen(igd_location, timeout=6).read().decode(errors="replace")
        ctrl = re.search(r"<controlURL>([^<]+)</controlURL>", xml)
        svc = re.search(r"<serviceType>(urn:schemas-upnp-org:service:WANIPConnection:\d)</serviceType>", xml) \
            or re.search(r"<serviceType>(urn:schemas-upnp-org:service:WANPPPConnection:\d)</serviceType>", xml)
        if ctrl and svc:
            base = re.match(r"(https?://[^/]+)", igd_location).group(1)
            url = base + ctrl.group(1) if ctrl.group(1).startswith("/") else ctrl.group(1)
            body = ('<?xml version="1.0"?><s:Envelope '
                    'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                    f'<u:GetExternalIPAddress xmlns:u="{svc.group(1)}"/>'
                    '</s:Body></s:Envelope>').encode()
            req = urllib.request.Request(url, data=body, headers={
                "Content-Type": 'text/xml; charset="utf-8"',
                "SOAPAction": f'"{svc.group(1)}#GetExternalIPAddress"',
            })
            resp = urllib.request.urlopen(req, timeout=8).read().decode(errors="replace")
            ext = re.search(r"<NewExternalIPAddress>([^<]*)</NewExternalIPAddress>", resp)
            router_ip = ext.group(1) if ext else "?"
            say(f"  Внешний IP по данным роутера: {router_ip}")
            if router_ip and public_ip and router_ip != public_ip:
                say("  -> НЕ совпадает с публичным IP: вы за вторым NAT провайдера (CGNAT).")
                say("     Проброс порта на роутере входящие соединения не откроет.")
            elif router_ip == public_ip:
                say("  -> Совпадает с публичным IP: белый адрес, проброс порта имеет смысл.")
    except Exception as exc:
        say(f"  Не удалось опросить IGD: {exc}")


# ------------------------------------------------------------------ 5. TURN
section("5. Доступность публичных TURN/STUN хостов (TCP-коннект)")

for host, port in [("openrelay.metered.ca", 80), ("openrelay.metered.ca", 443),
                   ("relay.expressturn.com", 443), ("turn.cloudflare.com", 443)]:
    try:
        s = socket.create_connection((host, port), timeout=5)
        s.close()
        say(f"  {host}:{port:<5} TCP-коннект есть")
    except Exception as exc:
        say(f"  {host}:{port:<5} недоступен ({exc})")


# ------------------------------------------------------------------- итог
section("ИТОГ")
say("  Отдайте файл netcheck_result.txt обратно в чат.")

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "netcheck_result.txt")
with open(path, "w") as fh:
    fh.write("\n".join(OUT) + "\n")
print(f"\nСохранено: {path}")
