# DirectDrop — что менялось, построчно

Все диффы ниже сняты из репозитория (`git diff`), а не восстановлены по памяти.
Состояние на момент отчёта: **188 тестов зелёные, `flutter analyze` — 0
замечаний**, релиз собирается.

---

## Часть I. Команды и их реальный вывод

### Проверка после каждого изменения

```bash
flutter analyze
# No issues found! (ran in 4.6s)

flutter test
# 00:10 +188: All tests passed!

flutter build apk --release --split-per-abi
# ✓ app-armeabi-v7a-release.apk (31.7MB)
# ✓ app-arm64-v8a-release.apk   (40.5MB)
# ✓ app-x86_64-release.apk      (44.5MB)
```

### Инвентаризация мёртвого кода

```bash
for sym in HttpTransferTransport generateServerlessQRPayload "webrtc/answer" \
           _getAvailableDiskSpace receiveWithSdpOffer; do
  echo "=== $sym ==="; grep -rn "$sym" lib/ test/;
done
```

Показала, что `HttpTransferTransport` объявлен и **ни разу не инстанцирован**, а
`generateServerlessQRPayload` вызывается только из тестов.

### Какие константы протокола реально применяются

```bash
for c in qhtpManifestMaxBytes qhtpMaxFileBytes qhtpMaxRelPathChars qhtpMaxPathDepth; do
  grep -rn "$c" lib/ | grep -v app_constants
done
```

Вывод — `qhtpManifestMaxBytes` использований **ноль**. Константа была, проверки
не было.

### Сверка трёх копий walkthrough

```bash
for f in walkthrough.md quickshare/walkthrough.md quickshare/docs/walkthrough.md; do
  git log --oneline -1 -- "$f"
done
# все три: 80cabbb Initial commit
```

Все из одного коммита, значит ни одна не новее — редакционные варианты.

### Замеры, на которых основаны решения

```bash
# Тип NAT при включённом VPN
python3 natfilter.py
#   ВЕРДИКТ: Address-and-Port-Dependent Filtering (port-restricted cone)

# Живой ли дефолтный TURN
dig +short @1.1.1.1 openrelay.metered.ca      # пусто — NXDOMAIN
dig +short @1.1.1.1 metered.ca                # 216.39.254.157 — домен жив
dig +short @1.1.1.1 standard.relay.metered.ca # 37.27.44.221

# Из чего состоит APK
python3 -c "import zipfile,collections; ..."
#   нативные .so × 3 ABI  94.4 MB (94%)
#   dex                    2.5 MB  (2%)
#   ресурсы                0.5 MB
```

### Проверка, что release-APK действительно не подписан

```bash
unzip -l app-release.apk | grep -iE "\.(RSA|DSA|EC|SF)$"   # пусто
python3 -c "print(open('app-release.apk','rb').read().rfind(b'APK Sig Block 42'))"  # -1
```

Оба признака подписи отсутствуют — тихая debug-подпись исключена.

---

## Часть II. Изменения кода: было → стало

### 1. `lib/features/receiver/data/store/session_state_store.dart`

#### 1.1. Инъекция каталога

**Было** — жёсткая привязка к платформенному каналу, из-за чего единственный
код, удаляющий файлы, не покрывался headless-тестами:

```dart
class SessionStateStore {
  Future<String> _getStoreDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'qhtp_sessions'));
```

**Стало:**

```dart
class SessionStateStore {
  /// Where session records live. Injected so the one part of this app that
  /// deletes files can be tested against a scratch directory instead of the
  /// user's own.
  ///
  /// Optional rather than required: production has exactly one answer for it,
  /// and making it required would force every construction site to become
  /// async for no gain.
  final String? _storeDirectoryOverride;

  SessionStateStore({String? storeDirectory})
      : _storeDirectoryOverride = storeDirectory;

  Future<String> _getStoreDir() async {
    final root = _storeDirectoryOverride ??
        (await getApplicationSupportDirectory()).path;
    final dir = Directory(p.join(root, 'qhtp_sessions'));
```

#### 1.2. Уборка: было удаление записи, стало каскадное удаление

**Было** — удалялся только JSON. Партиалы оставались в песочнице, а вместе с
записью терялась единственная ссылка на них:

```dart
/// Clean up states older than 24 hours (RESUME_STATE_TTL_MS)
Future<void> cleanExpiredStates() async {
  try {
    final dirPath = await _getStoreDir();
    final dir = Directory(dirPath);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = 24 * 60 * 60 * 1000; // 24 hours

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final stat = await entity.stat();
        if (now - stat.modified.millisecondsSinceEpoch > ttl) {
          await entity.delete();          // ← и всё
        }
      }
    }
```

