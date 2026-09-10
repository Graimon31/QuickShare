# DirectDrop — баг-репорты по сверке с ТЗ

**Дата:** 2026-09-10
**Ветка:** `fix/transfer-reliability` (рабочее дерево, включая незакоммиченный Bluetooth/direct-link)
**Источник требований:** `requirements.html` (реконструкция ТЗ, 57 пунктов, 10 сентября 2026)
**Путь к ТЗ:** `/private/tmp/claude-501/-Users-mrgraimon-Desktop-Share/a4df8649-c4d5-4660-bd25-48bc4cac2d4b/scratchpad/requirements.html`
**Код:** `~/Desktop/Share/quickshare` и `~/Desktop/Share/cloudflare-worker`

## Правила чтения

- ID — `DD-NN`. Статусы: **Подтверждён** (можно брать в работу).
- Приоритет — предложение по коду; подтверждается владельцем продукта.
- «Критерии приёмки» — Given/When/Then, обязательное условие закрытия.
- «Для разработки» — указатели в код, не часть требования.
- Незакоммиченные файлы помечены явно.

Сверка — статическая (чтение кода и тестов). На устройствах прогон не делался.

## Сводная таблица

| ID | Название | Требование | Транспорт / слой | Приоритет | Статус |
|---|---|---|---|---|---|
| DD-01 | Bluetooth gen-4: в serve-кадре нет TLS-отпечатка | B4, F2, D2 | Bluetooth → Wi-Fi | Critical | Подтверждён |
| DD-02 | `POST /turn` без аутентификации, CORS `*` | F7, L, A3 | Worker | High | Подтверждён |
| DD-03 | Пароль хотспота уходит по BLE в открытом виде | F2, F3, B4 | Bluetooth | High | Подтверждён |
| DD-04 | Drag-and-drop создаёт сессию без проверки Wi-Fi | FR-CONN, G2 | Wi-Fi / desktop | Medium | Подтверждён |
| DD-05 | Worker недоступен → мёртвые baked-in TURN-креды | F7, G1 | Интернет | High | Подтверждён |
| DD-06 | Неизвестный ICE-путь обходит лимит relay | G4, L | Интернет | Medium | Подтверждён |
| DD-07 | Локальный release APK собирается неподписанным | F9 | Android / сборка | Medium | Подтверждён |
| DD-08 | Linux-артефакт в CI собирается как debug | K1, A2 | Linux / CI | Medium | Подтверждён |
| DD-09 | iOS убивает фоновую передачу: `voip` убран, замены нет | J1, D4 | iOS | Medium | Подтверждён |
| DD-10 | Старый BT-приёмник не берёт даже один файл | D6 vs B4 | Bluetooth | Low | Подтверждён |
| DD-11 | Нет прямого пути: экран разбора не показывается | G1 | Интернет | High | Подтверждён |
| DD-12 | Отказ из‑за дорогого TURN затирается ошибкой | G4, L | Интернет | High | Подтверждён |
| DD-13 | iOS entitlement хотспота не попадает в подпись | B3, G1 | iOS | High | Подтверждён |
| DD-14 | Bluetooth-диалог на iOS обещает панель Wi-Fi | G2 | iOS / Bluetooth | Medium | Подтверждён |
| DD-15 | Сбой BT API считается «радио включено» | FR-CONN | Bluetooth | Medium | Подтверждён |
| DD-16 | Fallback на iPhone/Mac обещает поднять сеть | G2 | iOS / macOS | Low | Подтверждён |
| DD-17 | Ошибки и журнал передач не локализованы | I1 | UI | Medium | Подтверждён |
| DD-18 | Скан QR начинает приём без подтверждения | E4 | все | High | Подтверждён |
| DD-19 | `/info` без токена отдаёт имя и размер | F1 | Wi-Fi / LAN | Medium | Подтверждён |
| DD-20 | Android/Linux отвечают успехом на голый `START` | F3 | Bluetooth | Medium | Подтверждён |
| DD-21 | Приёмник не режет манифест и глубину пути | F10 | QHTP / WebRTC / BLE | Medium | Подтверждён |
| DD-22 | Ссылки `directdrop://join?room=` мертвые | E5 | диплинки | Low | Подтверждён |
| DD-23 | Apple BLE всё ещё качает файл на gen 4 | B4, D2 | Bluetooth iOS/macOS | High | Подтверждён |
| DD-24 | WebRTC шлёт прогресс на каждый чанк | J5 | Интернет | High | Подтверждён |
| DD-25 | QR ждёт полный обход дерева | BUG-10 | все | Medium | Подтверждён |
| DD-26 | WebRTC/BLE публикуют файл без сверки размера | D2 | Интернет / BLE | Medium | Подтверждён |

