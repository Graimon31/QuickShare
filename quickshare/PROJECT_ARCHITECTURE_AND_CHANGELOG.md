# QuickShare — Архитектура и чейнджлог

> Developer Onboarding Guide. Все утверждения ниже сверены с кодом в `lib/` на 2026-08-09.

---

## 1. Продуктовая концепция

QuickShare — бессерверное (zero-server) кроссплатформенное приложение для прямой передачи файлов между macOS, iOS, Android, Windows и Linux. Flutter/Dart, Clean Architecture + BLoC.

Инженерные принципы:

1. **Автономия от серверов.** Приложение работает «из коробки», без поднятия собственного сигнального сервера или облачного реле. (В репозитории есть `signaling_server/` — это опциональный путь, а не обязательная зависимость; см. §6.)
2. **Serverless WebRTC SDP-in-QR.** При передаче через интернет (LTE/5G) SDP Offer сжимается ZLib и зашивается прямо в QR-код. Телефон сканирует QR, распаковывает Offer и отправляет SDP Answer прямым HTTP POST на Mac.
3. **Мульти-протокольный фоллбэк:**
   - **Wi-Fi LAN** — высокоскоростной стриминг (QHTP / HTTP Range).
   - **Internet P2P (Direct)** — проброс портов через UPnP / NAT-PMP.
   - **Internet Relay (Fallback)** — TURN over UDP (:80), TURN over TCP (:80), TURNS over TLS (:443), с `'iceTransportPolicy': 'all'`.
   - **Bluetooth** — отдельные транспорты для sender/receiver.

---

## 2. Структура проекта

```
lib/
├── core/
│   ├── constants/       app_constants.dart — TURN-дефолты, таймауты, диапазон портов
│   ├── network/         auto_tunnel_service.dart, upnp_port_forwarder.dart,
│   │                    network_info_service.dart — WAN IP, UPnP/NAT-PMP
│   ├── webrtc/          sdp_compressor.dart — ZLib-сжатие + нормализация CRLF
│   ├── utils/           app_logger.dart — сквозное логирование в quickshare.log
│   ├── deep_link/       quickshare:// share-ссылки
│   ├── di/              service_locator.dart
│   └── router/, theme/, errors/, permissions/
├── features/
│   ├── sender/
│   │   ├── data/
│   │   │   ├── server/       local_http_server.dart — роут POST /webrtc/answer
│   │   │   ├── transports/   webrtc_transfer_transport.dart, http_transfer_transport.dart,
│   │   │   │                 bluetooth_transfer_transport.dart
│   │   │   ├── indexer/      file_indexer.dart
│   │   │   ├── qr/           qr_payload_encoder.dart
│   │   │   └── repositories/ sender_repository_impl.dart — резолв внешнего WAN IP
│   │   ├── domain/           entities, usecases, transports (интерфейсы)
│   │   └── presentation/     sender_bloc.dart, qr_display_page.dart
│   └── receiver/
│       ├── data/
│       │   ├── qr/           qr_payload_decoder.dart
│       │   ├── transports/   webrtc_receiver_transport.dart, bluetooth_receiver_transport.dart
│       │   ├── client/       qhtp_receiver_client.dart, http_file_downloader.dart
│       │   └── store/        session_state_store.dart
│       ├── domain/
│       └── presentation/     receiver_bloc.dart, download_progress_page.dart (Wakelock)
└── shared/
    ├── models/               qr_payload.dart, bluetooth_qr_payload.dart
    └── widgets/
```

---

## 3. Бессерверное WebRTC-рукопожатие (2-way handshake)

```
  macOS (Sender)                              iPhone (Receiver на LTE)
  --------------                              ------------------------
  1. createOffer() → сбор ICE-кандидатов
     (ожидание gathering ~1 s)
  2. ZLib-сжатие SDP Offer (SdpCompressor)
  3. Резолв публичного WAN IP + UPnP
     (AutoTunnelService)
  4. Генерация QRPayload → экран Mac
                                              5. Сканирование QR-кода
                                              6. ZLib-распаковка + нормализация CRLF
                                              7. setRemoteDescription(Offer)
                                              8. createAnswer() → setLocalDescription
                                              9. POST http://<WAN_IP>:<port>/webrtc/answer
 10. LocalHttpServer принимает POST
     (роут исключён из auth-проверки)
 11. WebRtcTransferTransport.handleDirectAnswer(sdp, type)
 --------------------------------------------------------------------------
            === Открытие DataChannel → передача файла чанками ===
```

Ключевые параметры канала (`AppConstants`): чанк `16 384` B, backpressure по `bufferedAmount` — `262 144` B (256 KB).

---