**Стало** — читаем запись, удаляем её партиалы, и только потом саму запись:

```dart
Future<int> cleanExpiredStates({
  Duration ttl = const Duration(hours: 24),
}) async {
  var reclaimed = 0;
  try {
    final dir = Directory(await _getStoreDir());
    if (!await dir.exists()) return 0;
    final cutoff = DateTime.now().subtract(ttl);

    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final stat = await entity.stat();
      if (stat.modified.isAfter(cutoff)) continue;

      reclaimed += await _deletePartialsOf(entity);   // ← сначала файлы
      await entity.delete();                          // ← потом запись
    }
  } catch (e) {
    debugPrint('Session cleanup failed: $e');
  }
  return reclaimed;
}
```

Плюс новый `_deletePartialsOf` с защитой — метод удаляет по путям из JSON,
прочитанного с диска, поэтому границу надо проверять:

```dart
// Guard against a state file that points outside the directory it claims:
// this deletes files, so a malformed record must not be able to aim it
// somewhere else.
if (!p.isWithin(baseDir, partial.path)) {
  debugPrint('Refusing to delete ${partial.path}: outside $baseDir');
  continue;
}
reclaimed += await partial.length();
await partial.delete();
```

Завершённые элементы пропускаются — это файлы, которые пользователь уже
получил.

---

### 2. `lib/main.dart` — запуск уборки

**Было:**

```dart
runApp(const QuickShareApp());
```

**Стало:**

```dart
// Sweep abandoned transfers and the partial files they left behind.
// Deliberately not awaited: it walks the filesystem, and the first frame
// should not wait on disk.
unawaited(SessionStateStore().cleanExpiredStates());

runApp(const DirectDropApp());
```

---

### 3. `lib/features/receiver/data/client/qhtp_receiver_client.dart`

Четыре независимых исправления в одном файле.

#### 3.1. Проверка **до** переименования, а не после

**Было** — файл переименовывался, потом считался хеш, который ни с чем не
сравнивался:

```dart
// 5. Verify & Atomic Rename
final finalFile = File(finalPath);
if (await finalFile.exists()) await finalFile.delete();
await partialFile.rename(finalPath);              // ← публикуем

final hashDigest = await sha256.bind(File(finalPath).openRead()).first;
final checksumStr = 'sha256:$hashDigest';          // ← и просто записываем
```

**Стало:**

```dart
// 5. Verify, then rename. In that order: the old code renamed first and
// hashed afterwards without comparing to anything, so a truncated or
// corrupted file was published as complete.
final checksumStr = await _verifyPartial(partial: partialFile, item: item);

final finalFile = File(finalPath);
if (await finalFile.exists()) await finalFile.delete();
await partialFile.rename(finalPath);
```

Новый метод сверяет размер всегда, чексумму — если она есть, и **удаляет
партиал при несовпадении**, чтобы ретрай начался с нуля, а не дописывал к
заведомо испорченному:

```dart
Future<String?> _verifyPartial({required File partial, required QhtpItem item}) async {
  final writtenBytes = await partial.length();
  if (item.size > 0 && writtenBytes != item.size) {
    await partial.delete();
    throw Exception('size mismatch for ${item.path}: received $writtenBytes '
        'bytes, manifest declares ${item.size}');
  }

  final expected = item.sha256;
  final digest = await sha256.bind(partial.openRead()).first;
  final actual = 'sha256:$digest';

  if (expected != null && expected.isNotEmpty && actual != expected) {
    await partial.delete();
    throw Exception('checksum mismatch for ${item.path}');
  }
  return actual;
}
```

#### 3.2. Утечка `fileSink`

**Было** — sink закрывался только на одном пути ошибки, на остальных оставался
открытым:

```dart
final fileSink = partialFile.openWrite(...);
...
if (response.statusCode != 200 && response.statusCode != 206) {
  await fileSink.close();   // ← только здесь
  throw Exception('Server returned status ${response.statusCode}');
}
...
} catch (e) {
  itemError = e.toString();
  if (attempt < AppConstants.maxRetryAttempts) {
    await Future.delayed(Duration(seconds: attempt));
  }
}                            // ← sink остался открытым
```

**Стало** — объявление вынесено выше `try`, закрытие в `finally`:

```dart
IOSink? fileSink;
try {
  ...
  fileSink = partialFile.openWrite(...);
  ...
} catch (e) {
  ...
} finally {
  // The sink used to be left open on every failed attempt, leaking a handle
  // per retry and — worse — letting buffered bytes land in the file after the
  // next attempt had already measured its length.
  if (fileSink != null) {
    try { await fileSink.flush(); } catch (_) {}
    try { await fileSink.close(); } catch (_) {}
  }
}
```

#### 3.3. Ответ `200` на Range-запрос

**Было** — принимался наравне с `206`, то есть полное тело дописывалось в
append к уже скачанному куску:

```dart
if (response.statusCode != 200 && response.statusCode != 206) {
  throw Exception('Server returned status ${response.statusCode}');
}
```

**Стало:**

```dart
if (existingBytes > 0 && response.statusCode == 200) {
  // 200 means the server ignored the Range header and is sending from byte
  // zero. Appending that to a partial file silently corrupts it, which is
  // how resumed downloads used to break.
  throw Exception('Server ignored the Range request (200 instead of 206)');
}
if (response.statusCode != 200 && response.statusCode != 206) {
  throw Exception('Server returned status ${response.statusCode}');
}
```

#### 3.4. Переросший партиал

**Было** — правилась переменная, а не файл, и файл длиннее ожидаемого
переименовывался как готовый:

```dart
if (existingBytes >= item.size && item.size > 0) {
  existingBytes = item.size;      // ← клэмп счётчика
}
```

**Стало:**

```dart
if (item.size > 0 && existingBytes > item.size) {
  // A previous attempt wrote past the declared end — a 200 answered to a
  // Range request appends a whole second copy. Clamping the counter used to
  // hide that and rename an oversized file as complete; start over instead.
  await partialFile.delete();
  existingBytes = 0;
}
```

#### 3.5. Длинные имена файлов

**Было** — санитайзер чистил запрещённые символы и на этом останавливался:

```dart
String sanitizeSegment(String segment) {
  var clean = segment.replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_').trim();
  if (clean.isEmpty || clean.replaceAll('.', '').isEmpty) clean = 'item';
  return clean;
}
```

Имя в 400 символов доходило до `File.create()` и падало с `ENAMETOOLONG`.

**Стало** — добавлено усечение **по байтам** с сохранением расширения:

```dart
return _fitToNameLimit(clean);
```

```dart
String _fitToNameLimit(String name) {
  const limit = AppConstants.qhtpMaxNameBytes;
  if (utf8.encode(name).length <= limit) return name;

  final extension = p.extension(name);
  // An "extension" longer than the budget is not an extension, it is a name
  // with a dot in it.
  final keptExtension =
      utf8.encode(extension).length <= limit ~/ 4 ? extension : '';
  final stem = name.substring(0, name.length - extension.length);
  final stemBudget = limit - utf8.encode(keptExtension).length;

  final buffer = StringBuffer();
  var used = 0;
  for (final rune in stem.runes) {          // ← по рунам, не по байтам
    final encoded = utf8.encode(String.fromCharCode(rune)).length;
    if (used + encoded > stemBudget) break;
    buffer.writeCharCode(rune);
    used += encoded;
  }
  final shortened = '$buffer$keptExtension';
  return shortened.isEmpty ? 'item' : shortened;
}
```

Три решения внутри, каждое с последствием:

- **байты, а не символы** — 200 кириллических символов это 400 байт; имя,
  «короткое» по спеке, упало бы на `create()`;
- **обход по рунам** — побайтовый рез посреди двухбайтовой последовательности
  дал бы `U+FFFD`;
- **расширение сохраняется** — от него зависит, откроется ли файл вообще.

#### 3.6. Размер манифеста и пофайловый лимит

**Было** — манифест парсился в память без всякой границы:

```dart
final manifestMap = manifestRes.data is String
    ? jsonDecode(manifestRes.data as String)
    : manifestRes.data;
final manifest = QhtpManifest.fromJson(manifestMap as Map<String, dynamic>);
```

**Стало:**