---

## DD-01. Bluetooth gen-4: в serve-кадре нет TLS-отпечатка

**Приоритет:** Critical
**Требования:** B4, F2, D2
**Git:** незакоммичено (`direct_link_coordinator.dart`, `bluetooth_receive_page.dart`, `sender_bloc.dart`)

**Шаги:**
1. Собрать текущее рабочее дерево.
2. Отправить любой файл по Bluetooth (протокол поколения 4: байты по BLE больше не идут).
3. Дождаться подъёма Wi-Fi-линка и QHTP-pull на приёмнике.

**Фактический результат:** отправитель отдаёт только `{ip, port, token}`. `LinkServeInfo` поля отпечатка не имеет. Приёмник собирает `QRPayload` без `tlsFingerprint`. QHTP-клиент отказывается от пустого отпечатка (даунгрейда на HTTP нет) с текстом «обновите отправителя». Файл не едет. Старого BLE-пути у этого билда тоже нет.

**Ожидаемый результат:** serve-кадр несёт тот же `tf`, что QR и mDNS. Приёмник пинит сертификат сессии.

**Критерии приёмки:**
- **Given** оба устройства на поколении 4, **When** передача идёт по Bluetooth, **Then** QHTP-pull устанавливает TLS с пином отпечатка из serve-кадра и файл доходит.
- **Given** отпечаток отсутствует или не совпал, **Then** приём отклоняется, HTTP-даунгрейда нет.

**Для разработки:** `LinkServeInfo` в `lib/core/network/direct_link_coordinator.dart:166–184`; сборка кадра в `sender_bloc.dart:954–956`; приём в `bluetooth_receive_page.dart:159–166`; отказ в `qhtp_receiver_client.dart:396–399`. Добавить `tlsFingerprint` (sender берёт `localServer.tlsFingerprint`) и прокинуть в `QRPayload.tlsFingerprint`.

---

## DD-02. `POST /turn` без аутентификации, CORS `*`

**Приоритет:** High
**Требования:** F7, L («чужой ресурс не тратится молча»), A3

**Шаги:**
```bash
curl -X POST https://directdrop-worker.directdrop-worker.workers.dev/turn
```

**Фактический результат:** любой origin получает короткоживущие TURN-креды Cloudflare Calls. Rate limit в README помечен как «ещё нет». URL Worker зашит в клиент по умолчанию. Квоту проекта можно вычерпать с любой машины, в том числе из браузера.

**Ожидаемый результат:** выдача кредов только клиентам сессии; как минимум rate limit и отказ неизвестному Origin.

**Критерии приёмки:**
- **Given** запрос без секрета сессии / HMAC, **When** `POST /turn`, **Then** 401/403, креды не выданы.
- **Given** всплеск запросов с одного IP, **Then** срабатывает лимит.

**Для разработки:** `cloudflare-worker/src/index.js:18–23, 287–288`; дефолт URL в `app_constants.dart:123–126`.

---

## DD-03. Пароль хотспота уходит по BLE в открытом виде

**Приоритет:** High
**Требования:** F2, F3, B4

**Фактический результат:** `AP:<ssid>:<passphrase>` и JSON-директива `{ssid, passphrase}` пишутся в GATT без bonding/шифрования характеристики. Рядом сидящий сниффер получает WPA-пароль сети, которую приложение только что подняло.

Без токена QHTP файлы не забрать (401). Вместе с DD-01 возможен evil twin: та же SSID/пароль, приёмник идёт на атакующего.

Linux/Windows именуют сеть из session code (джойнер выводит креды локально). Android `startLocalOnlyHotspot` игнорирует переданные SSID/PSK и шлёт случайную пару по BLE.

