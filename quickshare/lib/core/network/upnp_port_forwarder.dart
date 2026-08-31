import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class PortMappingResult {
  final bool success;
  final String? publicIp;
  final int? externalPort;
  final String method;
  final String? error;

  const PortMappingResult({
    required this.success,
    this.publicIp,
    this.externalPort,
    required this.method,
    this.error,
  });

  @override
  String toString() =>
      'PortMappingResult(success: $success, method: $method, publicIp: $publicIp, port: $externalPort, error: $error)';
}

class UpnpDeviceInfo {
  final String controlUrl;
  final String serviceType;
  const UpnpDeviceInfo({required this.controlUrl, required this.serviceType});
}

/// Real native UPnP (SSDP/SOAP IGD) and NAT-PMP port forwarding client.
/// Automatically maps public router ports to local ports without any external servers.
class UpnpPortForwarder {
  static const String _ssdpIp = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const int _natPmpPort = 5351;

  /// Preferred lease, in seconds. A mapping that outlives the process is a
  /// hole in the user's router that nothing will ever close — and the previous
  /// code asked for exactly that (`NewLeaseDuration` of 0 means permanent)
  /// while never calling DeletePortMapping anywhere. A finite lease means a
  /// crash costs an hour rather than forever; [releaseAll] closes it sooner in
  /// the normal case.
  static const int _leaseSeconds = 3600;

  /// Mappings this instance created and is responsible for removing.
  final List<({UpnpDeviceInfo device, int externalPort})> _activeMappings = [];

  /// True when there is something to clean up.
  bool get hasActiveMappings => _activeMappings.isNotEmpty;

