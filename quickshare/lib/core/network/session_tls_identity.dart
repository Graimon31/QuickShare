import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// A throwaway TLS identity for one local-network transfer.
///
/// The Wi-Fi/LAN server used to speak plain HTTP: the bearer token and every
/// byte of the file crossed the network in the clear, so anyone able to see
/// the traffic on a shared network — an open café Wi-Fi, a WPA2 network whose
/// password is on the wall — could read both. Trust could not live in the
/// channel because the channel was public.
///
/// It lives in the QR code instead, the way the serverless WebRTC path
/// already anchors trust in a seed the QR carries. The sender generates a
/// fresh self-signed certificate per session, serves HTTPS with it, and puts
/// [fingerprint] — a SHA-256 of the whole certificate — in the QR. The
/// receiver pins exactly that: no certificate authority, no hostname check,
/// just "is this the certificate the QR promised". A per-session certificate
/// is never reissued, so pinning the certificate rather than its public key
/// costs nothing and covers the lot.
///
/// The key is ECDSA P-256. Generation is a few tens of milliseconds — an
/// RSA-2048 key would be closer to a second and would have to be hidden
/// behind the file picker.
class SessionTlsIdentity {
  SessionTlsIdentity._({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprint,
  });

  /// The certificate, PEM-encoded — for [securityContext] and for tests.
  final String certificatePem;

  /// The private key, PEM-encoded.
  final String privateKeyPem;

  /// `base64url(sha256(certificate DER))`, no padding — what rides in the QR
  /// and what the receiver pins. 43 characters.
  final String fingerprint;

  SecurityContext? _context;

  /// A server context carrying this identity. Built once, reused.
  SecurityContext get securityContext => _context ??= SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

  /// Generates a fresh identity. A few tens of milliseconds on a phone.
  static SessionTlsIdentity generate() {
    final sw = Stopwatch()..start();
    final pair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;

    const dn = {'CN': 'quickshare.local'};
    final csrPem = X509Utils.generateEccCsrPem(dn, priv, pub);

    // Back-dated for clock skew between two devices that never synced with
    // each other; a day is far longer than any transfer and short enough that
    // a leaked key is worthless by tomorrow.
    final notBefore =
        DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final certificatePem = X509Utils.generateSelfSignedCertificate(
      priv,
      csrPem,
      1, // days from notBefore
      notBefore: notBefore,
      sans: const ['quickshare.local'],
    );
    final privateKeyPem = CryptoUtils.encodeEcPrivateKeyToPem(priv);
    final fingerprint = fingerprintOf(pemToDer(certificatePem));

    AppLogger.info(
        'Session TLS identity: P-256 in ${sw.elapsedMilliseconds}ms, '
        'fingerprint $fingerprint',
        tag: 'TLS');
    return SessionTlsIdentity._(
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
      fingerprint: fingerprint,
    );
  }

  /// The DER bytes inside a PEM block.
  static Uint8List pemToDer(String pem) {
    final body = pem
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    return base64.decode(body);
  }

  /// The pinned form of a certificate's DER bytes.
  static String fingerprintOf(List<int> der) =>
      base64Url.encode(sha256.convert(der).bytes).replaceAll('=', '');

  /// Whether [certificate], as offered during a TLS handshake, is the one
  /// [expectedFingerprint] (from the QR) pins to.
  ///
  /// This is the entire trust decision on the receiver: no chain, no CN, no
  /// system roots. Use it as a `badCertificateCallback` — the certificate is
  /// self-signed and will always be "bad" to the platform.
  static bool matches(X509Certificate certificate, String expectedFingerprint) {
    if (expectedFingerprint.isEmpty) return false;
    return fingerprintOf(certificate.der) == expectedFingerprint;
  }
}