**Ожидаемый результат:** креды линка либо выводятся из session code, либо едут зашифрованными ключом из session token.

**Критерии приёмки:**
- **Given** Android-хост поднял сеть, **When** GATT-сниффер слушает без session token, **Then** passphrase не читается в открытом виде.

**Для разработки:** `ble_control_protocol.dart:84–95`; `direct_link_coordinator.dart:126–134`; `HotspotPlugin.kt` игнорирует ssid/passphrase.

---

## DD-04. Drag-and-drop создаёт сессию без проверки Wi-Fi

**Приоритет:** Medium
**Требования:** FR-CONN / BUG-04 из `2026-08-29-transfer-bugfixes.md`, G2
**Платформы:** macOS, Windows, Linux

**Шаги:**
1. Выключить Wi-Fi на десктопе.
2. Перетащить файл на карточку «Отправить» на домашнем экране.

**Фактический результат:** `home_page.dart` сразу ведёт на `/send` с `qhtpPaths`. `FilePickerPage.initState` шлёт `StartQhtpSend` с дефолтным `TransportType.wifi` без `TransportPreconditions.ensure`. Предусловия срабатывают только при ручном переключении радиокнопки. То же для `_pickItems` / `_pickMedia` после уже выбранного режима.

**Ожидаемый результат:** нет Wi-Fi — диалог, сессия и QR не создаются.

**Критерии приёмки:**
- **Given** Wi-Fi выключен, **When** файл перетащен на «Отправить» или выбран в пикере при режиме Wi-Fi, **Then** показан запрос включения; сессия не создана.

**Для разработки:** `home_page.dart:225–231`; `file_picker_page.dart:32, 42–50, 77–89, 137–154`. Вызвать `ensure` непосредственно перед каждым `StartQhtpSend`.

---

## DD-05. Worker недоступен → мёртвые baked-in TURN-креды

**Приоритет:** High (из РФ / при блокировке `workers.dev`)
**Требования:** F7, G1, работа из российских сетей

**Фактический результат:** `configurationDynamic` при ошибке Worker молча берёт статику `openrelaymodule` / `standard.relay.metered.ca`. В комментариях прямо сказано: эти креды не проверены. Metered в Worker не сконфигурирован (один провайдер, не два).

Из РФ `workers.dev` часто режется. Нет живого TURN → VPN/symmetric NAT не пробивается → пользователь не получает внятного «сервис недоступен».

**Ожидаемый результат:** креды с `POST /turn`, не из бинарника. Если сервис молчит — честный экран (G1) / хотспот, без притворства, что relay есть.

**Критерии приёмки:**
- **Given** Worker не отвечает, **When** интернет-передача за NAT/VPN, **Then** экран разбора или отказ, а не тихий ICE без пути.
- Релизный бинарь не содержит публичных TURN username/password.

**Для разработки:** `ice_servers.dart:122–151`; `app_constants.dart:73–80`.

---

## DD-06. Неизвестный ICE-путь обходит лимит relay

**Приоритет:** Medium
**Требования:** G4, L

**Фактический результат:**
```
unknown → IcePathKind.unknown
if (path != IcePathKind.relayed) return true;
```
Неизвестный путь = «можно слать». Если `getStats()` пустой или падает, гигабайты уходят через чужой TURN. Потолок сейчас 2 ГБ (`maxRelayTransferBytes`), не 50 МБ из README.

**Ожидаемый результат:** нет подтверждённой прямой пары — не начинать (или считать relayed).

**Критерии приёмки:**
- **Given** `selectedPathKind` вернул `unknown`, **When** сессия больше лимита relay, **Then** байты не отправлены, показан fallback.

**Для разработки:** `ice_gathering.dart:100–122`; проверка после открытия канала в `webrtc_transfer_transport.dart:204–231`.

---

## DD-07. Локальный release APK собирается неподписанным

**Приоритет:** Medium
**Требования:** F9

**Фактический результат:** ТЗ (реконструкция) говорит «сборка падает». CI на `push` без keystore действительно `exit 1`. Локально и на PR:

```
signingConfig null
println("... building an UNSIGNED release")
```

`flutter build apk --release` без `key.properties` — успех и неподписанный артефакт.

