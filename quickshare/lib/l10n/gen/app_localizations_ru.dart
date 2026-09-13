// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appName => 'DirectDrop';

  @override
  String get appTagline =>
      'Мгновенно делитесь файлами по Wi-Fi, Bluetooth\nили по ссылке через интернет';

  @override
  String get commonCancel => 'Отмена';

  @override
  String get commonClear => 'Очистить';

  @override
  String get commonSave => 'Сохранить';

  @override
  String get commonDone => 'Готово';

  @override
  String get commonOpen => 'Открыть';

  @override
  String get commonRetry => 'Повторить';

  @override
  String get commonSettings => 'Настройки';

  @override
  String get commonChange => 'Изменить';

  @override
  String get commonOk => 'ОК';

  @override
  String get homeSendTitle => 'Отправить файл';

  @override
  String get homeSendSubtitle => 'Выберите файл и поделитесь им';

  @override
  String get homeReceiveTitle => 'Получить файл';

  @override
  String get homeReceiveSubtitleDesktop => 'Вставьте код или ссылку';

  @override
  String get homeReceiveSubtitleMobile => 'Отсканируйте QR-код';

  @override
  String get homeDropHere => 'Перетащите файл сюда для отправки';

  @override
  String get homeSettingsTooltip => 'Настройки';

  @override
  String get errorOops => 'Ой!';

  @override
  String get errorGoHome => 'На главную';

  @override
  String get pickerTitle => 'Отправка файла или папки';

  @override
  String get pickerIndexing => 'Индексируем выбранное…';

  @override
  String get pickerStartingSession => 'Запуск защищённого прямого соединения';

  @override
  String get pickerStepMethod => '1. Выберите способ передачи';

  @override
  String get pickerMethodWifiTitle => 'Wi-Fi / Локальная сеть';

  @override
  String get pickerMethodWifiSubtitle => 'Быстрая передача по локальной сети';

  @override
  String get pickerMethodBluetoothTitle => 'Bluetooth';

  @override
  String get pickerMethodBluetoothSubtitle => 'Прямая передача по Bluetooth';

  @override
  String get pickerMethodInternetTitle => 'Ссылка через интернет';

  @override
  String get pickerMethodInternetSubtitle =>
      'Ссылка через сигнальный сервер WebRTC';

  @override
  String get pickerStepWhat => '2. Что отправить';

  @override
  String get pickerPhotosVideos => 'Фото и видео';

  @override
  String get pickerSelectFile => 'Выбрать файл';

  @override
  String get pickerSelectFolder => 'Выбрать папку';

  @override
  String get pickerSendMedia => 'Отправить фото и видео';

  @override
  String get pickerSendFiles => 'Отправить файлы';

  @override
  String get pickerSendFilesHint =>
      'Файлы и папки — можно выбрать сразу несколько';

  @override
  String pickerIndexingFound(int count, String size) {
    return 'Найдено: $count · $size';
  }

  @override
  String get wifiPromptTitle => 'Включить Wi-Fi для более быстрой отправки?';

  @override
  String get wifiPromptBody =>
      'Один Bluetooth работает медленно — большое видео может идти часами.\n\nС включённым Wi-Fi устройства соединяются напрямую, и те же файлы уходят за секунды. Подключаться к сети не нужно, достаточно включить сам модуль.';

  @override
  String get wifiPromptDecline => 'Отправить по Bluetooth';

  @override
  String get wifiPromptAccept => 'Открыть настройки';

  @override
  String get completeSaving => 'Сохраняем…';

  @override
  String get completeTitle => 'Получено!';

  @override
  String get completeWhereTo => 'Куда сохранить?';

  @override
  String get completeSaveOne => 'Сохранить на устройство';

  @override
  String completeSaveMany(int count) {
    return 'Сохранить файлы ($count) на устройство';
  }

  @override
  String get completeReceiveAnother => 'Получить ещё раз';

  @override
  String get completeDontSave => 'Не сохранять';

  @override
  String completeSavedCount(int count) {
    return 'Сохранено: $count';
  }

  @override
  String completeWaitingCount(int count) {
    return 'Ждут решения: $count';
  }

  @override
  String completeFailedCount(int count) {
    return 'Не удалось сохранить: $count';
  }

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get settingsStorage => 'Хранилище';

  @override
  String get settingsCache => 'Кэш';

  @override
  String get settingsCacheMeasuring => 'Измеряем…';

  @override
  String get settingsCacheDescription =>
      'Входящие файлы хранятся здесь, пока вы их не сохраните. Всё, что вы не сохранили, удаляется автоматически при выходе с экрана передачи.';

  @override
  String get settingsClearCacheTitle => 'Очистить кэш?';

  @override
  String get settingsClearCacheBody =>
      'Всё полученное, но ещё не сохранённое, будет удалено. Файлы, которые вы уже сохранили на устройство, не пострадают.';

  @override
  String settingsCacheFreed(String size) {
    return 'Освобождено $size';
  }

  @override
  String get settingsCacheNothingToClear => 'Нечего очищать';

  @override
  String get settingsSaveLocation => 'Папка сохранения';

  @override
  String get settingsSaveLocationDefault => 'По умолчанию для этого устройства';

  @override
  String get settingsSaveLocationDefaultSubtitle =>
      'Папка «Загрузки», которую обычно использует эта система';

  @override
  String get settingsSaveLocationCustomSubtitle =>
      'Полученные файлы сохраняются сюда';

  @override
  String get settingsSaveLocationReading => 'Читаем…';

  @override
  String get settingsSaveLocationUseDefault =>
      'Использовать папку по умолчанию';

  @override
  String get settingsSaveLocationFootnote =>
      'Сюда попадают только файлы, которые DirectDrop сохраняет автоматически — фото на телефоне всё равно уходит в галерею, а всё, о чём приложение вас спрашивает, по-прежнему сохраняется туда, куда вы укажете в тот момент.';

  @override
  String get settingsSaveLocationPickerTitle =>
      'Куда сохранять полученные файлы?';

  @override
  String settingsSaveLocationError(String error) {
    return 'Не удалось использовать эту папку: $error';
  }

  @override
  String get settingsLanguage => 'Язык';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsLanguageRussian => 'Русский';

  @override
  String get settingsLanguageFootnote =>
      'Меняет интерфейс сразу же, только на этом устройстве.';

  @override
  String get settingsLastTransfers => 'Последние передачи';

  @override
  String get settingsNoTransfersYet => 'Пока нет передач';

  @override
  String get settingsNoTransfersYetSubtitle =>
      'Здесь появится передача, как только она завершится.';

  @override
  String get settingsCopyDetails => 'Скопировать сведения';

  @override
  String get settingsDetailsCopied => 'Сведения скопированы';

  @override
  String settingsTransferPeerSent(String address) {
    return 'Отправлено на $address';
  }

  @override
  String settingsTransferPeerReceived(String address) {
    return 'Соединение с $address';
  }

  @override
  String get settingsTransferFootnote =>
      'Скорость объясняется маршрутом. Прямая связь — самая быстрая, передача через интернет-реле — самая медленная. Скопируйте сведения, если просите кого-то о помощи.';

  @override
  String get commonSend => 'Отправить';

  @override
  String get commonCopy => 'Копировать';

  @override
  String get commonNo => 'Нет';

  @override
  String get commonYes => 'Да';

  @override
  String get commonOpenSettings => 'Открыть настройки';

  @override
  String get commonUnknownError => 'Неизвестная ошибка';

  @override
  String get transferFileReceived => 'Файл получен';

  @override
  String sharedItemsCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файла',
      many: '$count файлов',
      few: '$count файла',
      one: '$count файл',
    );
    return '$_temp0';
  }

  @override
  String mediaSelectedCount(int count) {
    return 'Выбрано: $count';
  }

  @override
  String get mediaNotStored =>
      'Эти файлы не хранятся на устройстве — откройте их в Фото, чтобы они загрузились, и попробуйте снова.';

  @override
  String mediaSkippedICloud(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файла есть',
      many: '$count файлов есть',
      few: '$count файла есть',
      one: '$count файл есть',
    );
    return '$_temp0 только в iCloud — пропущены.';
  }

  @override
  String get mediaAccessDeniedTitle => 'У DirectDrop нет доступа к вашим фото';

  @override
  String get mediaAccessDeniedBody =>
      'Дайте доступ в настройках, чтобы отправлять фото и видео.';

  @override
  String get mediaEmptyTitle => 'Здесь пока пусто';

  @override
  String get mediaLimitedBody => 'С DirectDrop поделились только частью фото.';

  @override
  String get mediaEmptyBody => 'На этом устройстве нет фото или видео.';

  @override
  String get mediaChooseMore => 'Выбрать ещё';

  @override
  String get mediaLimitedBanner => 'Вы поделились только частью фото.';

  @override
  String get mediaManage => 'Управлять';

  @override
  String get qrDisplayTitle => 'Отправка файла';

  @override
  String get qrDisplayPreparing => 'Готовим отправку…';

  @override
  String get qrDisplayPreparingDetail => 'Создаём защищённую QR-сессию';

  @override
  String get qrDisplayScanOrShare => 'Отсканируйте QR или отправьте ссылку';

  @override
  String get qrDisplayShareLinkToReceive =>
      'Отправьте эту ссылку, чтобы получить файл';

  @override
  String get qrDisplayScanToReceive =>
      'Отсканируйте этот QR-код, чтобы получить файл';

  @override
  String get qrDisplayPhoneHint =>
      'На телефоне: откройте DirectDrop → Получить и отсканируйте этот QR.';

  @override
  String qrDisplayRenderError(String error) {
    return 'Ошибка отрисовки QR: $error';
  }

  @override
  String get qrDisplayShareLinkLabel => 'Ссылка';

  @override
  String get qrDisplayLinkCopied => 'Ссылка скопирована';

  @override
  String qrDisplayTotalSize(String size) {
    return 'Общий размер: $size';
  }

  @override
  String qrDisplaySessionExpires(String time) {
    return 'Сессия истекает через $time';
  }

  @override
  String get qrDisplayCancelTransfer => 'Отменить передачу';

  @override
  String get precondWifiTitle => 'Включите Wi-Fi';

  @override
  String get precondWifiBody =>
      'Передача по локальной сети работает только с включённым Wi-Fi-модулем.';

  @override
  String get precondBluetoothTitle => 'Включите Bluetooth';

  @override
  String get precondBluetoothBody =>
      'Передача по Bluetooth работает только с включённым Bluetooth-модулем.';

  @override
  String get precondOpenSettings => 'Открыть настройки';

  @override
  String get precondOpenAppSettings => 'Настройки приложения';

  @override
  String get precondWifiBodyApple =>
      'Передача по локальной сети работает через Wi-Fi. iOS не даёт приложениям открывать раздел Wi-Fi, поэтому включите его сами: Настройки › Wi-Fi. Если Wi-Fi уже включён, возможно, приложению не выдан доступ к локальной сети — он находится на странице настроек приложения.';

  @override
  String get precondWifiBlocked =>
      'Передача невозможна, пока не включён Wi-Fi.';

  @override
  String get precondBluetoothBlocked =>
      'Передача невозможна, пока не включён Bluetooth.';

  @override
  String get precondBluetoothNeedsWifi =>
      'Для передачи по Bluetooth нужен включённый Wi-Fi';

  @override
  String get precondBluetoothNeedsWifiBody =>
      'Сам файл идёт по прямому Wi-Fi-каналу между устройствами — Bluetooth только находит их. Включите Wi-Fi, к сети подключаться не нужно.';

  @override
  String get precondBluetoothNeedsWifiBodyApple =>
      'Сам файл идёт по прямому Wi-Fi-каналу между устройствами — Bluetooth только находит их. iOS не даёт приложению открыть панель Wi-Fi, поэтому включите его сами в Настройках → Wi-Fi. К сети подключаться не нужно.';

  @override
  String get precondBluetoothWifiBlocked =>
      'Передача по Bluetooth недоступна, пока не включён Wi-Fi.';

  @override
  String get precondInternetBlocked =>
      'Нет активного сетевого подключения. Передача через интернет недоступна.';

  @override
  String get sessionExpiredTitle => 'Сессия истекла';

  @override
  String get sessionExpiredBody =>
      'За отведённое время никто не подключился. Обновите, чтобы создать новую сессию.';

  @override
  String get sessionRefresh => 'Обновить';

  @override
  String get senderProgressCancelTitle => 'Отменить передачу?';

  @override
  String get senderProgressCancelBody =>
      'Вы уверены, что хотите остановить отправку этого файла?';

  @override
  String get senderProgressCancelConfirm => 'Да, отменить';

  @override
  String get senderProgressTitle => 'Передача файла';

  @override
  String get senderProgressCompleteTitle => 'Передача завершена!';

  @override
  String get senderProgressSendAnother => 'Отправить ещё файл';

  @override
  String get senderProgressSending => 'Отправка…';

  @override
  String get senderProgressFailed => 'Передача не удалась';

  @override
  String get senderProgressPreparing => 'Готовим передачу…';

  @override
  String get fallbackTooLargeTitle => 'Слишком много для этого соединения';

  @override
  String get fallbackNoRouteTitle => 'Нет прямого пути к другому устройству';

  @override
  String fallbackTooLargeBody(String size) {
    return 'Единственный доступный путь идёт через публичное реле. $size шли бы очень долго и вряд ли дошли бы до конца, поэтому пока ничего не отправлено.';
  }

  @override
  String get fallbackNoRouteBody =>
      'VPN или NAT этой сети блокирует прямое соединение, а реле оказалось недоступно. Пока ничего не отправлено.';

  @override
  String get fallbackWifiTitle => 'Подключите оба устройства к одной сети';

  @override
  String get fallbackWifiBody =>
      'Передача по локальной сети не имеет ограничения по размеру и идёт на полной скорости канала.';

  @override
  String get fallbackWifiBodyCanHost =>
      'Передача по локальной сети не имеет ограничения по размеру и идёт на полной скорости канала. Это устройство может само поднять такую сеть, если роутера рядом нет.';

  @override
  String get fallbackVpnTitle => 'Или отключите VPN на время передачи';

  @override
  String get fallbackVpnBody =>
      'VPN, перехватывающий маршрут по умолчанию, мешает устройствам найти друг друга напрямую.';

  @override
  String get fallbackCreateNetwork => 'Создать сеть для этой передачи';

  @override
  String get fallbackGoBack => 'Вернуться и выбрать другой способ';

  @override
  String fallbackRelayCap(String size) {
    return 'Передача через реле ограничена $size.';
  }

  @override
  String get localNetTitle => 'Локальная сеть';

  @override
  String get localNetCreating => 'Создаём сеть…';

  @override
  String get localNetWorking => 'Работаем…';

  @override
  String get localNetStep1Title => 'Отсканируйте это камерой другого телефона';

  @override
  String get localNetStep1Subtitle =>
      'Он присоединится к сети. Приложение для этого шага не нужно.';

  @override
  String get localNetNetworkLabel => 'Сеть';

  @override
  String get localNetPasswordLabel => 'Пароль';

  @override
  String get localNetNoInternetNote =>
      'У этой сети нет интернета — она нужна только для передачи файлов.';

  @override
  String get localNetJoinedButton => 'Готово, подключено';

  @override
  String get localNetStep2Title => 'Теперь отсканируйте этот в приложении';

  @override
  String localNetStep2Subtitle(String host) {
    return 'Он указывает на файлы на $host.';
  }

  @override
  String get btSendTitle => 'Bluetooth';

  @override
  String get btSendPreparing => 'Готовим Bluetooth…';

  @override
  String get btSendPreparingDetail => 'Делаем устройство видимым';

  @override
  String get btSendScanPrompt =>
      'Отсканируйте этот QR-код на принимающем устройстве';

  @override
  String get btSendAutoConnectNote =>
      'Принимающее устройство подключится по Bluetooth и начнёт передачу автоматически.';

  @override
  String get btReceiveLookingForLink => 'Ищем прямую связь…';

  @override
  String get btReceiveDirectLinkPlaceholder => 'Получаем напрямую по Wi-Fi';

  @override
  String get btReceiveTitle => 'Устройства рядом';

  @override
  String get btReceiveLookingNearby => 'Ищем Mac поблизости…';

  @override
  String get btReceiveLookingQr => 'Ищем Mac из QR-кода…';

  @override
  String get btReceiveScanning => 'Ищем устройства поблизости…';

  @override
  String get btReceiveScanningDetail =>
      'Держите Bluetooth включённым на обоих устройствах';

  @override
  String get btReceiveConnecting => 'Подключаемся по Bluetooth…';

  @override
  String btReceivePairingWith(String name) {
    return 'Соединяемся с $name';
  }

  @override
  String get btReceiveConnectionFailed => 'Не удалось подключиться';

  @override
  String get btReceiveScanAgain => 'Искать снова';

  @override
  String get codeReceivePasteError => 'Вставьте ссылку от отправителя.';

  @override
  String get codeReceiveParseError =>
      'Не удалось прочитать эту ссылку. Скопируйте ссылку под QR-кодом у отправителя.';

  @override
  String get codeReceiveTitle => 'Получить файл';

  @override
  String get codeReceivePastePrompt => 'Вставьте код или ссылку';

  @override
  String get codeReceiveHint => 'directdrop://join?p=…';

  @override
  String get codeReceivePasteButton => 'Вставить';

  @override
  String get codeReceiveReceiveButton => 'Получить';

  @override
  String get codeReceiveFileFound => 'Файл найден';

  @override
  String get codeReceiveIncomingTransfer => 'Входящая передача';

  @override
  String get codeReceiveSizeUnknown =>
      'Размер станет известен после начала передачи';

  @override
  String get codeReceiveDownloadButton => 'Скачать';

  @override
  String get codeReceiveConnecting => 'Подключаемся к отправителю…';

  @override
  String get codeReceiveConnectingDetail =>
      'Держите Mac открытым на экране передачи. В одной Wi-Fi сети сигнализация работает напрямую; через LTE нужен публичный сервер сигнализации и TURN.';

  @override
  String get codeReceiveTransferFailed => 'Передача не удалась';

  @override
  String codeReceiveSignalingError(String url) {
    return 'Сервер сигнализации недоступен ($url). Укажите свой сервер через:\n--dart-define=QUICKSHARE_SIGNALING_URL=wss://your-server.com';
  }

  @override
  String get codeReceiveTryAnother => 'Попробовать другой код';

  @override
  String get codeReceiveNotFoundLan =>
      'Отправитель с этим кодом не найден в локальной сети. Убедитесь, что оба устройства подключены к одной сети Wi-Fi.';

  @override
  String get codeReceiveNotAShareLink =>
      'Это не ссылка DirectDrop. Скопируйте ссылку под QR у отправителя — не адрес Wi-Fi.';

  @override
  String get codeReceiveInvalidQr =>
      'Неверный QR-код. Наведите камеру на QR на экране отправителя — не на текст Wi-Fi под ним.';

  @override
  String get codeReceiveSearchingLan => 'Поиск отправителя в локальной сети…';

  @override
  String get qrScanCameraPermission => 'Нужен доступ к камере';

  @override
  String get qrScanDetected => 'QR найден — открываем передачу…';

  @override
  String qrScanCameraError(String code) {
    return 'Ошибка камеры: $code\nПопробуйте закрыть и снова открыть Получение.';
  }

  @override
  String get qrScanEnterCode => 'Ввести код';

  @override
  String get qrScanPointCamera => 'Наведите камеру на QR-код';

  @override
  String get qrScanPreparingCamera => 'Готовим камеру…';

  @override
  String get qrScanPreparingDetail => 'Запрашиваем доступ к камере';

  @override
  String get downloadWakelockWarning =>
      'Держите экран включённым и приложение открытым до окончания передачи файла.';

  @override
  String get downloadCancelTitle => 'Отменить скачивание?';

  @override
  String get downloadTitle => 'Скачивание…';

  @override
  String get downloadConnecting => 'Подключаемся к отправителю…';

  @override
  String get downloadConnectingDetail => 'Готовим защищённый канал передачи';

  @override
  String get downloadVerifying => 'Проверяем передачу…';

  @override
  String get downloadVerifyingDetail => 'Проверяем целостность файла';

  @override
  String get downloadPreparing => 'Готовим скачивание…';

  @override
  String get downloadPreparingDetail => 'Ждём отправителя';

  @override
  String get downloadErrorSenderUnreachable =>
      'Связь с отправителем потеряна. Возможно, он отменил передачу, закрыл приложение или у него пропал Wi-Fi. Попросите его начать передачу заново.';

  @override
  String get downloadErrorCancelledBySender => 'Отправитель отменил передачу.';

  @override
  String get previewReadyTitle => 'Готово к приёму';

  @override
  String get previewFolderTransfer => 'Передача папки';

  @override
  String previewFolderSize(String size) {
    return 'Размер папки: $size';
  }

  @override
  String get previewCalculatingSize => 'Считаем размер…';

  @override
  String get previewStarting => 'Начинаем передачу файла…';

  @override
  String get previewConfirmPrompt => 'Принять эту передачу?';

  @override
  String get previewStartNow => 'Начать сейчас';

  @override
  String get settingsLogs => 'Журнал';

  @override
  String get settingsLogsSubtitle =>
      'Технический лог — скопируйте его, когда сообщаете о проблеме с передачей';

  @override
  String get logsCopyAll => 'Скопировать весь журнал';

  @override
  String get logsEmpty => 'Записей пока нет';

  @override
  String get nearbyTitle => 'Устройства рядом';

  @override
  String get nearbySearching => 'Ищем…';

  @override
  String get nearbyEmpty => 'Пока никого';

  @override
  String get nearbyEmptyHint =>
      'Откройте DirectDrop на другом устройстве. Оба должны быть в одной сети.';

  @override
  String get nearbyBlocked => 'Эта сеть скрывает устройства друг от друга';

  @override
  String get nearbyBlockedHint =>
      'Так обычно устроены гостевые и публичные сети. Используйте код ниже.';

  @override
  String get nearbyReady => 'Готов отправить';

  @override
  String get nearbyIdle => 'Ожидает';

  @override
  String get inviteTitle => 'Принять файлы?';

  @override
  String get inviteAccept => 'Принять';

  @override
  String get inviteDecline => 'Отклонить';

  @override
  String get inviteUnknownSize => 'размер неизвестен';

  @override
  String inviteApprovalBody(
      String deviceName, String address, int itemCount, String size) {
    String _temp0 = intl.Intl.pluralLogic(
      itemCount,
      locale: localeName,
      other: '$itemCount файлов',
      few: '$itemCount файла',
      one: '$itemCount файл',
    );
    return '$deviceName$address хочет получить $_temp0 ($size).';
  }

  @override
  String inviteApprovalExpiresIn(int seconds) {
    return 'Запрос истекает через $seconds с';
  }

  @override
  String previewSenderLabel(String sender) {
    return 'От: $sender';
  }

  @override
  String get nearbyOrPaste => 'Или вставьте код';

  @override
  String get inviteAsking => 'Спрашиваем…';

  @override
  String get inviteAccepted => 'Принято — отправляем';

  @override
  String get inviteDeclined => 'Отклонено';

  @override
  String get inviteUnreachable => 'Не удалось связаться с устройством';

  @override
  String get inviteBusy => 'Устройство сейчас решает по другой передаче';

  @override
  String get nearbySendTo => 'Отправить сразу на устройство';

  @override
  String get codeLabel => 'Код для принимающего устройства';

  @override
  String get codeHint =>
      'Введите его на другом устройстве, если его нет в списке выше';

  @override
  String get codeEnterPrompt => 'Введите код с устройства-отправителя';

  @override
  String get codeEnterHint => '10 цифр';

  @override
  String get codeNotFound => 'Рядом нет устройства с таким кодом';

  @override
  String get btReceiveCodePrompt => 'Введите код с устройства-отправителя';

  @override
  String get qrScanBluetoothReceive => 'Получить по Bluetooth';

  @override
  String get btReceiveWaitingToBeChosen =>
      'Ждём выбора на устройстве-отправителе';

  @override
  String get btReceiveWaitingDetail =>
      'Это устройство видно отправителю. Выберите его там, чтобы начать передачу.';

  @override
  String get btReceiveCodeInvalid => 'Код состоит из 10 цифр';

  @override
  String get codeMalformed => 'Код состоит из 10 цифр';

  @override
  String get routeDirectWifiLink => 'Прямая связь Wi-Fi';

  @override
  String get routeLocalNetwork => 'Локальная сеть';

  @override
  String get routeInternetDirect => 'Интернет (напрямую, одна сеть)';

  @override
  String get routeInternetPeerToPeer =>
      'Интернет (напрямую между устройствами)';

  @override
  String get routeInternetRelayed => 'Интернет (через реле)';

  @override
  String get routeBluetooth => 'Bluetooth';

  @override
  String get routeUnknown => 'Маршрут неизвестен';

  @override
  String settingsTransferSent(String size, int seconds) {
    return 'Отправлено $size за $seconds с';
  }

  @override
  String settingsTransferReceived(String size, int seconds) {
    return 'Принято $size за $seconds с';
  }

  @override
  String get errorTransferFailedUnexpectedly =>
      'Передача оборвалась, и соединение не сообщило почему. Попробуйте ещё раз, а если повторяется — подключите оба устройства к одной сети.';

  @override
  String get errorBluetoothStartFailed =>
      'Не удалось начать передачу по Bluetooth.';

  @override
  String get errorBluetoothTransferFailed =>
      'Передача по Bluetooth оборвалась.';

  @override
  String get errorInternetStartFailed =>
      'Не удалось начать передачу через интернет.';

  @override
  String get errorNothingSelected => 'Не выбрано ни одного файла или папки.';

  @override
  String get errorSelectionUnreadable => 'Не удалось прочитать выбранное.';

  @override
  String get errorNetworkCreateFailed =>
      'Не удалось создать сеть на этом устройстве.';

  @override
  String get errorNetworkWithoutAddress =>
      'Сеть поднялась, но так и не получила адреса — направить второе устройство некуда.';

  @override
  String get errorNothingToRestart =>
      'Возобновлять нечего — выберите файлы заново.';

  @override
  String get errorReceiverTooOldForDirectLink =>
      'На принимающем устройстве старая версия: она умеет принимать только по Bluetooth. Обновите её, и передача пойдёт по прямой связи Wi-Fi.';

  @override
  String get errorReceiverTooOldToPair =>
      'На принимающем устройстве старая версия: она не умеет безопасно соединяться по Bluetooth. Обновите её или отправьте по Wi-Fi.';

  @override
  String get errorCancelledHere => 'Вы отменили передачу.';

  @override
  String get errorLinkWifiOff =>
      'Wi-Fi выключен. Передача строит прямую связь Wi-Fi между устройствами и без него не начнётся.';

  @override
  String get errorLinkPeerSilentAtSetup =>
      'Второе устройство не ответило на настройку защищённой связи. Убедитесь, что на нём стоит текущая версия, и попробуйте ещё раз.';

  @override
  String get errorLinkSetupFailed =>
      'Не удалось построить прямую связь Wi-Fi. Держите устройства рядом и попробуйте ещё раз.';

  @override
  String get errorLinkPeerLost =>
      'Связь со вторым устройством пропала до того, как канал был построен. Не уходите с этого экрана и попробуйте ещё раз.';

  @override
  String get errorLinkWithoutAddress =>
      'Канал поднят, но это устройство не смогло определить свой адрес в нём.';

  @override
  String get errorSessionWithoutCertificate =>
      'Передача началась без сертификата, и второму устройству нечему доверять. Попробуйте ещё раз.';

  @override
  String get qrDisplayStillCounting => 'Считаем файлы…';
}
