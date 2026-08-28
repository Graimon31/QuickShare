import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru')
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'DirectDrop'**
  String get appName;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'Share files instantly over Wi-Fi, Bluetooth,\nor by link over the internet'**
  String get appTagline;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get commonClear;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get commonDone;

  /// No description provided for @commonOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get commonOpen;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get commonSettings;

  /// No description provided for @commonChange.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get commonChange;

  /// No description provided for @commonOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get commonOk;

  /// No description provided for @homeSendTitle.
  ///
  /// In en, this message translates to:
  /// **'Send File'**
  String get homeSendTitle;

  /// No description provided for @homeSendSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select and share a file'**
  String get homeSendSubtitle;

  /// No description provided for @homeReceiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Receive File'**
  String get homeReceiveTitle;

  /// No description provided for @homeReceiveSubtitleDesktop.
  ///
  /// In en, this message translates to:
  /// **'Paste a code or share link'**
  String get homeReceiveSubtitleDesktop;

  /// No description provided for @homeReceiveSubtitleMobile.
  ///
  /// In en, this message translates to:
  /// **'Scan a QR code to download'**
  String get homeReceiveSubtitleMobile;

  /// No description provided for @homeDropHere.
  ///
  /// In en, this message translates to:
  /// **'Drop file here to send'**
  String get homeDropHere;

  /// No description provided for @homeSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get homeSettingsTooltip;

  /// No description provided for @errorOops.
  ///
  /// In en, this message translates to:
  /// **'Oops!'**
  String get errorOops;

  /// No description provided for @errorGoHome.
  ///
  /// In en, this message translates to:
  /// **'Go Home'**
  String get errorGoHome;

  /// No description provided for @pickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Send File or Folder'**
  String get pickerTitle;

  /// No description provided for @pickerIndexing.
  ///
  /// In en, this message translates to:
  /// **'Indexing selection…'**
  String get pickerIndexing;

  /// No description provided for @pickerStartingSession.
  ///
  /// In en, this message translates to:
  /// **'Starting a secure peer-to-peer session'**
  String get pickerStartingSession;

  /// No description provided for @pickerStepMethod.
  ///
  /// In en, this message translates to:
  /// **'1. Select Transfer Method'**
  String get pickerStepMethod;

  /// No description provided for @pickerMethodWifiTitle.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi / Local Network'**
  String get pickerMethodWifiTitle;

  /// No description provided for @pickerMethodWifiSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Fast transfer over local Wi-Fi / LAN'**
  String get pickerMethodWifiSubtitle;

  /// No description provided for @pickerMethodBluetoothTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get pickerMethodBluetoothTitle;

  /// No description provided for @pickerMethodBluetoothSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Direct peer transfer via Bluetooth'**
  String get pickerMethodBluetoothSubtitle;

  /// No description provided for @pickerMethodInternetTitle.
  ///
  /// In en, this message translates to:
  /// **'Internet Link'**
  String get pickerMethodInternetTitle;

  /// No description provided for @pickerMethodInternetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Share link via WebRTC signaling server'**
  String get pickerMethodInternetSubtitle;

  /// No description provided for @pickerStepWhat.
  ///
  /// In en, this message translates to:
  /// **'2. Choose What to Share'**
  String get pickerStepWhat;

  /// No description provided for @pickerPhotosVideos.
  ///
  /// In en, this message translates to:
  /// **'Photos & Videos'**
  String get pickerPhotosVideos;

  /// No description provided for @pickerSelectFile.
  ///
  /// In en, this message translates to:
  /// **'Select File'**
  String get pickerSelectFile;

  /// No description provided for @pickerSelectFolder.
  ///
  /// In en, this message translates to:
  /// **'Select Folder'**
  String get pickerSelectFolder;

  /// No description provided for @wifiPromptTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on Wi-Fi to send faster?'**
  String get wifiPromptTitle;

  /// No description provided for @wifiPromptBody.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth on its own is slow — a large video can take hours.\n\nWith Wi-Fi switched on, the two devices connect directly and the same files take seconds. You do not need to join a network: the radio just has to be on.'**
  String get wifiPromptBody;

  /// No description provided for @wifiPromptDecline.
  ///
  /// In en, this message translates to:
  /// **'Send over Bluetooth'**
  String get wifiPromptDecline;

  /// No description provided for @wifiPromptAccept.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get wifiPromptAccept;

  /// No description provided for @completeSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get completeSaving;

  /// No description provided for @completeAndMore.
  ///
  /// In en, this message translates to:
  /// **'and {count} more'**
  String completeAndMore(int count);

  /// No description provided for @completeTitle.
  ///
  /// In en, this message translates to:
  /// **'Received!'**
  String get completeTitle;

  /// No description provided for @completeWhereTo.
  ///
  /// In en, this message translates to:
  /// **'Where should these go?'**
  String get completeWhereTo;

  /// No description provided for @completeSaveOne.
  ///
  /// In en, this message translates to:
  /// **'Save to device'**
  String get completeSaveOne;

  /// No description provided for @completeSaveMany.
  ///
  /// In en, this message translates to:
  /// **'Save {count} files to device'**
  String completeSaveMany(int count);

  /// No description provided for @completeReceiveAnother.
  ///
  /// In en, this message translates to:
  /// **'Receive Another'**
  String get completeReceiveAnother;

  /// No description provided for @completeDontSave.
  ///
  /// In en, this message translates to:
  /// **'Don\'t save'**
  String get completeDontSave;

  /// No description provided for @completeSavedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} saved'**
  String completeSavedCount(int count);

  /// No description provided for @completeWaitingCount.
  ///
  /// In en, this message translates to:
  /// **'{count} waiting for you'**
  String completeWaitingCount(int count);

  /// No description provided for @completeFailedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} could not be saved'**
  String completeFailedCount(int count);

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get settingsStorage;

  /// No description provided for @settingsCache.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get settingsCache;

  /// No description provided for @settingsCacheMeasuring.
  ///
  /// In en, this message translates to:
  /// **'Measuring…'**
  String get settingsCacheMeasuring;

  /// No description provided for @settingsCacheDescription.
  ///
  /// In en, this message translates to:
  /// **'Incoming transfers are held here until you save them. Anything you do not save is removed automatically when you leave the transfer.'**
  String get settingsCacheDescription;

  /// No description provided for @settingsClearCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear cache?'**
  String get settingsClearCacheTitle;

  /// No description provided for @settingsClearCacheBody.
  ///
  /// In en, this message translates to:
  /// **'Anything received but not yet saved will be deleted. Files you already saved to this device are not affected.'**
  String get settingsClearCacheBody;

  /// No description provided for @settingsCacheFreed.
  ///
  /// In en, this message translates to:
  /// **'Freed {size}'**
  String settingsCacheFreed(String size);

  /// No description provided for @settingsCacheNothingToClear.
  ///
  /// In en, this message translates to:
  /// **'Nothing to clear'**
  String get settingsCacheNothingToClear;

  /// No description provided for @settingsSaveLocation.
  ///
  /// In en, this message translates to:
  /// **'Save location'**
  String get settingsSaveLocation;

  /// No description provided for @settingsSaveLocationDefault.
  ///
  /// In en, this message translates to:
  /// **'Default for this device'**
  String get settingsSaveLocationDefault;

  /// No description provided for @settingsSaveLocationDefaultSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The Downloads folder this platform normally uses'**
  String get settingsSaveLocationDefaultSubtitle;

  /// No description provided for @settingsSaveLocationCustomSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Received files are saved here'**
  String get settingsSaveLocationCustomSubtitle;

  /// No description provided for @settingsSaveLocationReading.
  ///
  /// In en, this message translates to:
  /// **'Reading…'**
  String get settingsSaveLocationReading;

  /// No description provided for @settingsSaveLocationUseDefault.
  ///
  /// In en, this message translates to:
  /// **'Use the default folder instead'**
  String get settingsSaveLocationUseDefault;

  /// No description provided for @settingsSaveLocationFootnote.
  ///
  /// In en, this message translates to:
  /// **'Only files DirectDrop saves automatically go here — a photo on a phone still goes to the gallery, and anything this app asks you about still goes wherever you choose at the time.'**
  String get settingsSaveLocationFootnote;

  /// No description provided for @settingsSaveLocationPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Where should received files go?'**
  String get settingsSaveLocationPickerTitle;

  /// No description provided for @settingsSaveLocationError.
  ///
  /// In en, this message translates to:
  /// **'Could not use that folder: {error}'**
  String settingsSaveLocationError(String error);

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get settingsLanguageEnglish;

  /// No description provided for @settingsLanguageRussian.
  ///
  /// In en, this message translates to:
  /// **'Русский'**
  String get settingsLanguageRussian;

  /// No description provided for @settingsLanguageFootnote.
  ///
  /// In en, this message translates to:
  /// **'Changes the interface immediately, on this device only.'**
  String get settingsLanguageFootnote;

  /// No description provided for @settingsLastTransfers.
  ///
  /// In en, this message translates to:
  /// **'Last transfers'**
  String get settingsLastTransfers;

  /// No description provided for @settingsNoTransfersYet.
  ///
  /// In en, this message translates to:
  /// **'No transfers yet'**
  String get settingsNoTransfersYet;

  /// No description provided for @settingsNoTransfersYetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A transfer appears here once it finishes.'**
  String get settingsNoTransfersYetSubtitle;

  /// No description provided for @settingsCopyDetails.
  ///
  /// In en, this message translates to:
  /// **'Copy details'**
  String get settingsCopyDetails;

  /// No description provided for @settingsDetailsCopied.
  ///
  /// In en, this message translates to:
  /// **'Details copied'**
  String get settingsDetailsCopied;

  /// No description provided for @settingsTransferFootnote.
  ///
  /// In en, this message translates to:
  /// **'The route explains the speed. A direct link is the fastest, a relayed internet transfer the slowest — copy the details if you are asking someone for help.'**
  String get settingsTransferFootnote;

  /// No description provided for @commonSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get commonSend;

  /// No description provided for @commonCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get commonCopy;

  /// No description provided for @commonNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get commonNo;

  /// No description provided for @commonYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get commonYes;

  /// No description provided for @commonOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get commonOpenSettings;

  /// No description provided for @commonUnknownError.
  ///
  /// In en, this message translates to:
  /// **'Unknown error'**
  String get commonUnknownError;

  /// No description provided for @transferFileReceived.
  ///
  /// In en, this message translates to:
  /// **'File received'**
  String get transferFileReceived;

  /// No description provided for @sharedItemsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file} other{{count} files}}'**
  String sharedItemsCount(num count);

  /// No description provided for @mediaSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String mediaSelectedCount(int count);

  /// No description provided for @mediaNotStored.
  ///
  /// In en, this message translates to:
  /// **'These items are not stored on this device — open them in Photos once so they download, then try again.'**
  String get mediaNotStored;

  /// No description provided for @mediaSkippedICloud.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item is} other{{count} items are}} only in iCloud and were skipped.'**
  String mediaSkippedICloud(num count);

  /// No description provided for @mediaAccessDeniedTitle.
  ///
  /// In en, this message translates to:
  /// **'DirectDrop has no access to your photos'**
  String get mediaAccessDeniedTitle;

  /// No description provided for @mediaAccessDeniedBody.
  ///
  /// In en, this message translates to:
  /// **'Grant access in Settings to send photos and videos.'**
  String get mediaAccessDeniedBody;

  /// No description provided for @mediaEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get mediaEmptyTitle;

  /// No description provided for @mediaLimitedBody.
  ///
  /// In en, this message translates to:
  /// **'Only some photos are shared with DirectDrop.'**
  String get mediaLimitedBody;

  /// No description provided for @mediaEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'This device has no photos or videos.'**
  String get mediaEmptyBody;

  /// No description provided for @mediaChooseMore.
  ///
  /// In en, this message translates to:
  /// **'Choose more'**
  String get mediaChooseMore;

  /// No description provided for @mediaLimitedBanner.
  ///
  /// In en, this message translates to:
  /// **'You have shared only some photos.'**
  String get mediaLimitedBanner;

  /// No description provided for @mediaManage.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get mediaManage;

  /// No description provided for @qrDisplayTitle.
  ///
  /// In en, this message translates to:
  /// **'Share File'**
  String get qrDisplayTitle;

  /// No description provided for @qrDisplayPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing share…'**
  String get qrDisplayPreparing;

  /// No description provided for @qrDisplayPreparingDetail.
  ///
  /// In en, this message translates to:
  /// **'Generating a secure QR session'**
  String get qrDisplayPreparingDetail;

  /// No description provided for @qrDisplayScanOrShare.
  ///
  /// In en, this message translates to:
  /// **'Scan the QR or share the link'**
  String get qrDisplayScanOrShare;

  /// No description provided for @qrDisplayShareLinkToReceive.
  ///
  /// In en, this message translates to:
  /// **'Share this link to receive the file'**
  String get qrDisplayShareLinkToReceive;

  /// No description provided for @qrDisplayScanToReceive.
  ///
  /// In en, this message translates to:
  /// **'Scan this QR code to receive the file'**
  String get qrDisplayScanToReceive;

  /// No description provided for @qrDisplayPhoneHint.
  ///
  /// In en, this message translates to:
  /// **'On the phone: open DirectDrop → Receive and scan this QR.\nThe Wi‑Fi line below is only for diagnostics — it is NOT the QR content.'**
  String get qrDisplayPhoneHint;

  /// No description provided for @qrDisplayRenderError.
  ///
  /// In en, this message translates to:
  /// **'QR Render Error: {error}'**
  String qrDisplayRenderError(String error);

  /// No description provided for @qrDisplayShareLinkLabel.
  ///
  /// In en, this message translates to:
  /// **'Share link'**
  String get qrDisplayShareLinkLabel;

  /// No description provided for @qrDisplayLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied to clipboard'**
  String get qrDisplayLinkCopied;

  /// No description provided for @qrDisplayWifiAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'Sender Wi‑Fi address'**
  String get qrDisplayWifiAddressLabel;

  /// No description provided for @qrDisplayWifiAddressCopied.
  ///
  /// In en, this message translates to:
  /// **'Wi‑Fi address copied'**
  String get qrDisplayWifiAddressCopied;

  /// No description provided for @qrDisplayTotalSize.
  ///
  /// In en, this message translates to:
  /// **'Total size: {size}'**
  String qrDisplayTotalSize(String size);

  /// No description provided for @qrDisplaySessionExpires.
  ///
  /// In en, this message translates to:
  /// **'Session expires in {time}'**
  String qrDisplaySessionExpires(String time);

  /// No description provided for @qrDisplayCancelTransfer.
  ///
  /// In en, this message translates to:
  /// **'Cancel Transfer'**
  String get qrDisplayCancelTransfer;

  /// No description provided for @senderProgressCancelTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel Transfer?'**
  String get senderProgressCancelTitle;

  /// No description provided for @senderProgressCancelBody.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to stop sending this file?'**
  String get senderProgressCancelBody;

  /// No description provided for @senderProgressCancelConfirm.
  ///
  /// In en, this message translates to:
  /// **'Yes, Cancel'**
  String get senderProgressCancelConfirm;

  /// No description provided for @senderProgressTitle.
  ///
  /// In en, this message translates to:
  /// **'Transferring File'**
  String get senderProgressTitle;

  /// No description provided for @senderProgressCompleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Transfer Complete!'**
  String get senderProgressCompleteTitle;

  /// No description provided for @senderProgressSendAnother.
  ///
  /// In en, this message translates to:
  /// **'Send Another File'**
  String get senderProgressSendAnother;

  /// No description provided for @senderProgressSending.
  ///
  /// In en, this message translates to:
  /// **'Sending...'**
  String get senderProgressSending;

  /// No description provided for @senderProgressFailed.
  ///
  /// In en, this message translates to:
  /// **'Transfer failed'**
  String get senderProgressFailed;

  /// No description provided for @senderProgressPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing transfer…'**
  String get senderProgressPreparing;

  /// No description provided for @fallbackTooLargeTitle.
  ///
  /// In en, this message translates to:
  /// **'Too large for this connection'**
  String get fallbackTooLargeTitle;

  /// No description provided for @fallbackNoRouteTitle.
  ///
  /// In en, this message translates to:
  /// **'No direct route to the other device'**
  String get fallbackNoRouteTitle;

  /// No description provided for @fallbackTooLargeBody.
  ///
  /// In en, this message translates to:
  /// **'The only route available goes through a public relay. {size} would take a long time and would not reliably finish, so nothing has been sent yet.'**
  String fallbackTooLargeBody(String size);

  /// No description provided for @fallbackNoRouteBody.
  ///
  /// In en, this message translates to:
  /// **'A VPN or this network\'s NAT is blocking a direct connection, and no relay was reachable. Nothing has been sent yet.'**
  String get fallbackNoRouteBody;

  /// No description provided for @fallbackWifiTitle.
  ///
  /// In en, this message translates to:
  /// **'Put both devices on one network'**
  String get fallbackWifiTitle;

  /// No description provided for @fallbackWifiBody.
  ///
  /// In en, this message translates to:
  /// **'The local transfer has no size limit and runs at full link speed. This phone can create that network itself if there is no router around.'**
  String get fallbackWifiBody;

  /// No description provided for @fallbackVpnTitle.
  ///
  /// In en, this message translates to:
  /// **'Or turn the VPN off for the transfer'**
  String get fallbackVpnTitle;

  /// No description provided for @fallbackVpnBody.
  ///
  /// In en, this message translates to:
  /// **'A VPN that captures the default route prevents the two devices from finding each other directly.'**
  String get fallbackVpnBody;

  /// No description provided for @fallbackCreateNetwork.
  ///
  /// In en, this message translates to:
  /// **'Create a network for this transfer'**
  String get fallbackCreateNetwork;

  /// No description provided for @fallbackGoBack.
  ///
  /// In en, this message translates to:
  /// **'Go back and pick another method'**
  String get fallbackGoBack;

  /// No description provided for @fallbackRelayCap.
  ///
  /// In en, this message translates to:
  /// **'Relay transfers are capped at {size}.'**
  String fallbackRelayCap(String size);

  /// No description provided for @localNetTitle.
  ///
  /// In en, this message translates to:
  /// **'Local network'**
  String get localNetTitle;

  /// No description provided for @localNetCreating.
  ///
  /// In en, this message translates to:
  /// **'Creating the network…'**
  String get localNetCreating;

  /// No description provided for @localNetWorking.
  ///
  /// In en, this message translates to:
  /// **'Working…'**
  String get localNetWorking;

  /// No description provided for @localNetStep1Title.
  ///
  /// In en, this message translates to:
  /// **'Scan this with the other phone\'s camera'**
  String get localNetStep1Title;

  /// No description provided for @localNetStep1Subtitle.
  ///
  /// In en, this message translates to:
  /// **'It joins the network. No app needed for this step.'**
  String get localNetStep1Subtitle;

  /// No description provided for @localNetNetworkLabel.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get localNetNetworkLabel;

  /// No description provided for @localNetPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get localNetPasswordLabel;

  /// No description provided for @localNetNoInternetNote.
  ///
  /// In en, this message translates to:
  /// **'This network has no internet — it exists only to carry the transfer.'**
  String get localNetNoInternetNote;

  /// No description provided for @localNetJoinedButton.
  ///
  /// In en, this message translates to:
  /// **'Done, it is connected'**
  String get localNetJoinedButton;

  /// No description provided for @localNetStep2Title.
  ///
  /// In en, this message translates to:
  /// **'Now scan this one in the app'**
  String get localNetStep2Title;

  /// No description provided for @localNetStep2Subtitle.
  ///
  /// In en, this message translates to:
  /// **'It points at the files on {host}.'**
  String localNetStep2Subtitle(String host);

  /// No description provided for @btSendTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get btSendTitle;

  /// No description provided for @btSendPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing Bluetooth…'**
  String get btSendPreparing;

  /// No description provided for @btSendPreparingDetail.
  ///
  /// In en, this message translates to:
  /// **'Making this device discoverable'**
  String get btSendPreparingDetail;

  /// No description provided for @btSendScanPrompt.
  ///
  /// In en, this message translates to:
  /// **'Scan this QR code on the receiving device'**
  String get btSendScanPrompt;

  /// No description provided for @btSendAutoConnectNote.
  ///
  /// In en, this message translates to:
  /// **'The receiving device will connect over Bluetooth and start the transfer automatically.'**
  String get btSendAutoConnectNote;

  /// No description provided for @btReceiveLookingForLink.
  ///
  /// In en, this message translates to:
  /// **'Looking for a direct link…'**
  String get btReceiveLookingForLink;

  /// No description provided for @btReceiveDirectLinkPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Receiving over direct Wi-Fi'**
  String get btReceiveDirectLinkPlaceholder;

  /// No description provided for @btReceiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Nearby devices'**
  String get btReceiveTitle;

  /// No description provided for @btReceiveLookingNearby.
  ///
  /// In en, this message translates to:
  /// **'Looking for nearby Macs…'**
  String get btReceiveLookingNearby;

  /// No description provided for @btReceiveLookingQr.
  ///
  /// In en, this message translates to:
  /// **'Looking for the Mac from the QR code…'**
  String get btReceiveLookingQr;

  /// No description provided for @btReceiveScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning for nearby devices…'**
  String get btReceiveScanning;

  /// No description provided for @btReceiveScanningDetail.
  ///
  /// In en, this message translates to:
  /// **'Keep Bluetooth enabled on both devices'**
  String get btReceiveScanningDetail;

  /// No description provided for @btReceiveConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting over Bluetooth…'**
  String get btReceiveConnecting;

  /// No description provided for @btReceivePairingWith.
  ///
  /// In en, this message translates to:
  /// **'Pairing with {name}'**
  String btReceivePairingWith(String name);

  /// No description provided for @btReceiveConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get btReceiveConnectionFailed;

  /// No description provided for @btReceiveScanAgain.
  ///
  /// In en, this message translates to:
  /// **'Scan again'**
  String get btReceiveScanAgain;

  /// No description provided for @codeReceivePasteError.
  ///
  /// In en, this message translates to:
  /// **'Paste the share link from the sender.'**
  String get codeReceivePasteError;

  /// No description provided for @codeReceiveParseError.
  ///
  /// In en, this message translates to:
  /// **'Could not read that link. Copy the share link under the QR on the sender.'**
  String get codeReceiveParseError;

  /// No description provided for @codeReceiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Receive a file'**
  String get codeReceiveTitle;

  /// No description provided for @codeReceivePastePrompt.
  ///
  /// In en, this message translates to:
  /// **'Paste a code or share link'**
  String get codeReceivePastePrompt;

  /// No description provided for @codeReceiveHint.
  ///
  /// In en, this message translates to:
  /// **'directdrop://join?p=…'**
  String get codeReceiveHint;

  /// No description provided for @codeReceivePasteButton.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get codeReceivePasteButton;

  /// No description provided for @codeReceiveReceiveButton.
  ///
  /// In en, this message translates to:
  /// **'Receive'**
  String get codeReceiveReceiveButton;

  /// No description provided for @codeReceiveFileFound.
  ///
  /// In en, this message translates to:
  /// **'File found'**
  String get codeReceiveFileFound;

  /// No description provided for @codeReceiveIncomingTransfer.
  ///
  /// In en, this message translates to:
  /// **'Incoming transfer'**
  String get codeReceiveIncomingTransfer;

  /// No description provided for @codeReceiveSizeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Size unknown until the transfer starts'**
  String get codeReceiveSizeUnknown;

  /// No description provided for @codeReceiveDownloadButton.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get codeReceiveDownloadButton;

  /// No description provided for @codeReceiveConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to sender…'**
  String get codeReceiveConnecting;

  /// No description provided for @codeReceiveConnectingDetail.
  ///
  /// In en, this message translates to:
  /// **'Keep the Mac on the Share screen. Same Wi‑Fi required for local signaling; LTE needs a public signaling + TURN server.'**
  String get codeReceiveConnectingDetail;

  /// No description provided for @codeReceiveTransferFailed.
  ///
  /// In en, this message translates to:
  /// **'Transfer failed'**
  String get codeReceiveTransferFailed;

  /// No description provided for @codeReceiveSignalingError.
  ///
  /// In en, this message translates to:
  /// **'Signaling server unreachable ({url}). Specify a remote server using:\n--dart-define=QUICKSHARE_SIGNALING_URL=wss://your-server.com'**
  String codeReceiveSignalingError(String url);

  /// No description provided for @codeReceiveTryAnother.
  ///
  /// In en, this message translates to:
  /// **'Try another code'**
  String get codeReceiveTryAnother;

  /// No description provided for @qrScanCameraPermission.
  ///
  /// In en, this message translates to:
  /// **'Camera permission required'**
  String get qrScanCameraPermission;

  /// No description provided for @qrScanDetected.
  ///
  /// In en, this message translates to:
  /// **'QR detected — opening transfer…'**
  String get qrScanDetected;

  /// No description provided for @qrScanCameraError.
  ///
  /// In en, this message translates to:
  /// **'Camera error: {code}\nTry closing and opening Receive again.'**
  String qrScanCameraError(String code);

  /// No description provided for @qrScanEnterCode.
  ///
  /// In en, this message translates to:
  /// **'Enter Code'**
  String get qrScanEnterCode;

  /// No description provided for @qrScanPointCamera.
  ///
  /// In en, this message translates to:
  /// **'Point camera at the QR code'**
  String get qrScanPointCamera;

  /// No description provided for @qrScanPreparingCamera.
  ///
  /// In en, this message translates to:
  /// **'Preparing camera…'**
  String get qrScanPreparingCamera;

  /// No description provided for @qrScanPreparingDetail.
  ///
  /// In en, this message translates to:
  /// **'Camera access is being initialized'**
  String get qrScanPreparingDetail;

  /// No description provided for @downloadWakelockWarning.
  ///
  /// In en, this message translates to:
  /// **'Keep the screen on and the app open until the transfer finishes.'**
  String get downloadWakelockWarning;

  /// No description provided for @downloadCancelTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel Download?'**
  String get downloadCancelTitle;

  /// No description provided for @downloadTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloading...'**
  String get downloadTitle;

  /// No description provided for @downloadConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to sender…'**
  String get downloadConnecting;

  /// No description provided for @downloadConnectingDetail.
  ///
  /// In en, this message translates to:
  /// **'Preparing a secure transfer channel'**
  String get downloadConnectingDetail;

  /// No description provided for @downloadVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying transfer…'**
  String get downloadVerifying;

  /// No description provided for @downloadVerifyingDetail.
  ///
  /// In en, this message translates to:
  /// **'Checking file integrity'**
  String get downloadVerifyingDetail;

  /// No description provided for @downloadPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing download…'**
  String get downloadPreparing;

  /// No description provided for @downloadPreparingDetail.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the sender'**
  String get downloadPreparingDetail;

  /// No description provided for @previewReadyTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready to Receive'**
  String get previewReadyTitle;

  /// No description provided for @previewFolderTransfer.
  ///
  /// In en, this message translates to:
  /// **'Folder Transfer'**
  String get previewFolderTransfer;

  /// No description provided for @previewFolderSize.
  ///
  /// In en, this message translates to:
  /// **'Folder size: {size}'**
  String previewFolderSize(String size);

  /// No description provided for @previewCalculatingSize.
  ///
  /// In en, this message translates to:
  /// **'Calculating size…'**
  String get previewCalculatingSize;

  /// No description provided for @previewStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting file transfer…'**
  String get previewStarting;

  /// No description provided for @previewStartNow.
  ///
  /// In en, this message translates to:
  /// **'Start Now'**
  String get previewStartNow;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