**Ожидаемый результат:** нет ключа → release не проходит (кроме явно помеченного исключения).

**Критерии приёмки:**
- **Given** нет env/`key.properties`, **When** `flutter build apk --release`, **Then** Gradle падает.
- CI на теге/`push` в main без секрета — красный прогон, артефакт не выкладывается (уже так).

**Для разработки:** `android/app/build.gradle:105–115`. `throw new GradleException(...)` в `else`; unsigned только за `ALLOW_UNSIGNED_RELEASE=1`.

---

## DD-08. Linux-артефакт в CI собирается как debug

**Приоритет:** Medium
**Требования:** K1, A2

**Фактический результат:**
- macOS: `flutter build macos --release`
- Windows: `flutter build windows --release`
- Linux: `flutter build linux --debug`

В публичный релиз Linux уезжает debug (логи, asserts, другой профиль производительности).

**Критерии приёмки:**
- **Given** тег `v*`, **When** отрабатывает desktop workflow, **Then** Linux-бандл — `--release`.

**Для разработки:** `.github/workflows/build_desktop.yml:80`.

---

## DD-09. iOS убивает фоновую передачу: `voip` убран, замены нет

**Приоритет:** Medium (ожидаемый потолок для WebRTC; для LAN — регрессия UX)
**Требования:** J1, D4

**Фактический результат:** на `main` есть коммит `fix(ios): remove UIBackgroundModes voip to prevent iOS launch termination`. В `Info.plist` нет `UIBackgroundModes`. Wakelock держит экран только в foreground. `TransferInterruptionGuard` даёт 1 минуту на возврат и умеет продолжить QHTP; WebRTC-канал при suspend умирает. J1 в реконструкции ТЗ ещё ссылается на `voip`.

**Ожидаемый результат:** честный текст «не сворачивайте приложение» + для LAN — background `URLSession`. `voip` не возвращать (termination / App Store).

**Критерии приёмки:**
- **Given** iOS, LAN-передача, **When** пользователь на 10 с уходит в другое приложение и возвращается в пределах grace, **Then** QHTP продолжается с байта.
- **Given** WebRTC, **When** приложение свернуто, **Then** на экране заранее сказано, что приём оборвётся.

**Для разработки:** `ios/Runner/Info.plist`; `interruption_guard.dart`. Обновить J1 в ТЗ.

---

## DD-10. Старый BT-приёмник не берёт даже один файл

**Приоритет:** Low / product
**Требования:** D6 vs B4 (конфликт)

**Фактический результат:** D6: однофайловому старому клиенту папку не шлют, один файл — шлют. B4 (gen 4): по BLE байты не едут вообще.

`peerCanTakeSession` ещё пускает 1 файл на любое поколение. `peerSupportsDirectLink` режет всех ниже 4. В транспорте используется второе — старый телефон получает «обновитесь» даже на одну фотографию. `peerCanTakeSession` в проде не вызывается.

**Ожидаемый результат:** либо явно зафиксировать breaking change в ТЗ (B4 побеждает D6), либо оставить BLE-fallback для одного файла.

**Критерии приёмки:** решение владельца продукта записано в ТЗ; UI и протокол ему соответствуют.

**Для разработки:** `ble_control_protocol.dart:148–170`.

---

## DD-11. Нет прямого пути: экран разбора не показывается

**Приоритет:** High
**Требования:** G1

**Шаги:**
1. Интернет-передача между двумя NAT/VPN, где ICE не сходится.
2. Дождаться `ICE failed` / долгого `disconnected`.

**Фактический результат:** состояние `NoUsablePathFound` объявлено и UI на него подписан (`context.go('/send/fallback')`), но нигде не эмитится. ICE-провал даёт только `TransferStatus.failed` → `TransferFailed('Transfer failed unexpectedly')` → snackbar на английском. `NetworkFallbackPage` не открывается.

**Ожидаемый результат:** объяснить причину и предложить выход, не отправив ни байта.

**Критерии приёмки:**
- **Given** ICE не нашёл путь до первого байта, **When** сессия интернет, **Then** открыт `/send/fallback`, snackbar «failed unexpectedly» нет.

