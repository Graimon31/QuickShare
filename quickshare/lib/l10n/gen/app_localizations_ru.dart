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
  String completeAndMore(int count) {
    return 'и ещё $count';
  }

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
      'На телефоне: откройте DirectDrop → Получить и отсканируйте этот QR.\nСтрока Wi-Fi ниже нужна только для диагностики — это НЕ содержимое QR.';

  @override
  String qrDisplayRenderError(String error) {
    return 'Ошибка отрисовки QR: $error';
  }

  @override
  String get qrDisplayShareLinkLabel => 'Ссылка';

  @override
  String get qrDisplayLinkCopied => 'Ссылка скопирована';

  @override
  String get qrDisplayWifiAddressLabel => 'Wi-Fi адрес отправителя';

  @override
  String get qrDisplayWifiAddressCopied => 'Wi-Fi адрес скопирован';

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
      'У локальной передачи нет ограничения по размеру, и идёт она на полной скорости канала. Этот телефон может сам создать такую сеть, если рядом нет роутера.';

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
  String get previewStartNow => 'Начать сейчас';
}
