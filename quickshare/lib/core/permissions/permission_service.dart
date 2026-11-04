import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<bool> requestCamera() async {
    if (isDesktop) return true;
    return _request(Permission.camera);
  }

  /// Recheck the OS grant independently of the permission-request callback.
  /// Some Android devices deliver a grant while its request Future is still
  /// pending; the QR scanner must not sit at "Preparing camera" forever.
  Future<bool> hasCameraPermission() async {
    if (isDesktop) return true;
    return (await Permission.camera.status).isGranted;
  }

  Future<bool> requestStorage() async {
    if (isDesktop) return true;
    if (Platform.isAndroid) {
      final manageStorage = await _request(Permission.manageExternalStorage);
      if (manageStorage) return true;
      return _request(Permission.storage);
    }
    return _request(Permission.storage);
  }

  Future<bool> requestLocation() async {
    if (isDesktop) return true;
    return _request(Permission.location);
  }

  Future<bool> _request(Permission permission) async {
    final status = await permission.request();
    if (status.isGranted) {
      return true;
    } else if (status.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }
    return false;
  }
}
