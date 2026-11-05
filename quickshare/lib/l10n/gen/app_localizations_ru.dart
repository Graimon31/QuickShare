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
      'Мгновенно делитесь файлами\nчерез интернет или напрямую';

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
  String get homeInternetTitle => 'Через интернет';

  @override
  String get homeInternetSubtitle => 'Работает из любой сети';

  @override
  String get homeAirdropTitle => 'AirDrop';

  @override
  String get homeAirdropSubtitle => 'Для устройств поблизости';

  @override
  String get homeLocalNetworkTitle => 'Передача по локальной сети';

  @override
  String get homeLocalNetworkSubtitle => 'Оба устройства в одной сети';

  @override
  String homeAirdropAltTitle(String airdrop) {
    return 'Аналог $airdrop';
  }

  @override
  String get homeAirdropAltSubtitle =>
      'На телефон поблизости, общая сеть не нужна';

  @override
  String get homeReceiveTitle => 'Получить файл';

  @override
  String get homeReceiveSubtitleDesktop => 'Введите код отправителя';

  @override
  String get homeReceiveSubtitleMobile =>
      'Отсканируйте QR-код или введите код отправителя';

  @override
  String get homeDropHere => 'Перетащите файл сюда для отправки';

  @override
  String get homeSettingsTooltip => 'Настройки';

  @override
  String get errorOops => 'Ой!';

  @override
  String get errorGoHome => 'На главную';

  @override
  String get pickerIndexing => 'Индексируем выбранное…';

  @override
  String get pickerStartingSession => 'Запуск защищённого прямого соединения';

  @override
  String get pickerStepWhat => 'Что отправить';

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
  String get qrDisplayScanOrEnterCode => 'Отсканируйте QR или введите код';

  @override
  String offerCodeChangesIn(String time) {
    return 'Код и QR сменятся через $time';
  }

  @override
  String offerQrChangesIn(String time) {
    return 'QR-код сменится через $time';
  }

  @override
  String get qrDisplayScanToReceive =>
      'Отсканируйте этот QR-код, чтобы получить файл';

  @override
  String get qrDisplayPhoneHint =>
      'На другом устройстве: откройте DirectDrop → Получить. Телефон сканирует этот QR, компьютер вводит код.';

  @override
  String qrDisplayRenderError(String error) {
    return 'Ошибка отрисовки QR: $error';
  }

  @override
  String qrDisplayTotalSize(String size) {
    return 'Общий размер: $size';
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
      'VPN или NAT этой сети блокирует прямое соединение. Пока ничего не отправлено.';

  @override
  String get fallbackNoRouteBodyRelayLimited =>
      'Прямое соединение невозможно, а сервис реле сейчас ограничивает запросы, поэтому реле поднять не удалось. Попробуйте ещё раз примерно через минуту. Пока ничего не отправлено.';

  @override
  String get fallbackNoRouteBodyRelayUnreachable =>
      'Прямое соединение невозможно, а сервис реле недоступен, поэтому реле поднять не удалось. Проверьте подключение этого устройства к интернету. Пока ничего не отправлено.';

  @override
  String get fallbackNoRouteBodyRelayOff =>
      'Прямое соединение невозможно, а реле в этой сборке выключено или не настроено. Пока ничего не отправлено.';

  @override
  String get fallbackNoRouteBodyRelayWasAvailable =>
      'Реле было доступно, но соединение всё равно не удалось установить. Возможно, VPN или фаервол блокирует даже трафик через реле. Пока ничего не отправлено.';

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
  String get btSendPreparingDetail =>
      'Готовим код, который отсканирует второй телефон';

  @override
  String get btSendScanPrompt =>
      'Отсканируйте этот QR-код на телефоне-получателе';

  @override
  String get btSendAutoConnectNote =>
      'По Bluetooth принимает телефон: откройте на нём DirectDrop, нажмите «Получить файл» и отсканируйте этот код. Компьютер по Bluetooth не принимает — для него используйте Wi-Fi.';

  @override
  String get codeReceiveTitle => 'Получить файл';

  @override
  String get codeReceivePrompt => 'Введите код с устройства отправителя';

  @override
  String get codeReceiveCodeInvalid => 'Введите все десять цифр кода.';

  @override
  String get codeReceiveHint => '12345 67890';

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
  String get codeReceiveTransferFailed => 'Передача не удалась';

  @override
  String get codeReceiveTryAnother => 'Попробовать другой код';

  @override
  String get codeReceiveUpdateRequired =>
      'На другом устройстве установлена другая версия DirectDrop, и оно не может принять этот код. Обновите DirectDrop на обоих устройствах и повторите попытку.';

  @override
  String get codeReceiveNotFound =>
      'Отправитель не найден. Проверьте код: он меняется каждые 5 минут. Для локальной сети оба устройства должны быть в одной сети.';

  @override
  String get codeReceiveSearching => 'Ищем отправителя…';

  @override
  String get codeReceiveAwaitingApproval =>
      'Ждём подтверждения на устройстве отправителя…';

  @override
  String get codeReceiveNoNetwork =>
      'Нет связи с интернет-сервисом, а в локальной сети отправитель не найден. Проверьте подключение и код и повторите попытку.';

  @override
  String get codeCopied => 'Код скопирован';

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
  String get inviteDeclined => 'Отклонено';

  @override
  String get inviteUnreachable => 'Не удалось связаться с устройством';

  @override
  String get codeLabel => 'Код для принимающего устройства';

  @override
  String get codeEnterPrompt => 'Введите код с устройства-отправителя';

  @override
  String get codeEnterHint => '10 цифр';

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
  String get errorSenderTooOldForDirectLink =>
      'На отправляющем устройстве старая версия DirectDrop: она не может договориться о передаче с этой версией. Обновите DirectDrop на отправляющем устройстве и отсканируйте его новый код.';

  @override
  String get errorBluetoothOff =>
      'Bluetooth выключен. Включите его и попробуйте ещё раз.';

  @override
  String get errorBluetoothPermissionDenied =>
      'DirectDrop нужно разрешение на поиск устройств поблизости, чтобы стать видимым по Bluetooth. Разрешите его в настройках и попробуйте ещё раз.';

  @override
  String get errorBluetoothSendUnsupported =>
      'Bluetooth этого устройства не умеет показываться другим устройствам, поэтому отправить по Bluetooth отсюда нельзя. Используйте Wi-Fi или интернет.';

  @override
  String get errorBluetoothAdvertiseFailed =>
      'Bluetooth не начал делать это устройство видимым. Выключите и снова включите Bluetooth, затем попробуйте ещё раз.';

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
      'На принимающем устройстве старая версия DirectDrop: она не может договориться о передаче с этой версией. Обновите её, и передача пойдёт по прямой связи Wi-Fi.';

  @override
  String get errorReceiverTooOldToPair =>
      'На принимающем устройстве старая версия: она не умеет безопасно соединяться по Bluetooth. Обновите её или отправьте по Wi-Fi.';

  @override
  String get errorCancelledHere => 'Вы отменили передачу.';

  @override
  String get errorOfferEnded =>
      'Предложение слишком долго оставалось без ответа и было закрыто. Начните отправку заново.';

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
  String get errorNoPathRelayLimited =>
      'Не удалось соединиться: устройства не видят друг друга напрямую, а сервис реле сейчас ограничивает запросы. Попробуйте ещё раз примерно через минуту.';

  @override
  String get errorNoPathRelayUnreachable =>
      'Не удалось соединиться: устройства не видят друг друга напрямую, а сервис реле недоступен. Проверьте подключение к интернету.';

  @override
  String get errorNoPathRelayOff =>
      'Не удалось соединиться: устройства не видят друг друга напрямую, а реле в этой сборке выключено или не настроено.';

  @override
  String get errorNoPathRelayWasAvailable =>
      'Соединиться не удалось, хотя реле было доступно. Что-то между устройствами блокирует связь — например, VPN или фаервол.';

  @override
  String get errorNotEnoughSpace =>
      'Для этой передачи не хватает свободного места. Освободите место там, куда сохраняются файлы, и попробуйте ещё раз.';

  @override
  String errorNotEnoughSpaceDetail(String needed, String available) {
    return 'Не хватает свободного места: нужно $needed, доступно $available. Освободите место там, куда сохраняются файлы, и попробуйте ещё раз.';
  }

  @override
  String get errorDiskFull =>
      'Диск заполнился во время сохранения. Освободите место и попробуйте ещё раз.';

  @override
  String get errorUnsafeDestination =>
      'В папке сохранения на месте файла или папки стоит ярлык (символическая ссылка), поэтому ничего не было записано. Удалите его или выберите другую папку.';

  @override
  String get errorPathTooLong =>
      'Место сохранения вложено слишком глубоко — Windows не сможет открыть файлы по такому длинному пути. Выберите папку ближе к корню диска.';

  @override
  String get errorReceivedFilesNotIntact =>
      'Часть полученных файлов пропала или изменилась до конца передачи, поэтому передача не считается завершённой. Попробуйте ещё раз — заново будет получено только недостающее.';

  @override
  String get qrDisplayStillCounting => 'Считаем файлы…';
}
