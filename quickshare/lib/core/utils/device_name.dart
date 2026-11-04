import 'dart:io';

/// What this machine is called, for the one place a name is still shown: the
/// approval dialog on the sender, and the preview on the receiver.
///
/// It is sent only inside an authenticated exchange — after a receiver has
/// proved the code, or to a sender whose certificate was pinned — and is never
/// put on the network for anyone to read.
///
/// `Platform.localHostname` is what the user named their machine, which is
/// what a person recognises. Trailing `.local` comes off because Bonjour puts
/// it there and nobody thinks of it as part of the name. A phone rarely has a
/// useful hostname, so those fall back to the platform.
String describeThisDevice() {
  try {
    final host = Platform.localHostname.trim();
    if (host.isNotEmpty && !Platform.isAndroid && !Platform.isIOS) {
      return host.replaceFirst(RegExp(r'\.local\.?$'), '');
    }
  } catch (_) {
    // Some sandboxes refuse the hostname. The platform name still tells the
    // other side something.
  }
  switch (Platform.operatingSystem) {
    case 'android':
      return 'Android device';
    case 'ios':
      return 'iPhone';
    case 'macos':
      return 'Mac';
    case 'windows':
      return 'Windows PC';
    case 'linux':
      return 'Linux PC';
    default:
      return 'Device';
  }
}