  /// Attempts to map [internalPort] on the local router using UPnP IGD or NAT-PMP.
  Future<PortMappingResult> forwardPort({
    required int internalPort,
    int? externalPort,
    String description = 'DirectDrop',
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final port = externalPort ?? internalPort;

    // 1. Try UPnP IGD (SSDP + SOAP WANIPConnection / WANPPPConnection v1 & v2)
    try {
      final upnpRes = await _tryUpnp(
        internalPort: internalPort,
        externalPort: port,
        description: description,
        timeout: timeout,
      );
      if (upnpRes.success) return upnpRes;
    } catch (e) {
      debugPrint('UPnP discovery error: $e');
    }

    // 2. Try NAT-PMP (UDP Port 5351 to Default Gateway)
    try {
      final natPmpRes = await _tryNatPmp(
        internalPort: internalPort,
        externalPort: port,
        timeout: timeout,
      );
      if (natPmpRes.success) return natPmpRes;
    } catch (e) {
      debugPrint('NAT-PMP error: $e');
    }

    return const PortMappingResult(
      success: false,
      method: 'none',
      error: 'UPnP and NAT-PMP port mapping unavailable on this network router',
    );
  }

  Future<PortMappingResult> _tryUpnp({
    required int internalPort,
    required int externalPort,
    required String description,
    required Duration timeout,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      const mSearch = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n\r\n';

      final data = utf8.encode(mSearch);
      socket.send(data, InternetAddress(_ssdpIp), _ssdpPort);

      final completer = Completer<String?>();
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            final response = utf8.decode(datagram.data);
            final locationHeader =
                RegExp(r'LOCATION:\s*(.+)', caseSensitive: false)
                    .firstMatch(response)
                    ?.group(1)
                    ?.trim();
            if (locationHeader != null && !completer.isCompleted) {
              completer.complete(locationHeader);
            }
          }
        }
      });

      final locationUrl = await completer.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      socket.close();

      if (locationUrl == null) {
        return const PortMappingResult(
          success: false,
          method: 'upnp',
          error: 'No UPnP IGD router response received',
        );
      }

      // Fetch UPnP XML Control URL & Dynamic Service Type (WANIPConnection:1, WANPPPConnection:1, etc.)
      final deviceInfo = await _parseUpnpDeviceInfo(locationUrl);
      if (deviceInfo == null) {
        return const PortMappingResult(
          success: false,
          method: 'upnp',
          error:
              'Could not parse UPnP control URL or serviceType from router XML',
        );
      }

      // Get local IP
      final localIp = await _getLocalIpForTarget(locationUrl);
      if (localIp == null) {
        return const PortMappingResult(
          success: false,
          method: 'upnp',
          error: 'Could not determine local IP for UPnP mapping',
        );
      }

      // Send SOAP AddPortMapping request with dynamic serviceType
      final soapSuccess = await _sendSoapAddPortMapping(
        deviceInfo: deviceInfo,
        localIp: localIp,
        internalPort: internalPort,
        externalPort: externalPort,
        description: description,
      );

      if (soapSuccess) {
        _activeMappings.add((device: deviceInfo, externalPort: externalPort));
        final publicIp = await _getUpnpExternalIp(deviceInfo);
        return PortMappingResult(
          success: true,
          method: 'upnp',
          publicIp: publicIp,
          externalPort: externalPort,
        );
      }
    } catch (e) {
      socket?.close();
      return PortMappingResult(
        success: false,
        method: 'upnp',
        error: 'UPnP mapping failed: $e',
      );
    }

    return const PortMappingResult(
      success: false,
      method: 'upnp',
      error: 'UPnP SOAP AddPortMapping failed',
    );
  }

  Future<UpnpDeviceInfo?> _parseUpnpDeviceInfo(String locationUrl) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse(locationUrl));
      final res = await req.close();
      if (res.statusCode == 200) {
        final xml = await res.transform(utf8.decoder).join();

        final serviceMatch = RegExp(
          r'<serviceType>(urn:schemas-upnp-org:service:WAN(?:IP|PPP)Connection:\d+)</serviceType>',
          caseSensitive: false,
        ).firstMatch(xml);

        final controlMatch = RegExp(
          r'<controlURL>(.*?)</controlURL>',
          caseSensitive: false,
        ).firstMatch(xml);

        if (controlMatch != null) {
          final serviceType = serviceMatch?.group(1) ??
              'urn:schemas-upnp-org:service:WANIPConnection:1';
          final relPath = controlMatch.group(1)!.trim();
          final baseUri = Uri.parse(locationUrl);
          final controlUrl = baseUri.resolve(relPath).toString();
          return UpnpDeviceInfo(
              controlUrl: controlUrl, serviceType: serviceType);
        }
      }
    } catch (_) {
    } finally {
      client.close();
    }
    return null;
  }

  Future<bool> _sendSoapAddPortMapping({
    required UpnpDeviceInfo deviceInfo,
    required String localIp,
    required int internalPort,
    required int externalPort,
    required String description,
  }) async {
    // Only ever a finite lease. Some IGDs answer 725
    // OnlyPermanentLeasesSupported and this returns false — the transfer then
    // falls back to a relay or fails cleanly, which is the right outcome. The
    // old code fell back to `NewLeaseDuration` of 0 (a permanent mapping) and
    // never called DeletePortMapping, so a crash left the router open forever.
    // A visible failure beats an invisible hole.
    final ok = await _addPortMapping(
        deviceInfo: deviceInfo,
        localIp: localIp,
        internalPort: internalPort,
        externalPort: externalPort,
        description: description,
        leaseSeconds: _leaseSeconds);
    if (!ok) {
      debugPrint('UPnP: router refused a ${_leaseSeconds}s lease for '
          '$externalPort -> $localIp:$internalPort; not forwarding rather '
          'than asking for a permanent mapping');
    }
    return ok;
  }

  Future<bool> _addPortMapping({
    required UpnpDeviceInfo deviceInfo,
    required String localIp,
    required int internalPort,
    required int externalPort,
    required String description,
    required int leaseSeconds,
  }) async {
    final body = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:AddPortMapping xmlns:u="${deviceInfo.serviceType}">
<NewRemoteHost></NewRemoteHost>
<NewExternalPort>$externalPort</NewExternalPort>
<NewProtocol>TCP</NewProtocol>
<NewInternalPort>$internalPort</NewInternalPort>
<NewInternalClient>$localIp</NewInternalClient>
<NewEnabled>1</NewEnabled>
<NewPortMappingDescription>$description</NewPortMappingDescription>
<NewLeaseDuration>$leaseSeconds</NewLeaseDuration>
</u:AddPortMapping>
</s:Body>
</s:Envelope>''';

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse(deviceInfo.controlUrl);
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers
          .set('SOAPAction', '"${deviceInfo.serviceType}#AddPortMapping"');
      req.add(utf8.encode(body));
      final res = await req.close();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Removes every mapping this instance created.
  ///
  /// Best effort by design: a router that has already dropped the mapping, or
  /// that went away with the network, is not an error the caller can act on.
  /// Returns the number of mappings the router confirmed removing.
  Future<int> releaseAll() async {
    if (_activeMappings.isEmpty) return 0;
    final pending = List.of(_activeMappings);
    _activeMappings.clear();

    var removed = 0;
    for (final mapping in pending) {
      if (await _sendSoapDeletePortMapping(
          deviceInfo: mapping.device, externalPort: mapping.externalPort)) {
        removed++;
      } else {
        debugPrint('UPnP: router did not confirm removing external port '
            '${mapping.externalPort}');
      }
    }
    return removed;
  }

  Future<bool> _sendSoapDeletePortMapping({
    required UpnpDeviceInfo deviceInfo,
    required int externalPort,
  }) async {
    final body = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:DeletePortMapping xmlns:u="${deviceInfo.serviceType}">
<NewRemoteHost></NewRemoteHost>
<NewExternalPort>$externalPort</NewExternalPort>
<NewProtocol>TCP</NewProtocol>
</u:DeletePortMapping>
</s:Body>
</s:Envelope>''';

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.postUrl(Uri.parse(deviceInfo.controlUrl));
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers
          .set('SOAPAction', '"${deviceInfo.serviceType}#DeletePortMapping"');
      req.add(utf8.encode(body));
      final res = await req.close();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  Future<String?> _getUpnpExternalIp(UpnpDeviceInfo deviceInfo) async {
    final body = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:GetExternalIPAddress xmlns:u="${deviceInfo.serviceType}">
</u:GetExternalIPAddress>
</s:Body>
</s:Envelope>''';

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse(deviceInfo.controlUrl);
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set(
          'SOAPAction', '"${deviceInfo.serviceType}#GetExternalIPAddress"');
      req.add(utf8.encode(body));
      final res = await req.close();
      if (res.statusCode == 200) {
        final xml = await res.transform(utf8.decoder).join();
        final match =
            RegExp(r'<NewExternalIPAddress>(.*?)</NewExternalIPAddress>')
                .firstMatch(xml);
        return match?.group(1)?.trim();
      }
    } catch (_) {
    } finally {
      client.close();
    }
    return null;
  }

  Future<PortMappingResult> _tryNatPmp({
    required int internalPort,
    required int externalPort,
    required Duration timeout,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      // NAT-PMP TCP Port Mapping Request packet (12 bytes)
      // Byte 0: Vers (0)
      // Byte 1: OP Code (2 = TCP)
      // Byte 2-3: Reserved (0)
      // Byte 4-5: Internal Port
      // Byte 6-7: External Port
      // Byte 8-11: Lifetime (3600s)
      final requestBytes = ByteData(12);
      requestBytes.setUint8(0, 0); // Vers 0
      requestBytes.setUint8(1, 2); // OP 2 (TCP)
      requestBytes.setUint16(2, 0); // Reserved
      requestBytes.setUint16(4, internalPort);
      requestBytes.setUint16(6, externalPort);
      requestBytes.setUint32(8, 3600); // 1 hour lease

      // Send to multicast gateway 224.0.0.1 on UDP 5351
      socket.send(requestBytes.buffer.asUint8List(),
          InternetAddress('224.0.0.1'), _natPmpPort);

      final completer = Completer<PortMappingResult>();
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null && datagram.data.length >= 12) {
            final data = ByteData.sublistView(datagram.data);
            final resOp = data.getUint8(1);
            final resultCode = data.getUint16(3);
            final mappedPort = data.getUint16(8);
            if ((resOp == 130 || resOp == 2) && resultCode == 0) {
              if (!completer.isCompleted) {
                completer.complete(PortMappingResult(
                  success: true,
                  method: 'nat-pmp',
                  externalPort: mappedPort,
                  publicIp: datagram.address.address,
                ));
              }
            }
          }
        }
      });

      final result = await completer.future.timeout(
        timeout,
        onTimeout: () => const PortMappingResult(
          success: false,
          method: 'nat-pmp',
          error: 'NAT-PMP gateway response timeout',
        ),
      );
      socket.close();
      return result;
    } catch (e) {
      socket?.close();
      return PortMappingResult(
        success: false,
        method: 'nat-pmp',
        error: 'NAT-PMP request failed: $e',
      );
    }
  }

  Future<String?> _getLocalIpForTarget(String targetUrl) async {
    try {
      final uri = Uri.parse(targetUrl);
      final socket = await Socket.connect(uri.host, uri.port,
          timeout: const Duration(seconds: 2));
      final localIp = socket.address.address;
      await socket.close();
      return localIp;
    } catch (_) {
      return null;
    }
  }
}