```dart
// The manifest is JSON parsed into memory, so its size has to be bounded
// before parsing rather than after. A sender that is broken — or not the
// sender we think it is — should not be able to make the receiver allocate
// without limit.
final declaredLength =
    int.tryParse(manifestRes.headers.value('content-length') ?? '');
if (declaredLength != null &&
    declaredLength > AppConstants.qhtpManifestMaxBytes) {
  return Left(FileFailure('Manifest is $declaredLength bytes, over the '
      '${AppConstants.qhtpManifestMaxBytes} byte limit'));
}

final manifest = QhtpManifest.fromJson(manifestMap as Map<String, dynamic>);

final oversized = manifest.items
    .where((i) => i.size > AppConstants.qhtpMaxFileBytes)
    .toList();
if (oversized.isNotEmpty) {
  return Left(FileFailure('${oversized.first.path} is larger than the '
      '100 GB per-file limit'));
}
```

---

### 4. `lib/core/constants/app_constants.dart`

Добавлено:

```dart
/// Longest single path segment, in **bytes** rather than characters.
///
/// Filesystems count bytes: ext4, APFS and NTFS all cap a name at 255, and a
/// Cyrillic or emoji name reaches that in half as many characters. Measuring
/// in characters would let a legal-looking name fail at create() with
/// ENAMETOOLONG, which the receiver would report as a failed transfer.
static const int qhtpMaxNameBytes = 255;

/// Above this total session size the indexer stops computing per-item
/// SHA-256 digests.
///
/// Hashing costs a full read of every byte before the QR code can appear.
/// At a few hundred MB/s that is seconds for a couple of gigabytes and the
/// better part of an hour for a 500 GB session, which would look like a hang.
static const int qhtpChecksumMaxSessionBytes = 2 * 1024 * 1024 * 1024;
```

---

### 5. `lib/core/network/hotspot_lifecycle_guard.dart` — новый файл, 81 строка