**Для разработки:** класс в `sender_bloc.dart:265–266`; обработчик `_onTransferFailed:1236–1254`; ICE в `webrtc_transfer_transport.dart:464–485`; слушатель в `file_picker_page.dart:233–238`. Эмитить `NoUsablePathFound()` вместо `SenderError`.

---

## DD-12. Отказ из‑за дорогого TURN затирается ошибкой

**Приоритет:** High
**Требования:** G4, L

**Шаги:**
1. Интернет-передача, ICE выбирает relay, сессия больше `maxRelayTransferBytes`.

**Фактический результат:** транспорт байты не шлёт и кладёт `RelayLimitExceeded` в `relayBlockedStream`. Сразу после этого — `_statusController.add(TransferStatus.failed)`.

В блоке оба события встают в очередь: `RelayBlocked` → `RelayTooExpensive` (уход на fallback), затем `TransferFailed` → `SenderError('Transfer failed unexpectedly')`. Последний побеждает.

**Ожидаемый результат:** показать fallback с лимитом, без «failed unexpectedly».

**Критерии приёмки:**
- **Given** выбран relay и сессия больше лимита, **When** канал открылся, **Then** ни байта не ушло и открыт экран разбора; `SenderError` нет.

**Для разработки:** `webrtc_transfer_transport.dart:221–231`; `sender_bloc.dart:438–443, 616–618`. Не слать `failed` после relay-cap.

---

## DD-13. iOS entitlement хотспота не попадает в подпись

**Приоритет:** High
**Требования:** B3, G1 (приёмник iOS должен уметь **войти** в сеть отправителя)

**Шаги:**
1. Android/десктоп поднимает local-only hotspot.
2. iPhone подключается через `NEHotspotConfiguration`.

**Фактический результат:** файл `ios/Runner/Runner.entitlements` есть (`com.apple.developer.networking.HotspotConfiguration = true`) и лежит в группе Xcode с синтетическим id `A1B2C3D4E5F60123456789BC`. `CODE_SIGN_ENTITLEMENTS` в iOS-проекте нет — только у macOS. Без этого `apply()` падает в рантайме.

**Ожидаемый результат:** iOS умеет join (хостить не обязан).

**Критерии приёмки:**
- **Given** подписанный iOS-билд, **When** `codesign -d --entitlements :-`, **Then** есть `HotspotConfiguration`.
- **Given** чужой хотспот сессии, **When** iPhone join, **Then** сеть поднимается без runtime-ошибки entitlement.

**Для разработки:** `ios/Runner/Runner.entitlements`; `ios/Runner.xcodeproj/project.pbxproj`. Прописать `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` для Debug/Release/Profile; включить capability на App ID.

---

## DD-14. Bluetooth-диалог на iOS обещает панель Wi-Fi

**Приоритет:** Medium
**Требования:** G2

**Фактический результат:** перед Bluetooth спрашивают включить Wi-Fi (для direct-link). Кнопка «Открыть настройки» на iOS ведёт в настройки **приложения** (`UIApplication.openSettingsURLString`), не в Wi-Fi. В `TransportPreconditions` это уже учтено отдельной копией; здесь — нет.

Комментарий в том же файле ещё говорит, что отказ «просто пойдёт по Bluetooth, как всегда». С поколения 4 это неправда: без Wi-Fi-линка передача не начинается.

**Критерии приёмки:**
- **Given** iOS, Wi-Fi выключен, выбран Bluetooth, **When** показан диалог, **Then** текст честно говорит про Настройки → Wi-Fi и не обещает системную панель.
- Отказ не стартует сессию, которая не сможет построить линк.

**Для разработки:** `wifi_speed_prompt.dart:49–57`; ключ `wifiPromptAccept`. Переиспользовать `precondWifiBodyApple` / `precondOpenAppSettings`.

---

## DD-15. Сбой BT API считается «радио включено»

**Приоритет:** Medium
**Требования:** FR-CONN / BUG-05

**Фактический результат:** если `UniversalBle.getBluetoothAvailabilityState()` бросает исключение, `ensure` возвращает `true` (fail open). Сессия и QR создаются при выключенном или неизвестном BT.

**Ожидаемый результат:** неизвестное состояние = радио не готово.

