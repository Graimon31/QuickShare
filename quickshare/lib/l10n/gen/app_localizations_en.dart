// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'DirectDrop';

  @override
  String get appTagline =>
      'Share files instantly over Wi-Fi, Bluetooth,\nor by link over the internet';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonClear => 'Clear';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDone => 'Done';

  @override
  String get commonOpen => 'Open';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonSettings => 'Settings';

  @override
  String get commonChange => 'Change';

  @override
  String get commonOk => 'OK';

  @override
  String get homeSendTitle => 'Send File';

  @override
  String get homeSendSubtitle => 'Select and share a file';

  @override
  String get homeReceiveTitle => 'Receive File';

  @override
  String get homeReceiveSubtitleDesktop => 'Paste a code or share link';

  @override
  String get homeReceiveSubtitleMobile => 'Scan a QR code to download';

  @override
  String get homeDropHere => 'Drop file here to send';

  @override
  String get homeSettingsTooltip => 'Settings';

  @override
  String get errorOops => 'Oops!';

  @override
  String get errorGoHome => 'Go Home';

  @override
  String get pickerTitle => 'Send File or Folder';

  @override
  String get pickerIndexing => 'Indexing selection…';

  @override
  String get pickerStartingSession => 'Starting a secure peer-to-peer session';

  @override
  String get pickerStepMethod => '1. Select Transfer Method';

  @override
  String get pickerMethodWifiTitle => 'Wi-Fi / Local Network';

  @override
  String get pickerMethodWifiSubtitle => 'Fast transfer over local Wi-Fi / LAN';

  @override
  String get pickerMethodBluetoothTitle => 'Bluetooth';

  @override
  String get pickerMethodBluetoothSubtitle =>
      'Direct peer transfer via Bluetooth';

  @override
  String get pickerMethodInternetTitle => 'Internet Link';

  @override
  String get pickerMethodInternetSubtitle =>
      'Share link via WebRTC signaling server';

  @override
  String get pickerStepWhat => '2. Choose What to Share';

  @override
  String get pickerPhotosVideos => 'Photos & Videos';

  @override
  String get pickerSelectFile => 'Select File';

  @override
  String get pickerSelectFolder => 'Select Folder';

  @override
  String get wifiPromptTitle => 'Turn on Wi-Fi to send faster?';

  @override
  String get wifiPromptBody =>
      'Bluetooth on its own is slow — a large video can take hours.\n\nWith Wi-Fi switched on, the two devices connect directly and the same files take seconds. You do not need to join a network: the radio just has to be on.';

  @override
  String get wifiPromptDecline => 'Send over Bluetooth';

  @override
  String get wifiPromptAccept => 'Open settings';

  @override
  String get completeSaving => 'Saving…';

  @override
  String completeAndMore(int count) {
    return 'and $count more';
  }

  @override
  String get completeTitle => 'Received!';

  @override
  String get completeWhereTo => 'Where should these go?';

  @override
  String get completeSaveOne => 'Save to device';

  @override
  String completeSaveMany(int count) {
    return 'Save $count files to device';
  }

  @override
  String get completeReceiveAnother => 'Receive Another';

  @override
  String get completeDontSave => 'Don\'t save';

  @override
  String completeSavedCount(int count) {
    return '$count saved';
  }

  @override
  String completeWaitingCount(int count) {
    return '$count waiting for you';
  }

  @override
  String completeFailedCount(int count) {
    return '$count could not be saved';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsStorage => 'Storage';

  @override
  String get settingsCache => 'Cache';

  @override
  String get settingsCacheMeasuring => 'Measuring…';

  @override
  String get settingsCacheDescription =>
      'Incoming transfers are held here until you save them. Anything you do not save is removed automatically when you leave the transfer.';

  @override
  String get settingsClearCacheTitle => 'Clear cache?';

  @override
  String get settingsClearCacheBody =>
      'Anything received but not yet saved will be deleted. Files you already saved to this device are not affected.';

  @override
  String settingsCacheFreed(String size) {
    return 'Freed $size';
  }

  @override
  String get settingsCacheNothingToClear => 'Nothing to clear';

  @override
  String get settingsSaveLocation => 'Save location';

  @override
  String get settingsSaveLocationDefault => 'Default for this device';

  @override
  String get settingsSaveLocationDefaultSubtitle =>
      'The Downloads folder this platform normally uses';

  @override
  String get settingsSaveLocationCustomSubtitle =>
      'Received files are saved here';

  @override
  String get settingsSaveLocationReading => 'Reading…';

  @override
  String get settingsSaveLocationUseDefault => 'Use the default folder instead';

  @override
  String get settingsSaveLocationFootnote =>
      'Only files DirectDrop saves automatically go here — a photo on a phone still goes to the gallery, and anything this app asks you about still goes wherever you choose at the time.';

  @override
  String get settingsSaveLocationPickerTitle =>
      'Where should received files go?';

  @override
  String settingsSaveLocationError(String error) {
    return 'Could not use that folder: $error';
  }

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsLanguageRussian => 'Русский';

  @override
  String get settingsLanguageFootnote =>
      'Changes the interface immediately, on this device only.';

  @override
  String get settingsLastTransfers => 'Last transfers';

  @override
  String get settingsNoTransfersYet => 'No transfers yet';

  @override
  String get settingsNoTransfersYetSubtitle =>
      'A transfer appears here once it finishes.';

  @override
  String get settingsCopyDetails => 'Copy details';

  @override
  String get settingsDetailsCopied => 'Details copied';

  @override
  String get settingsLogs => 'Logs';

  @override
  String get settingsLogsSubtitle => 'Technical journal — copy it when reporting a transfer problem';

  @override
  String get logsCopyAll => 'Copy entire log';

  @override
  String get logsEmpty => 'No entries yet';

  @override
  String get settingsTransferFootnote =>
      'The route explains the speed. A direct link is the fastest, a relayed internet transfer the slowest — copy the details if you are asking someone for help.';

  @override
  String get commonSend => 'Send';

  @override
  String get commonCopy => 'Copy';

  @override
  String get commonNo => 'No';

  @override
  String get commonYes => 'Yes';

  @override
  String get commonOpenSettings => 'Open Settings';

  @override
  String get commonUnknownError => 'Unknown error';

  @override
  String get transferFileReceived => 'File received';

  @override
  String sharedItemsCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String mediaSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get mediaNotStored =>
      'These items are not stored on this device — open them in Photos once so they download, then try again.';

  @override
  String mediaSkippedICloud(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items are',
      one: '1 item is',
    );
    return '$_temp0 only in iCloud and were skipped.';
  }

  @override
  String get mediaAccessDeniedTitle =>
      'DirectDrop has no access to your photos';

  @override
  String get mediaAccessDeniedBody =>
      'Grant access in Settings to send photos and videos.';

  @override
  String get mediaEmptyTitle => 'Nothing here yet';

  @override
  String get mediaLimitedBody => 'Only some photos are shared with DirectDrop.';

  @override
  String get mediaEmptyBody => 'This device has no photos or videos.';

  @override
  String get mediaChooseMore => 'Choose more';

  @override
  String get mediaLimitedBanner => 'You have shared only some photos.';

  @override
  String get mediaManage => 'Manage';

  @override
  String get qrDisplayTitle => 'Share File';

  @override
  String get qrDisplayPreparing => 'Preparing share…';

  @override
  String get qrDisplayPreparingDetail => 'Generating a secure QR session';

  @override
  String get qrDisplayScanOrShare => 'Scan the QR or share the link';

  @override
  String get qrDisplayShareLinkToReceive =>
      'Share this link to receive the file';

  @override
  String get qrDisplayScanToReceive => 'Scan this QR code to receive the file';

  @override
  String get qrDisplayPhoneHint =>
      'On the phone: open DirectDrop → Receive and scan this QR.\nThe Wi‑Fi line below is only for diagnostics — it is NOT the QR content.';

  @override
  String qrDisplayRenderError(String error) {
    return 'QR Render Error: $error';
  }

  @override
  String get qrDisplayShareLinkLabel => 'Share link';

  @override
  String get qrDisplayLinkCopied => 'Link copied to clipboard';

  @override
  String get qrDisplayWifiAddressLabel => 'Sender Wi‑Fi address';

  @override
  String get qrDisplayWifiAddressCopied => 'Wi‑Fi address copied';

  @override
  String qrDisplayTotalSize(String size) {
    return 'Total size: $size';
  }

  @override
  String qrDisplaySessionExpires(String time) {
    return 'Session expires in $time';
  }

  @override
  String get qrDisplayCancelTransfer => 'Cancel Transfer';

  @override
  String get senderProgressCancelTitle => 'Cancel Transfer?';

  @override
  String get senderProgressCancelBody =>
      'Are you sure you want to stop sending this file?';

  @override
  String get senderProgressCancelConfirm => 'Yes, Cancel';

  @override
  String get senderProgressTitle => 'Transferring File';

  @override
  String get senderProgressCompleteTitle => 'Transfer Complete!';

  @override
  String get senderProgressSendAnother => 'Send Another File';

  @override
  String get senderProgressSending => 'Sending...';

  @override
  String get senderProgressFailed => 'Transfer failed';

  @override
  String get senderProgressPreparing => 'Preparing transfer…';

  @override
  String get fallbackTooLargeTitle => 'Too large for this connection';

  @override
  String get fallbackNoRouteTitle => 'No direct route to the other device';

  @override
  String fallbackTooLargeBody(String size) {
    return 'The only route available goes through a public relay. $size would take a long time and would not reliably finish, so nothing has been sent yet.';
  }

  @override
  String get fallbackNoRouteBody =>
      'A VPN or this network\'s NAT is blocking a direct connection, and no relay was reachable. Nothing has been sent yet.';

  @override
  String get fallbackWifiTitle => 'Put both devices on one network';

  @override
  String get fallbackWifiBody =>
      'The local transfer has no size limit and runs at full link speed. This phone can create that network itself if there is no router around.';

  @override
  String get fallbackVpnTitle => 'Or turn the VPN off for the transfer';

  @override
  String get fallbackVpnBody =>
      'A VPN that captures the default route prevents the two devices from finding each other directly.';

  @override
  String get fallbackCreateNetwork => 'Create a network for this transfer';

  @override
  String get fallbackGoBack => 'Go back and pick another method';

  @override
  String fallbackRelayCap(String size) {
    return 'Relay transfers are capped at $size.';
  }

  @override
  String get localNetTitle => 'Local network';

  @override
  String get localNetCreating => 'Creating the network…';

  @override
  String get localNetWorking => 'Working…';

  @override
  String get localNetStep1Title => 'Scan this with the other phone\'s camera';

  @override
  String get localNetStep1Subtitle =>
      'It joins the network. No app needed for this step.';

  @override
  String get localNetNetworkLabel => 'Network';

  @override
  String get localNetPasswordLabel => 'Password';

  @override
  String get localNetNoInternetNote =>
      'This network has no internet — it exists only to carry the transfer.';

  @override
  String get localNetJoinedButton => 'Done, it is connected';

  @override
  String get localNetStep2Title => 'Now scan this one in the app';

  @override
  String localNetStep2Subtitle(String host) {
    return 'It points at the files on $host.';
  }

  @override
  String get btSendTitle => 'Bluetooth';

  @override
  String get btSendPreparing => 'Preparing Bluetooth…';

  @override
  String get btSendPreparingDetail => 'Making this device discoverable';

  @override
  String get btSendScanPrompt => 'Scan this QR code on the receiving device';

  @override
  String get btSendAutoConnectNote =>
      'The receiving device will connect over Bluetooth and start the transfer automatically.';

  @override
  String get btReceiveLookingForLink => 'Looking for a direct link…';

  @override
  String get btReceiveDirectLinkPlaceholder => 'Receiving over direct Wi-Fi';

  @override
  String get btReceiveTitle => 'Nearby devices';

  @override
  String get btReceiveLookingNearby => 'Looking for nearby Macs…';

  @override
  String get btReceiveLookingQr => 'Looking for the Mac from the QR code…';

  @override
  String get btReceiveScanning => 'Scanning for nearby devices…';

  @override
  String get btReceiveScanningDetail =>
      'Keep Bluetooth enabled on both devices';

  @override
  String get btReceiveConnecting => 'Connecting over Bluetooth…';

  @override
  String btReceivePairingWith(String name) {
    return 'Pairing with $name';
  }

  @override
  String get btReceiveConnectionFailed => 'Connection failed';

  @override
  String get btReceiveScanAgain => 'Scan again';

  @override
  String get codeReceivePasteError => 'Paste the share link from the sender.';

  @override
  String get codeReceiveParseError =>
      'Could not read that link. Copy the share link under the QR on the sender.';

  @override
  String get codeReceiveTitle => 'Receive a file';

  @override
  String get codeReceivePastePrompt => 'Paste a code or share link';

  @override
  String get codeReceiveHint => 'directdrop://join?p=…';

  @override
  String get codeReceivePasteButton => 'Paste';

  @override
  String get codeReceiveReceiveButton => 'Receive';

  @override
  String get codeReceiveFileFound => 'File found';

  @override
  String get codeReceiveIncomingTransfer => 'Incoming transfer';

  @override
  String get codeReceiveSizeUnknown => 'Size unknown until the transfer starts';

  @override
  String get codeReceiveDownloadButton => 'Download';

  @override
  String get codeReceiveConnecting => 'Connecting to sender…';

  @override
  String get codeReceiveConnectingDetail =>
      'Keep the Mac on the Share screen. Same Wi‑Fi required for local signaling; LTE needs a public signaling + TURN server.';

  @override
  String get codeReceiveTransferFailed => 'Transfer failed';

  @override
  String codeReceiveSignalingError(String url) {
    return 'Signaling server unreachable ($url). Specify a remote server using:\n--dart-define=QUICKSHARE_SIGNALING_URL=wss://your-server.com';
  }

  @override
  String get codeReceiveTryAnother => 'Try another code';

  @override
  String get qrScanCameraPermission => 'Camera permission required';

  @override
  String get qrScanDetected => 'QR detected — opening transfer…';

  @override
  String qrScanCameraError(String code) {
    return 'Camera error: $code\nTry closing and opening Receive again.';
  }

  @override
  String get qrScanEnterCode => 'Enter Code';

  @override
  String get qrScanPointCamera => 'Point camera at the QR code';

  @override
  String get qrScanPreparingCamera => 'Preparing camera…';

  @override
  String get qrScanPreparingDetail => 'Camera access is being initialized';

  @override
  String get downloadWakelockWarning =>
      'Keep the screen on and the app open until the transfer finishes.';

  @override
  String get downloadCancelTitle => 'Cancel Download?';

  @override
  String get downloadTitle => 'Downloading...';

  @override
  String get downloadConnecting => 'Connecting to sender…';

  @override
  String get downloadConnectingDetail => 'Preparing a secure transfer channel';

  @override
  String get downloadVerifying => 'Verifying transfer…';

  @override
  String get downloadVerifyingDetail => 'Checking file integrity';

  @override
  String get downloadPreparing => 'Preparing download…';

  @override
  String get downloadPreparingDetail => 'Waiting for the sender';

  @override
  String get previewReadyTitle => 'Ready to Receive';

  @override
  String get previewFolderTransfer => 'Folder Transfer';

  @override
  String previewFolderSize(String size) {
    return 'Folder size: $size';
  }

  @override
  String get previewCalculatingSize => 'Calculating size…';

  @override
  String get previewStarting => 'Starting file transfer…';

  @override
  String get previewStartNow => 'Start Now';
}