## 4. Чейнджлог внесённых исправлений

### 4.1. Разрешение `port == 0` для SDP QR-кодов

- **Файл:** [qr_payload.dart:136](lib/shared/models/qr_payload.dart#L136)
- **Проблема:** `isValid` строго требовал `port > 0`, из-за чего SDP-payload отвергался сканером с `Invalid QR Code`.
- **Решение:** условие ослаблено до
  `(mode == 'webrtc-sdp' || (sdpOffer != null && sdpOffer!.isNotEmpty) || port > 0)`.
- **⚠️ Важно для нового разработчика:** это защитная валидация, а **не** описание рантайма. Порт в SDP-режиме используется по-настоящему: ресивер строит из него endpoint `http://${payload.ip}:${payload.port}/webrtc/answer` ([receiver_bloc.dart:168](lib/features/receiver/presentation/bloc/receiver_bloc.dart#L168)). Фактически туда попадает захардкоженный `3000` из dummy-сессии, где никто не слушает — см. §6, дефект C.

### 4.2. Резолв публичного WAN IP компьютера

- **Файл:** [sender_repository_impl.dart:259](lib/features/sender/data/repositories/sender_repository_impl.dart#L259)
- **Проблема:** в QR зашивался LAN IP Mac (`192.168.x.x`), недоступный телефону на LTE.
- **Решение:** `AutoTunnelService().getPublicIpAddress()` + `checkServerlessReachability()`. Если UPnP отработал — берутся его `publicIp` / `externalPort`, иначе публичный IP, иначе `session.localIp`.

### 4.3. Принудительная нормализация CRLF (`\r\n`)

- **Файл:** [sdp_compressor.dart](lib/core/webrtc/sdp_compressor.dart)
- **Проблема:** нативный C++ парсер Google LibWebRTC на iOS падал с `SessionDescription is NULL` при Unix-переводах строк.
- **Решение:** в `decompress()` — `sdp.replaceAll(RegExp(r'\r?\n'), '\r\n')` (RFC 8866) плюс гарантированный завершающий `\r\n`.

### 4.4. Исправление BUNDLE-групп (`MID='0' matching no m= section`)

- **Файл:** [sdp_compressor.dart](lib/core/webrtc/sdp_compressor.dart)
- **Проблема:** регулярный фильтр вырезал секцию `m=audio` (несущую `a=mid:0`), но оставлял `a=group:BUNDLE 0` в заголовке сессии — парсер iOS отклонял Offer.
- **Решение:** переход на беспотерьное `zlib`-сжатие полного SDP (`zlib.encode` → `base64Url` без padding), целостность BUNDLE-групп сохраняется. Фоллбэк — plain base64, если zlib недоступен.

### 4.5. Сквозное логирование (`AppLogger`)

- **Файлы:** [app_logger.dart](lib/core/utils/app_logger.dart), [main.dart](lib/main.dart)
- Пишет события WebRTC, генерацию SDP и сетевые ответы с таймстемпами в `quickshare.log` (папка Documents на iOS/macOS) и дублирует в `flutter logs`. Есть чтение и очистка лога из кода (`readLog()`, `clear()`).

### 4.6. Защита от засыпания экрана (`WakelockPlus`)

- **Файлы:** [download_progress_page.dart](lib/features/receiver/presentation/pages/download_progress_page.dart), [local_http_server.dart](lib/features/sender/data/server/local_http_server.dart)
- `WakelockPlus.enable()` на время передачи (и на приёмнике, и на отправителе), `disable()` — по завершении/отмене. В UI приёмника показывается предупреждающая плашка.

---

## 5. Конфигурация (dart-define)

| Переменная | Дефолт | Назначение |
|---|---|---|
| `QUICKSHARE_TURN_URL` | `turn:openrelay.metered.ca:80` | Базовый TURN; из него автоматически строятся варианты TCP:80 и TURNS TLS:443 |
| `QUICKSHARE_TURN_USER` | `openrelaymodule` | TURN username |
| `QUICKSHARE_TURN_PASS` | `openrelaymodule` | TURN credential |
| `QUICKSHARE_SIGNALING_URL` | `ws://localhost:3000` | Опциональный сигнальный сервер (не нужен в SDP-in-QR режиме) |

STUN-серверы захардкожены: `stun.l.google.com:19302`, `stun1`, `stun2`.

`LocalHttpServer._bindServer()` выбирает первый свободный порт в диапазоне `serverPortMin=8000 … serverPortMax=9000` (на практике — 8000).

**Но в serverless-режиме в QR попадает `3000`**, потому что `SenderBloc._makeDummySession()` захардкодил `serverPort: 3000` ([sender_bloc.dart:186](lib/features/sender/presentation/bloc/sender_bloc.dart#L186)) — это зеркало дефолтного signaling URL `ws://localhost:3000`, а не порт файлового сервера. См. §6, дефект C.

---

## 6. Известные дефекты serverless-пути (открыты на 2026-08-09)

### A. Мангling SDP → `BUNDLE group contains a MID='0' matching no m= section` — ИСПРАВЛЕНО

Исправлено в исходниках 09.08 в 04:23 (§4.4), но воспроизводилось на устройствах до 09.08, т.к. последняя сборка iOS была от 08.08 21:57. Новый билд установлен на iPhone 09.08.

### B. Тонкий запас по ёмкости QR-кода — ИСПРАВЛЕНО

`QRPayload.encode()` применял base64 к JSON, внутри которого `sdpOffer` **уже** был base64 от zlib. Двойное кодирование давало +33 % поверх несжимаемых данных.

Замеры на SDP длины 7 672 (совпадает с реальными 7 622–8 366 из `quickshare.log`), лимит QR byte-mode v40 EC=L — **2 953**:

| Схема | Размер | Запас |
|---|---|---|
| Старая (двойной base64) | 2 376 | 19 % |
| Новая: `base64(zlib(json))`, сырой SDP внутри | 1 771 | 40 % |
| Новая + `pruneCandidatesForQr()` | **1 460** | 50 % |

**Блокирующим этот дефект не был** — реальные SDP влезали. Но 19 % запаса съедались при большем числе ICE-кандидатов, IPv6 или длинных именах файлов, и тогда `errorStateBuilder` в [qr_display_page.dart:197](lib/features/sender/presentation/pages/qr_display_page.dart#L197) показал бы `QR Render Error: …` вместо кода.

Исправлено:
- `QRPayload.encode()` — одно сжатие снаружи; `decode()` умеет читать и старый несжатый формат.
- `SdpCompressor.pruneCandidatesForQr()` — отсев `typ host`, IPv6, `.local` (mDNS) и `169.254.*` кандидатов. Трогает **только** строки `a=candidate:`, m= секции и BUNDLE-группы не затрагиваются — ровно то, что сломал старый regex-фильтр.
- `SdpCompressor.normalizeLineEndings()` выделен отдельно; `decompress()` распознаёт сырой SDP (`v=0`) и применяет к нему только нормализацию CRLF.
- Guard-тест «QR payload for a full-size gathered offer stays inside QR capacity» падает, если payload снова перевалит за 2 953 или если из SDP исчезнут `a=group:BUNDLE 0` / `a=mid:0` / `m=application`.

### C. Endpoint для SDP Answer не существует — ИСПРАВЛЕНО (блокирующий)

Цепочка в `_startSendingInternal()` при `mode == TransportType.internet` ([sender_bloc.dart:249](lib/features/sender/presentation/bloc/sender_bloc.dart#L249)):

1. `repository.startServer()` **не вызывается** — он есть только в Wi-Fi ветке (строка 346). `LocalHttpServer` не биндится вообще.
2. `_registerWebRtcRoutes()` (роут `POST /webrtc/answer`) регистрируется только внутри `start()` и `startQhtpSession()` — то есть в этом сценарии не регистрируется никогда.
3. В QR уходит `port: 3000` из dummy-сессии, приёмник строит `http://<WAN_IP>:3000/webrtc/answer`.
4. На :3000 слушает Node-процесс из `signaling_server/` — это WebSocket-сервер, POST-роутов в `server.js` нет вовсе.

Итог: SDP Answer с телефона уходил в 404, `handleDirectAnswer()` не вызывался, DataChannel не открывался. Рукопожатие из §3 не могло завершиться в принципе — независимо от фикса BUNDLE.

Исправлено: в ветке `TransportType.internet` теперь вызывается `repository.startServer(file)`, и в `QRPayload` уходит `session.serverPort` реально забинденного сервера вместо захардкоженного 3000. Если бинд не удался — пишется `AppLogger.error` с тегом `SENDER_BLOC`, а не тихий провал.

### D. `flutter run` маскирует провал установки

`flutter run -d <udid> --release` вернул **exit code 0** при `Error running application on iPhone` (причина была — заблокированный экран). Опасно для CI-шагов, завязанных на код возврата.

---

## 7. Команды сборки и проверки

Прогон тестов (56 тестов, все проходят — проверено 2026-08-09):

```bash
flutter test
```

Сборка релизного macOS-приложения:

```bash
flutter build macos
```

Сборка под iOS без подписи:

```bash
flutter build ios --no-codesign
```

Запуск на подключённом iPhone:

```bash
flutter run -d 00008110-001449080CF3801E --release
```