**Критерии приёмки:**
- **Given** проверка BT бросила исключение, **When** выбран Bluetooth, **Then** сессия не создана.

**Для разработки:** `transport_preconditions.dart:67–76`. Fail closed.

---

## DD-16. Fallback на iPhone/Mac обещает поднять сеть

**Приоритет:** Low
**Требования:** G2

**Фактический результат:** кнопка «создать сеть» на iOS/macOS скрыта (`canHost == false`). Текст плитки всё равно: «This phone can create that network itself if there is no router around.»

**Критерии приёмки:**
- **Given** `onCreateNetwork == null`, **When** открыт fallback, **Then** нет фразы, что это устройство само поднимет AP.

**Для разработки:** `network_fallback_page.dart:96–100`; ключ `fallbackWifiBody`.

---

## DD-17. Ошибки и журнал передач не локализованы

**Приоритет:** Medium
**Требования:** I1

**Фактический результат:** ключи `app_en.arb` / `app_ru.arb` совпадают, но runtime-ошибки и строки last transfers зашиты по-английски (`Transfer failed unexpectedly`, `Failed to start Bluetooth sharing`, `'${report.role} … in ${took}s'`). При RU-интерфейсе snackbar и настройки остаются EN.

**Критерии приёмки:**
- **Given** язык приложения RU, **When** сбой передачи или открыт журнал, **Then** пользовательские строки на русском.

**Для разработки:** `sender_bloc.dart`; `receiver_bloc.dart`; `settings_page.dart:443–456`; `transfer_report.dart`. Хранить enum маршрута, не английскую фразу.

---

## DD-18. Скан QR начинает приём без подтверждения

**Приоритет:** High
**Требования:** E4

**Шаги:**
1. Получатель: «Принять» → камера.
2. Отсканировать QR отправителя.

**Фактический результат:** превью держится 1,2 с, затем само шлёт `StartDownload`. Кнопки «Принять» нет. Список устройств и ввод кода ждут согласия. Bluetooth после скана сам пишет `START` первому найденному устройству.

**Ожидаемый результат:** имя в списке / факт скана сами по себе передачу не начинают.

**Критерии приёмки:**
- **Given** отсканирован QR, **When** пользователь не нажал «Принять», **Then** загрузка не началась.
- **Given** BLE-скан нашёл отправителя, **When** пользователь никого не выбрал, **Then** `START` не отправлен.

**Для разработки:** `transfer_preview_page.dart:24–64`; `bluetooth_receive_page.dart:94–102`. Образец подтверждения — `_buildConfirm` в `code_receive_page.dart`.

---

## DD-19. `/info` без токена отдаёт имя и размер

**Приоритет:** Medium
**Требования:** F1

**Фактический результат:** middleware специально пропускает `/info` и `/v2/health`. Любой в LAN, кто угадал порт 8000–9000, читает `{name, size, mime}` без QR. Неверный токен даёт 403, не 401. Токен QHTP не одноразовый: `POST /v2/session/complete` его не сбрасывает.

**Ожидаемый результат:** bearer на всё, кроме явного health; иначе 401.

**Критерии приёмки:**
- **Given** нет `Authorization`, **When** `GET /info`, **Then** 401 и в теле нет имени файла.
- **Given** сессия завершена, **When** повторный запрос со старым токеном, **Then** 401.

**Для разработки:** `local_http_server.dart:231–236, 565–571, 503–510`.

---

## DD-20. Android/Linux отвечают успехом на голый `START`

**Приоритет:** Medium
**Требования:** F3

**Фактический результат:** сессию Dart рвёт (`staleReceiverMessage`). GATT-write всё равно `PeripheralWriteRequestResult()` — успех. iOS/macOS отвечают `insufficientAuthentication`. Старый клиент думает, что передача началась.

**Критерии приёмки:**
- **Given** Android или Linux отправитель, **When** приёмник пишет `START` без токена, **Then** ATT error, не success.

**Для разработки:** `bluetooth_transfer_transport.dart:186–194`; `linux_bluetooth_sender.dart:105–108`.

---

## DD-21. Приёмник не режет манифест и глубину пути

**Приоритет:** Medium
**Требования:** F10