Ключевая часть — почему `paused` и `detached` обрабатываются по-разному:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  switch (state) {
    case AppLifecycleState.resumed:
      _graceTimer?.cancel();
      _graceTimer = null;

    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
      _graceTimer?.cancel();
      _graceTimer = Timer(grace, () {          // grace = 2 минуты
        AppLogger.info('Backgrounded for ${grace.inMinutes} min — dropping '
            'the hotspot so the Wi-Fi radio does not stay in AP mode',
            tag: 'HOTSPOT');
        unawaited(_hotspot.stopHosting());
      });

    case AppLifecycleState.detached:
      _graceTimer?.cancel();
      unawaited(_hotspot.stopHosting());        // процесс уходит — сразу

    case AppLifecycleState.inactive:
      // A transient state — a notification shade, an incoming call, the app
      // switcher. Acting on it would tear the network down every time the
      // user glances at a banner.
      break;
  }
}
```

### 6. `lib/app.dart` — подключение

```diff
 class _DirectDropAppState extends State<DirectDropApp> {
   final _deepLinks = DeepLinkService();
+  // App-level rather than page-level: the hotspot outlives the screen that
+  // raised it — the transfer moves on to the progress route while the network
+  // stays up.
+  final _hotspotGuard = HotspotLifecycleGuard();
   StreamSubscription<InternetInvite>? _sub;

   void initState() {
     _deepLinks.init();
+    _hotspotGuard.attach();
   }

   void dispose() {
     _sub?.cancel();
+    _hotspotGuard.detach();
     _deepLinks.dispose();
   }
```

---

## Часть III. Тесты

### `test/features/receiver/session_cleanup_test.dart` — 12 тестов

Покрывает единственный код, удаляющий пользовательские файлы. Работает на
настоящей `Directory.systemTemp`, а не in-memory: баги, которые тут возможны, —
это баги путей, а in-memory FS их как раз пропускает.

| Тест | Что доказывает |
|---|---|
| removes the partials an abandoned session left behind | Возвращённые байты сходятся, запись удаляется последней |
| leaves finished files alone | Худший исход метода — удалить полученное пользователем |
| a session still inside its TTL is untouched | Пауза 5 минут ещё возобновляема |
| refuses a path that escapes the recorded base directory | `../precious.jpg` → `p.isWithin` после нормализации отбраковывает |
| refuses an absolute finalPath pointing somewhere else | `finalPath` — из той же недоверенной записи |
| a corrupt record is dropped without taking anything with it | Битый JSON не уносит соседей |
| a record with no baseDir deletes nothing | Нет границы — нет удаления |
| survives a store directory that does not exist yet | Не падает |
| ignores files that are not session records | `.txt` не трогается |
| a custom TTL is honoured | Граница в обе стороны |
| saves and reloads through the injected directory | Round-trip |
| writes inside the injected directory | Изоляция теста доказана |

Оба негативных сценария **сработали не вхолостую** — guard реально отбраковал
пути, а не «прошёл, потому что файла не было».

### `test/features/receiver/qhtp_limits_test.dart` — 8 тестов

| Тест | Что доказывает |
|---|---|
| an ordinary name is untouched | Обычное имя не портится |
| an over-long name is shortened | ≤ 255 байт, расширение на месте |
| counts bytes, not characters | 200 кириллических символов = 400 байт |
| never cuts a character in half | Нет `U+FFFD` |
| a name that is one long "extension" | `.` + 400 символов — не расширение |
| an over-long name still produces a usable path | **Файл реально создаётся на диске** |
| shortening does not defeat the traversal guard | Усечение не открывает обход |
| the numbers are the ones the spec states | Спека и код сверены числами |

### `test/features/receiver/qhtp_integrity_test.dart` — 4 теста

Гоняет настоящий клиент против настоящего сервера по loopback, с Dio-интерцептором
вместо сетевых сбоев. Главный:

```dart
test('a corrupted body is rejected instead of being renamed into place', () {
  // Flip one byte in flight: the length still matches, so only the checksum
  // can catch this. Before the fix the file was renamed and marked complete.
```

### `test/core/network/local_hotspot_service_test.dart` — 11 тестов

Включая экранирование `; : \ "` в `WIFI:`-payload — сгенерированный пароль с
точкой с запятой обрезал бы payload и отдал камере битую сеть.

---

## Часть IV. Документация

### `docs/HEAVY_TRANSFER_PROTOCOL.md`

Колонка «Enforce where» была декларативной, стала указывать на конкретные
методы:

```diff
-| `MAX_FILE_BYTES` | 100 × 1024³ | Sender index, Receiver before write |
+| `MAX_FILE_BYTES` | 100 × 1024³ | `FileIndexer._checkFileLimits`; receiver rejects the session after reading the manifest |

-| `MAX_NAME_CHARS` | 255 | Single path segment |
+| `MAX_NAME_BYTES` | 255 | `QhtpReceiverClient.sanitizeSegment`. **Bytes, not characters** … |

-| `MANIFEST_MAX_BYTES` | 32 MB | Reject oversized manifest JSON |
+| `MANIFEST_MAX_BYTES` | 32 MB | Receiver checks `Content-Length` **before** parsing |

-| **Receiver** | … writes paths, verifies hashes |
+| **Receiver** | … **verifies size always and SHA-256 when the manifest carries one, before renaming** |
```

Три расхождения закрыты **кодом**, а не вычёркиванием из спеки. Это записано в
приложении к документу.

### `docs/walkthrough.md`

Три копии → одна. Все из одного коммита, ни одна не новее. Новая версия
описывает нынешний флоу: QHTP, serverless через Nostr, хотспот, и таблицу «что
видит посредник» — включая честное «кто угодно в локальной сети видит всё,
потому что QHTP это открытый HTTP».

---

## Часть V. Что осталось непроверенным

Ни один из этих пунктов не закрывается кодом или тестом на этой машине:

- **Нативный слой.** Kotlin компилируется в составе релиза — это проверка
  синтаксиса, не поведения. Swift не собирался вообще.
- `startLocalOnlyHotspot`, `NEHotspotConfiguration`, entitlement
  `HotspotConfiguration` — не исполнялись.
- Эвристика имени интерфейса `ap*`/`swlan*`/`wlan1`.
- Отсутствие R8-регрессий.
- Валидность TURN-креденшелов.
- Занятость `DirectDrop` и `com.directdrop.app`.
- `HotspotLifecycleGuard` — не покрыт тестом.

---

# Заход 2 — тест на lifecycle guard и сверка спеки

Состояние после: **199 тестов зелёные, `flutter analyze` — 0**.

---

## Команды и реальный вывод

### Мутационная проверка: а ловит ли тест то, ради чего написан

Не «тесты зелёные», а «тест краснеет, когда ломаешь именно то, что он
сторожит». Внёс классическую утечку — убрал отмену предыдущего таймера:

```bash
cp lib/core/network/hotspot_lifecycle_guard.dart /tmp/guard.bak
# убрать `_graceTimer?.cancel();` из ветки paused
flutter test test/core/network/hotspot_lifecycle_guard_test.dart
```

```
Expected: <1>
  Actual: <10>
ten pauses must not mean ten teardowns
00:00 +10 -1: Some tests failed.
```

```bash
cp /tmp/guard.bak lib/core/network/hotspot_lifecycle_guard.dart
flutter test test/core/network/hotspot_lifecycle_guard_test.dart
# 00:00 +11: All tests passed!
```

Десять `paused` дали десять гашений — тест поймал. Мутация откачена.

### Сверка спеки с кодом

```bash
# что реально уходит в QR
grep -nE "'(v|ip|p|t|sid|mode|fn|fs|cs|ic|sdp)'" lib/shared/models/qr_payload.dart
#   'fn': fileName   ← спека утверждала, что этого в QR нет
#   'fs': fileSize
#   'ic': itemCount

# как кодируется
sed -n '/String encode()/,/^  }/p' lib/shared/models/qr_payload.dart
#   base64Url.encode(zlib.encode(bytes))   ← спека говорила просто base64url

# что отдаёт манифест
sed -n '/Map<String, dynamic> toJson/,/^  }/p' \
  lib/features/sender/domain/entities/qhtp_manifest.dart
#   'mtime', 'sha256' — в спеке не описаны
```

### Проверка хвоста ребрендинга

```bash
flutter build apk --release 2>&1 | grep -oE "(DirectDrop|QuickShare): no release signing.*"
# DirectDrop: no release signing configured, building an UNSIGNED release…
```

---

## Код: было → стало

### 1. `pubspec.yaml` — явная зависимость вместо транзитивной

`fake_async` приходил транзитивно из `flutter_test`. Импортировать чужое дерево
напрямую — способ однажды сломаться на его апдейте.

```diff
   bloc_test: ^9.1.7
+  # Deterministic time for the hotspot lifecycle tests: "two minutes later"
+  # has to be exact, and a real delay would make the suite slow and flaky.
+  fake_async: ^1.3.1
```

### 2. `android/app/build.gradle` — хвост ребрендинга

```diff
-  println("QuickShare: no release signing configured, building " +
+  println("DirectDrop: no release signing configured, building " +
```

---

## Спека: четыре расхождения с кодом

### 2.1. Кодирование QR — единственное, что ломало совместимость

**Было в спеке:**

```
### 4.1 Encoding
Same as today: UTF-8 JSON → base64url (no padding required).
```

**Делает код:**

```dart
String encode() {
  final bytes = utf8.encode(jsonEncode(toJson()));
  return base64Url.encode(zlib.encode(bytes)).replaceAll('=', '');
}
```

**Стало в спеке:**

```
UTF-8 JSON → zlib → base64url, padding stripped.

    base64Url(zlib(utf8(json))).replaceAll('=', '')

> The zlib pass is not decoration. An earlier version base64-encoded the JSON
> directly, and because the SDP inside was *already* base64 of compressed
> bytes, the result grew ~33% and approached the 2953-byte ceiling of QR byte
> mode v40 EC=L. A decoder written against the previous wording would read
> compressed bytes as text and fail — this is the one place in the spec where
> the mismatch broke interoperability rather than expectations.
```

### 2.2. «Not in QR: file names, sizes»

**Было:** `**Not in QR:** file names, sizes, checksums, item list.`

**Делает код:** кладёт `fn`, `fs`, `ic`, и намеренно.

**Стало** — три строки добавлены в таблицу полей, плюс:

```
> `fn`, `fs` and `ic` were added deliberately and this section used to deny
> their existence. Without them the receiver had to call /v2/session before it
> could draw anything, which froze the scanner for up to ~20 seconds on some
> networks and read to the user as "scanning does nothing".

**Still not in QR:** per-item checksums and the item list.
```

### 2.3. «receiver must validate RFC1918»

Не валидирует и не может: serverless кладёт в это поле литерал `"p2p"`, хотспот
— подсеть, которую выбрал вендор. Спека теперь описывает, что `validatePrivateIp`
делает на самом деле: отбрасывает нераспарсиваемое, link-local и multicast,
остальное принимает.

Заодно `sid`: спека говорила «hex 16–32 chars», код кладёт UUID v4 (36 символов
с дефисами). Поле никем не парсится — исправлена спека.

### 2.4. Заявленное, но не реализованное

Два места, где спека обещала поведение, которого нет. Помечены прямо в
таблицах, а не вычеркнуты:

```diff
-| Session expired/closed | 410 | {"error":"gone","code":"SESSION_GONE"} |
+| Session expired/closed | 410 | … — **not implemented**: an expired session
+  stops the server, so the request fails to connect rather than answering 410.
+  The 410 that does exist is ITEM_GONE |
```

```diff
 **413** if JSON would exceed MANIFEST_MAX_BYTES and NDJSON not used.
+
+> **Not implemented.** /v2/session honestly advertises
+> supportsNdjsonManifest: false, and the server always serves full JSON. The
+> receiver enforces the ceiling from its side instead.
```

### 2.5. Манифест: два недокументированных поля

```
Items carry two fields not shown above:

- `mtime` — modification time in milliseconds, always present.
- `sha256` — `sha256:<hex>`, **optional**. Filled in for sessions up to 2 GB
  and skipped above that; hashing is a full read of every byte before the QR
  can appear, and 500 GB of it would look like a hang.
```

---

## Тест: `test/core/network/hotspot_lifecycle_guard_test.dart` — 11 тестов

Ключевое решение — фейк переопределяет `canHost`:

```dart
class _CountingHotspot extends LocalHotspotService {
  int stopCalls = 0;
  @override
  bool get canHost => true;          // ← без этого всё проходит вхолостую
  @override
  Future<void> stopHosting() async => stopCalls++;
}
```

Настоящий `stopHosting` начинается с `if (!canHost) return;`, а тесты идут на
macOS. Без переопределения каждое утверждение «гашение не произошло»
выполнялось бы само собой.

### Что именно проверяется на утечку

Утверждения на **количество** вызовов, а не на факт: утёкший таймер выглядит
как корректный ровно до второго срабатывания.

| Тест | Метрика |
|---|---|
| 10 подряд `paused` | `stopCalls == 1` (не 10), `pendingTimers` пуст |
| 50 циклов `paused`/`resumed` по 100 мс | `pendingTimers` пуст, `stopCalls == 0` за час |
| `paused` → `detached` | `stopCalls == 1`, и через grace всё ещё 1 |
| `detach()` при висящем таймере | `stopCalls == 0` за час |
| 5 циклов `attach`/`detach` + один живой | `stopCalls == 1` — наблюдатели не копятся |

### Что проверяется на поведение

| Тест | Что доказывает |
|---|---|
| `detached` гасит немедленно | Процесс уходит, вежливость неуместна |
| `paused` ждёт grace-период | Передача переживает взгляд в другое приложение |
| `hidden` ведёт себя как `paused` | — |
| `inactive` игнорируется | Иначе сеть падала бы от каждого баннера |
| `resumed` отменяет гашение | Вернулись — сеть на месте |
| grace перезапускается после каждого возврата | Шесть минут фона суммарно, ни разу две подряд |

---

# Заход 3 — интеграционные тесты на реальном WebRTC

Состояние: **201 юнит + 6 интеграционных, `flutter analyze` — 0.**

Главное этого захода: интеграционный тест нашёл дефект, который принципиально
не мог быть найден юнит-тестами, и serverless-путь впервые отработал end-to-end.

---

## Открытие: macOS-десктоп — это устройство

```bash
flutter devices
# Found 1 connected device:
#   macOS (desktop) • macos • darwin-arm64 • macOS 15.5
```

Блокер «нет железа» к десктопной половине не относился. flutter_webrtc
собирается под macOS, значит настоящий нативный стек запускается прямо здесь —
без телефона, эмулятора и подписи.

---

## Найденный дефект: несовпадение m-строк

Первый прогон `integration_test/serverless_e2e_test.dart -d macos`:

```
Failed to set remote answer sdp: The order of m-lines in answer
doesn't match order in offer. Rejecting answer.
```

Снял оба SDP диагностическим прогоном:

```
РЕАЛЬНЫЙ ОФФЕР                      ШАБЛОН CompactSdp
a=group:BUNDLE 0 1 2                a=group:BUNDLE 0
m=audio        … a=mid:0            m=application … a=mid:0
m=video        … a=mid:1
m=application  … a=mid:2  ← нужный
```

flutter_webrtc по умолчанию предлагает audio и video, даже когда создан только
DataChannel. Приёмник отвечал на однострочный шаблон, отправитель прикладывал
ответ к трёхстрочному офферу.

### Было

```dart
Future<String?> createLocalOfferSdp() async {
  if (_peerConnection == null) return null;
  final offer = await _peerConnection!.createOffer();
```

### Стало

```dart
  /// Constraints that keep the offer to the one media section this app has
  /// any use for. …the answer came back with one m-line against an offer with
  /// three and libwebrtc rejected it with "the order of m-lines in answer
  /// doesn't match order in offer".
  static const Map<String, dynamic> _dataChannelOnly = {
    'mandatory': {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };

  Future<String?> createLocalOfferSdp() async {
    if (_peerConnection == null) return null;
    final offer = await _peerConnection!.createOffer(_dataChannelOnly);
```

**Побочный эффект, замеренный:** оффер ужался с 8591 до 2045 символов,
кандидатов стало 11 вместо 39 — ушли кодековые списки для медиа, которых мы
не шлём.

### Защита, чтобы не вернулось

Проверка в `CompactSdp.fromSdp` — падать там, где причина, а не через сетевой
раунд-трип в `setRemoteDescription`:

```dart
if (mediaSections > 1) {
  throw FormatException(
      'SDP carries $mediaSections media sections; CompactSdp can only '
      'represent one. Create the offer with OfferToReceiveAudio and '
      'OfferToReceiveVideo disabled.');
}
```

Два юнит-теста на неё, проверено что группа реально вызывается из `main()`.

---

## Вторая находка: отправитель не принимал свой signaling URL

LAN-тест падал на `Connection refused`. Причина оказалась в асимметрии API:
приёмник принимал `signalingUrl` с момента написания, отправитель — нет,
`initialize()` жёстко брал `AppConstants.signalingServerUrl`. Room-путь
невозможно было прогнать ни против чего, кроме процесса на вкомпилированном
порту.

```diff
-  WebRtcTransferTransport();
+  /// Overrides the signaling endpoint this sender dials.
+  ///
+  /// The receiver has taken one of these since it was written; the sender did
+  /// not, which made the room-based path impossible to exercise against
+  /// anything but a process listening on the compiled-in default.
+  final String? signalingUrlOverride;
+
+  WebRtcTransferTransport({this.signalingUrlOverride});
```

---

## Тесты

### `integration_test/serverless_e2e_test.dart` — 4 теста

| Тест | Что доказывает |
|---|---|
| Файл 512 КБ через настоящий DataChannel | `CompactSdp` → `SealedEnvelope` → ответ → `handleDirectAnswer` → чанки → запись. Сверка **побайтовая по SHA-256** |
| Файл лёг в `_baseDir` | Регрессия с CWD не вернулась |
| `progressStream` даёт `transferring` и `completed` | Экран больше не висит на «Connecting» |
| Ответ, запечатанный для другого оффера, отвергается | Релей несёт трафик всего мира; чужое должно падать на аутентификации |
| ICE собирает годные кандидаты | Печатает типы — это диагностика, ради которой тест и гоняется |

Рандеву **in-memory**, а не настоящий Nostr: тест не должен зависеть от чужого
аптайма. Запечатывание при этом настоящее — отправитель принимает только то,
что открывается под seed из его же QR.

### `integration_test/lan_webrtc_e2e_test.dart` — 2 теста

Сигнальный сервер — сорок строк Dart внутри теста, а не процесс Node.
Первая версия дёргала `signaling_server/server.js`, и тест **молча
пропускался**: `Directory.current` внутри запущенного macOS-приложения — это
бандл, а не репозиторий, скрипт не находился. Свой сервер такого режима отказа
не имеет и от `node` на PATH не зависит.

```
Signaling: connecting to ws://192.168.3.52:50820
WebRTC: receiver joined — creating offer
WebRTC receiver ICE: RTCIceConnectionStateChecking
WebRTC sender DataChannel state: RTCDataChannelOpen
WebRTC receiver ICE: RTCIceConnectionStateConnected
```

Дублирующий гард на односекционный оффер: `startSharing()` строит его другим
методом, значит нуждается в собственной проверке.

---

## Побочный замер: TURN не даёт relay

```
ICE gathered: 11 candidates, types {host, srflx} — relay present: false
```

Эмпирическое подтверждение, что зашитые креды `openrelaymodule` relay-кандидата
не производят. Вопрос висел открытым с момента, когда обнаружился мёртвый
`openrelay.metered.ca` — теперь на него есть ответ из прогона, а не из
рассуждения.

---

## CI

`.github/workflows/integration.yml` — отдельная джоба, **не на каждый PR**:

- `schedule: '0 4 * * *'` — отказ ждёт утром, а не прерывает работу;
- `workflow_dispatch` — руками;
- `push` только по путям, где поломка невидима юнит-суите: `core/webrtc/**`,
  `core/signaling/**`, `*/data/transports/**`, `integration_test/**`.

Пайплайн, которого ждут, — это пайплайн, который учатся игнорировать.
