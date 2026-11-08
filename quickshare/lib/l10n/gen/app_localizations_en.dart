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
      'Share files instantly\nover the internet or directly';

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
  String get homeInternetTitle => 'Over the internet';

  @override
  String get homeInternetSubtitle => 'Works from any network';

  @override
  String get homeAirdropTitle => 'AirDrop';

  @override
  String get homeAirdropSubtitle => 'For devices close to you';

  @override
  String get homeLocalNetworkTitle => 'Local network transfer';

  @override
  String get homeLocalNetworkSubtitle => 'Both devices on the same network';

  @override
  String homeAirdropAltTitle(String airdrop) {
    return '$airdrop alternative';
  }

  @override
  String get homeAirdropAltSubtitle =>
      'To a device close by, no shared network needed';

  @override
  String get homeReceiveTitle => 'Receive File';

  @override
  String get homeReceiveSubtitleDesktop => 'Enter the code from the sender';

  @override
  String get homeReceiveSubtitleMobile =>
      'Scan a QR code or enter the sender\'s code';

  @override
  String get homeDropHere => 'Drop file here to send';

  @override
  String get homeSettingsTooltip => 'Settings';

  @override
  String get errorOops => 'Oops!';

  @override
  String get errorGoHome => 'Go Home';

  @override
  String get pickerIndexing => 'Indexing selection…';

  @override
  String get pickerStartingSession => 'Starting a secure peer-to-peer session';

  @override
  String get pickerStepWhat => 'Choose What to Share';

  @override
  String get pickerPhotosVideos => 'Photos & Videos';

  @override
  String get pickerSelectFile => 'Select File';

  @override
  String get pickerSelectFolder => 'Select Folder';

  @override
  String get pickerSendMedia => 'Send Photos & Videos';

  @override
  String get pickerSendFiles => 'Send Files';

  @override
  String get pickerSendFilesHint =>
      'Files and folders — pick as many as you like';

  @override
  String pickerIndexingFound(int count, String size) {
    return 'Found $count · $size';
  }

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
  String settingsTransferPeerSent(String address) {
    return 'Sent to $address';
  }

  @override
  String settingsTransferPeerReceived(String address) {
    return 'Connected to $address';
  }

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
  String get qrDisplayScanOrEnterCode => 'Scan the QR or enter the code';

  @override
  String offerCodeChangesIn(String time) {
    return 'Code and QR change in $time';
  }

  @override
  String offerQrChangesIn(String time) {
    return 'QR code changes in $time';
  }

  @override
  String get qrDisplayScanToReceive => 'Scan this QR code to receive the file';

  @override
  String get qrDisplayPhoneHint =>
      'On the other device: open DirectDrop → Receive. A phone scans this QR; a computer types the code.';

  @override
  String qrDisplayRenderError(String error) {
    return 'QR Render Error: $error';
  }

  @override
  String qrDisplayTotalSize(String size) {
    return 'Total size: $size';
  }

  @override
  String get qrDisplayCancelTransfer => 'Cancel Transfer';

  @override
  String get precondWifiTitle => 'Turn on Wi-Fi';

  @override
  String get precondWifiBody =>
      'Local network transfer needs the Wi-Fi module to be on.';

  @override
  String get precondBluetoothTitle => 'Turn on Bluetooth';

  @override
  String get precondBluetoothBody =>
      'Bluetooth transfer needs the Bluetooth module to be on.';

  @override
  String get precondOpenSettings => 'Open Settings';

  @override
  String get precondOpenAppSettings => 'Open app settings';

  @override
  String get precondWifiBodyApple =>
      'Local network transfer needs Wi-Fi. iOS lets no app open the Wi-Fi pane, so switch it on yourself in Settings › Wi-Fi. If Wi-Fi is already on, the app may be missing Local Network access — that one is in its own settings page.';

  @override
  String get precondWifiBlocked =>
      'Transfer is unavailable until Wi-Fi is turned on.';

  @override
  String get precondBluetoothBlocked =>
      'Transfer is unavailable until Bluetooth is turned on.';

  @override
  String get precondBluetoothNeedsWifi => 'Bluetooth transfer needs Wi-Fi on';

  @override
  String get precondBluetoothNeedsWifiBody =>
      'The file itself crosses a direct Wi-Fi link between the two devices — Bluetooth only finds them. Switch Wi-Fi on; you do not need to join a network.';

  @override
  String get precondBluetoothNeedsWifiBodyApple =>
      'The file itself crosses a direct Wi-Fi link between the two devices — Bluetooth only finds them. iOS lets no app open the Wi-Fi pane, so switch it on yourself in Settings › Wi-Fi. You do not need to join a network.';

  @override
  String get precondBluetoothWifiBlocked =>
      'Bluetooth transfer is unavailable until Wi-Fi is turned on.';

  @override
  String get precondInternetBlocked =>
      'No active network connection. Internet transfer is unavailable.';

  @override
  String get sessionRefresh => 'Refresh';

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
      'A VPN or this network\'s NAT is blocking a direct connection. Nothing has been sent yet.';

  @override
  String get fallbackNoRouteBodyRelayLimited =>
      'No direct connection was possible, and the relay service is limiting requests right now, so no relay could be set up. Try again in about a minute. Nothing has been sent yet.';

  @override
  String get fallbackNoRouteBodyRelayUnreachable =>
      'No direct connection was possible, and the relay service could not be reached, so no relay could be set up. Check this device\'s internet connection. Nothing has been sent yet.';

  @override
  String get fallbackNoRouteBodyRelayOff =>
      'No direct connection was possible, and the relay is switched off or not configured in this build. Nothing has been sent yet.';

  @override
  String get fallbackNoRouteBodyRelayWasAvailable =>
      'A relay was available, but the connection still could not be made. A VPN or firewall may be blocking even relayed traffic. Nothing has been sent yet.';

  @override
  String get fallbackWifiTitle => 'Put both devices on one network';

  @override
  String get fallbackWifiBody =>
      'The local transfer has no size limit and runs at full link speed.';

  @override
  String get fallbackWifiBodyCanHost =>
      'The local transfer has no size limit and runs at full link speed. This device can create that network itself if there is no router around.';

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
  String get btSendPreparingDetail =>
      'Preparing a QR and numeric code for the receiver';

  @override
  String get btSendScanPrompt => 'Scan the QR or enter the numeric code';

  @override
  String get btSendAutoConnectNote =>
      'Open DirectDrop on the receiving device and choose Receive file. Scan the QR or enter the code manually. Enable Bluetooth on both devices and keep them nearby.';

  @override
  String get codeReceiveTitle => 'Receive a file';

  @override
  String get codeReceivePrompt => 'Enter the code from the sender';

  @override
  String get codeReceiveCodeInvalid => 'Enter all ten digits of the code.';

  @override
  String get codeReceiveHint => '12345 67890';

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
  String get codeReceiveTransferFailed => 'Transfer failed';

  @override
  String get codeReceiveTryAnother => 'Try another code';

  @override
  String get codeReceiveUpdateRequired =>
      'The other device is running a different version of DirectDrop and cannot take this code. Update DirectDrop on both devices, then try again.';

  @override
  String get codeReceiveNotFound =>
      'Sender not found. Check the code: it changes every 5 minutes. For Nearby transfer, enable Bluetooth and keep devices nearby. For local network transfer, connect both devices to the same network.';

  @override
  String get codeReceiveSearching => 'Looking for the sender…';

  @override
  String get codeReceiveAwaitingApproval =>
      'Waiting for the sender to confirm…';

  @override
  String get codeReceiveNoNetwork =>
      'No sender found over Bluetooth or the local network, and the internet service is unavailable. Check the code, Bluetooth and your connection.';

  @override
  String get codeCopied => 'Code copied to clipboard';

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
  String get downloadErrorSenderUnreachable =>
      'Lost the connection to the sender. It may have cancelled, closed the app, or lost Wi-Fi. Ask them to start the transfer again.';

  @override
  String get downloadErrorCancelledBySender =>
      'The sender cancelled the transfer.';

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
  String get previewConfirmPrompt => 'Accept this transfer?';

  @override
  String get previewStartNow => 'Start Now';

  @override
  String get settingsLogs => 'Logs';

  @override
  String get settingsLogsSubtitle =>
      'Technical journal — copy it when reporting a transfer problem';

  @override
  String get logsCopyAll => 'Copy entire log';

  @override
  String get logsEmpty => 'No entries yet';

  @override
  String get inviteTitle => 'Accept files?';

  @override
  String get inviteAccept => 'Accept';

  @override
  String get inviteDecline => 'Decline';

  @override
  String get inviteUnknownSize => 'size unknown';

  @override
  String inviteApprovalBody(
      String deviceName, String address, int itemCount, String size) {
    String _temp0 = intl.Intl.pluralLogic(
      itemCount,
      locale: localeName,
      other: '$itemCount files',
      one: '1 file',
    );
    return '$deviceName$address wants to receive $_temp0 ($size).';
  }

  @override
  String inviteApprovalExpiresIn(int seconds) {
    return 'Request expires in ${seconds}s';
  }

  @override
  String previewSenderLabel(String sender) {
    return 'From $sender';
  }

  @override
  String get inviteDeclined => 'Declined';

  @override
  String get inviteUnreachable => 'Could not reach that device';

  @override
  String get codeLabel => 'Code for the receiving device';

  @override
  String get codeEnterPrompt => 'Enter the code from the sender';

  @override
  String get codeEnterHint => '10 digits';

  @override
  String get codeMalformed => 'A code is 10 digits';

  @override
  String get routeDirectWifiLink => 'Direct Wi-Fi link';

  @override
  String get routeLocalNetwork => 'Local network';

  @override
  String get routeInternetDirect => 'Internet (direct, same network)';

  @override
  String get routeInternetPeerToPeer => 'Internet (peer to peer)';

  @override
  String get routeInternetRelayed => 'Internet (relayed)';

  @override
  String get routeBluetooth => 'Bluetooth';

  @override
  String get routeUnknown => 'Unknown route';

  @override
  String settingsTransferSent(String size, int seconds) {
    return 'Sent $size in ${seconds}s';
  }

  @override
  String settingsTransferReceived(String size, int seconds) {
    return 'Received $size in ${seconds}s';
  }

  @override
  String get errorTransferFailedUnexpectedly =>
      'The transfer stopped before it finished, and the connection did not say why. Try again, and if it keeps happening put both devices on the same network.';

  @override
  String get errorBluetoothStartFailed =>
      'Could not start sharing over Bluetooth.';

  @override
  String get errorBluetoothTransferFailed =>
      'The Bluetooth transfer stopped before it finished.';

  @override
  String get errorSenderTooOldForDirectLink =>
      'The sending device is on an older version of DirectDrop that cannot set up the transfer with this one. Update DirectDrop on the sending device and scan its new code.';

  @override
  String get errorBluetoothOff =>
      'Bluetooth is turned off. Turn it on and try again.';

  @override
  String get errorBluetoothPermissionDenied =>
      'DirectDrop needs permission to find nearby devices before it can make this device visible over Bluetooth. Allow it in Settings and try again.';

  @override
  String get errorBluetoothSendUnsupported =>
      'This device\'s Bluetooth cannot make itself visible to other devices, so it cannot send over Bluetooth. Use Wi-Fi or the internet instead.';

  @override
  String get errorBluetoothAdvertiseFailed =>
      'Bluetooth did not start making this device visible. Switch Bluetooth off and on, then try again.';

  @override
  String get errorInternetStartFailed =>
      'Could not start the transfer over the internet.';

  @override
  String get errorNothingSelected => 'Nothing is selected to send.';

  @override
  String get errorSelectionUnreadable => 'Could not read what you selected.';

  @override
  String get errorNetworkCreateFailed =>
      'Could not create a network on this device.';

  @override
  String get errorNetworkWithoutAddress =>
      'The network came up but never got an address, so there is nothing to point the other device at.';

  @override
  String get errorNothingToRestart =>
      'There is nothing left to restart — choose the files again.';

  @override
  String get errorReceiverTooOldForDirectLink =>
      'The receiving device is on an older version of DirectDrop that cannot set up the transfer with this one. Update it, and the transfer moves to a direct Wi-Fi link.';

  @override
  String get errorReceiverTooOldToPair =>
      'The receiving device is on an older version that cannot pair securely over Bluetooth. Update it, or send over Wi-Fi.';

  @override
  String get errorCancelledHere => 'You cancelled the transfer.';

  @override
  String get errorOfferEnded =>
      'This offer sat unused for too long and was closed. Start sending again.';

  @override
  String get errorLinkWifiOff =>
      'Wi-Fi is turned off. The transfer builds a direct Wi-Fi link between the devices, so it cannot start without it.';

  @override
  String get errorLinkPeerSilentAtSetup =>
      'The other device did not answer the setup for a private link. Make sure it is running the current version and try again.';

  @override
  String get errorLinkSetupFailed =>
      'Could not set up the direct Wi-Fi link. Keep the devices next to each other and try again.';

  @override
  String get errorLinkPeerLost =>
      'Lost contact with the other device before the link was set up. Stay on this screen and try again.';

  @override
  String get errorLinkWithoutAddress =>
      'The link is up, but this device could not work out its own address on it.';

  @override
  String get errorSessionWithoutCertificate =>
      'The transfer started without a certificate, so the other device has nothing to trust. Try again.';

  @override
  String get errorNoPathRelayLimited =>
      'Could not connect: the two devices cannot reach each other directly, and the relay service is limiting requests right now. Try again in about a minute.';

  @override
  String get errorNoPathRelayUnreachable =>
      'Could not connect: the two devices cannot reach each other directly, and the relay service could not be reached. Check the internet connection.';

  @override
  String get errorNoPathRelayOff =>
      'Could not connect: the two devices cannot reach each other directly, and the relay is switched off or not configured in this build.';

  @override
  String get errorNoPathRelayWasAvailable =>
      'Could not connect even though a relay was available. Something between the devices is blocking the connection — a VPN or a firewall, for example.';

  @override
  String get errorNotEnoughSpace =>
      'There is not enough free space for this transfer. Free up some space where the files are being saved and try again.';

  @override
  String errorNotEnoughSpaceDetail(String needed, String available) {
    return 'Not enough free space: $needed needed, $available available. Free up some space where the files are being saved and try again.';
  }

  @override
  String get errorDiskFull =>
      'The disk filled up while saving. Free up some space and try again.';

  @override
  String get errorUnsafeDestination =>
      'The save folder has a shortcut (a symbolic link) where a file or folder should be, so nothing was written there. Remove it, or choose another save folder.';

  @override
  String get errorPathTooLong =>
      'The save location is nested too deeply — Windows cannot open files at a path this long. Choose a folder closer to the root of the drive.';

  @override
  String get errorReceivedFilesNotIntact =>
      'Some received files went missing or changed before the transfer finished, so it is not reported as complete. Try again — only what is missing will be received again.';

  @override
  String get qrDisplayStillCounting => 'Still counting the files…';

  @override
  String get errorCancelledByReceiver => 'The receiver cancelled the transfer.';

  @override
  String get errorConnectionLostNotRecovered =>
      'The connection was lost during the transfer and could not be restored after several attempts. Send again; nothing is reported as received that did not arrive whole.';

  @override
  String get errorConnectionLostPeerTooOld =>
      'The connection was lost, and the other device runs an older version of DirectDrop that cannot continue an interrupted transfer. Update the app on that device and send again.';

  @override
  String get errorIntegrityMismatch =>
      'A file arrived damaged: its checksum (SHA-256) does not match the original, so it was discarded and the transfer is not reported as complete. Send again.';

  @override
  String get transferReconnecting => 'Connection lost, reconnecting…';

  @override
  String get transferReconnectingHint =>
      'What was already transferred is kept. The transfer will continue from where it stopped.';
}