**Фактический результат:** escape за корень закрыт (`isWithin`). Лимиты 32 уровня / 512 символов пути / 32 МБ манифеста проверяет только sender indexer. Враждебный отправитель может отдать огромный JSON или дерево на тысячи уровней — оно останется внутри папки приёма и съест память/диск.

Walkthrough обещает отказ, если `Content-Length` манифеста > 32 МБ. В клиенте этой проверки нет (`qhtpManifestMaxBytes` в `lib/features/receiver` не используется).

**Критерии приёмки:**
- **Given** манифест > 32 МБ, **When** приём, **Then** отказ до полного parse.
- **Given** путь глубже 32 или длиннее 512, **Then** элемент отклонён.

**Для разработки:** `qhtp_receiver_client.dart` (fetch `/v2/manifest`); константы в `app_constants.dart:188–198`; indexer уже проверяет в `file_indexer.dart:313–377`.

---

## DD-22. Ссылки `directdrop://join?room=` мертвые

**Приоритет:** Low
**Требования:** E5

**Фактический результат:** живой формат — `directdrop://join?p=…`. `?room=` игнорируется. Комментарий в `app_constants.dart` и ветка сканера для `mode == internet` всё ещё строят/ждут room-URL.

**Критерии приёмки:**
- Документация и роутер описывают только `p=`.
- Старый `?room=` либо явно отвергается с понятным текстом, либо больше нигде не собирается.

**Для разработки:** `app_constants.dart:152–153`; `app_router.dart:222–225`; `qr_scan_page.dart:272–275`; `code_receive_page.dart:40`.

---

## DD-23. Apple BLE всё ещё качает файл на gen 4

**Приоритет:** High
**Требования:** B4, D2
**Платформы:** iOS, macOS

**Фактический результат:** Dart и `beginSenderTransferIfReady()` для поколения ≥ 4 только шлют `receiverReady`. Но при старте рекламы всё ещё открывается файл (`openCurrentSenderItem`), а `peripheralManagerIsReady` всегда зовёт `pumpSenderQueue()`, который пишет метаданные и чанки в data characteristic.

`sendLinkFrame` (кадры `link`/`serve`) идёт через тот же `updateValue`. Если очередь GATT полна (`BUSY`), `isReady` сбрасывает в канал байты файла. Приёмник умеет писать BLE-данные в `.qs.partial` и переименовывать без QHTP-проверки — параллельно с Wi-Fi pull.

Android/Linux по BLE файлы уже не шлют.

**Критерии приёмки:**
- **Given** iOS/macOS отправитель gen 4, **When** идёт рандеву, **Then** в data characteristic нет чанков файла.
- **Given** `updateValue` вернул false на link-кадре, **When** пришёл `isReady`, **Then** качается только служебный кадр, не файл.

**Для разработки:** `ios/Runner/QuickShareBluetooth.swift:417–419, 535–574, 772–774`; то же в `macos/Runner/QuickShareBluetooth.swift`. Не открывать файл на advertise. `pumpSenderQueue` не вызывать на gen ≥ 4.

---

## DD-24. WebRTC шлёт прогресс на каждый чанк

**Приоритет:** High (тот же класс, что зависание UI / BUG-01)
**Требования:** J5

**Фактический результат:** QHTP ограничен 100 мс. WebRTC: каждый чанк 64 КБ → `_emit('transferring')` / `_progressController.add`. На ~20 МБ/с это сотни перестроек BLoC в секунду на том же изоляте, что пишет файл. Скорость троттлится 0,5 с, прогресс — нет.

**Критерии приёмки:**
- **Given** интернет-передача, **When** идут чанки, **Then** UI-события прогресса не чаще 10 Гц; 100% и completed приходят сразу, без очереди.

**Для разработки:** `webrtc_transfer_transport.dart:360–362`; `webrtc_receiver_transport.dart:392–399`. Образец — `_progressInterval` в `qhtp_receiver_client.dart:86–93`.

---

## DD-25. QR ждёт полный обход дерева

**Приоритет:** Medium
**Требования:** BUG-10 из `2026-08-29-transfer-bugfixes.md`

**Фактический результат:** SHA-256 до QR убран (`includeChecksums: false`). Обход папки и `stat` каждого файла по-прежнему до `QRReady` / `BluetoothAdvertising`. На десятках тысяч файлов QR появляется с задержкой, пропорциональной числу inode, не объёму.

**Критерии приёмки:**
- **Given** папка на ~1 ТБ / десятки тысяч файлов, **When** пользователь нажал отправить, **Then** QR виден за ≤ 2 с (спек BUG-10); индекс догоняет в фоне; первый байт — когда манифест готов.

**Для разработки:** `sender_bloc.dart:798–825`; `sender_repository_impl.dart:170–198`.

---

## DD-26. WebRTC/BLE публикуют файл без сверки размера

**Приоритет:** Medium
**Требования:** D2

**Фактический результат:** `file-end` всегда делает `commit()` (fsync + rename `.qs.partial` → настоящее имя). Пофайловой сверки с `item.size` нет, только сумма сессии в конце. Обрезанный файл из середины списка уже лежит под настоящим именем. BLE `_sealCurrentFile` — то же. QHTP сверяет размер (и SHA-256, если есть) до rename.

**Критерии приёмки:**
- **Given** WebRTC-элемент короче, чем в манифесте, **When** пришёл `file-end`, **Then** настоящее имя не появляется; partial удалён или сессия падает с понятной ошибкой.

**Для разработки:** `webrtc_receiver_transport.dart:451–452, 661–668`.

---

## Что из спека 2026-08-29 в текущем коде выглядит закрытым

Не часть этого списка работ. Чтобы не дублировать закрытое.

| Старый ID | Было | Сейчас |
|---|---|---|
| BUG-01 | iOS зависает на 98–100% | Drain complete-кадра, завершение по числу байт, `IsolatedQhtpReceiver`, ретраи `POST /v2/session/complete`. На устройстве не гонялось. Остаточный риск — DD-24. |
| BUG-03 | Строка Wi-Fi-адреса | В UI нет. |
| BUG-04 | QR при выключенном Wi-Fi | Закрыто для клика по способу передачи; drop — это DD-04. |
| BUG-05 | BT-сессия после отказа | `TransportPreconditions` возвращает `false`. Дыра — DD-15. |
| BUG-06 | Нет Room Link на iOS | Заменено десятизначным кодом (E2) на LAN/BT; ссылка осталась для интернета. Не дефект, пока продукт не вернёт ссылку. |
| BUG-08 | Нет таймера сессии | Таймер 5 мин на QR и BT. На экране хотспота (`local_network_page`) TTL UI нет — отдельный низкий хвост, в DD не выносился. |
| BUG-09 | Cancel не нажимается | Кнопка есть на `bluetooth_send_page`. |
| BUG-10 | QR ждёт хеш всего объёма | Хеш убран; обход дерева остался — DD-25. |

---

## Требования, которые в коде выглядят выполненными

A1, A2, A3 (байты файла не идут через Worker), B1–B3, B5, C1–C3, C5, C4 на QHTP (100 ГБ / 500 ГБ / 100k), D1, D2 на QHTP, D3–D5 на QHTP, E1–E3, E6, F1 на защищённых роутах, F2 (LAN TLS pin), F3 на Apple, F4–F6, F8 (UPnP удалён), F10 от escape за корень, G3, G5, H1–H2, I2–I3, J2–J4, K2, K3.

---

## Документы, которые расходятся с кодом

Это не дефекты продукта, пока ТЗ/README не обновлены.

| Источник | Утверждение | Код |
|---|---|---|
| README / G4 в `requirements.html` | Relay ≤ 50 МБ | `maxRelayTransferBytes` = 2 ГБ |
| README | LAN = plaintext HTTP | TLS + pin (`SessionTlsIdentity`) |
| README | BLE возит мелкие файлы | Gen 4 — только рандеву |
| `ice_servers.dart` комментарий | J3 «ещё не подключено» | `TurnCredentialRefresher` вызывается |
| `app_constants.dart:153` | `directdrop://join?room=A1B2C3` | Рабочая ссылка — `?p=` |
| Walkthrough | LAN открытый HTTP; отказ манифеста > 32 МБ | TLS есть; проверки 32 МБ на приёме нет (DD-21) |
| J1 в `requirements.html` | `UIBackgroundModes: voip` | Убран (DD-09) |
