import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// HKDF with SHA-256 (RFC 5869), extract and expand in one call.
///
/// Synchronous on purpose: the callers derive a few dozen bytes once per
/// handshake, and `package:cryptography`'s version is asynchronous for no
/// benefit here. Pinned by the RFC's own test case in
/// `test/core/crypto/hkdf_test.dart`.
Uint8List hkdfSha256(
  List<int> ikm, {
  List<int> salt = const [],
  List<int> info = const [],
  required int length,
}) {
  const hashLength = 32;
  if (length < 0 || length > 255 * hashLength) {
    throw ArgumentError.value(length, 'length', 'out of range for HKDF-SHA256');
  }
  // RFC 5869 §2.2: an absent salt is a string of zeros as long as the hash.
  final prk = Hmac(sha256, salt.isEmpty ? Uint8List(hashLength) : salt)
      .convert(ikm)
      .bytes;
  final okm = BytesBuilder(copy: false);
  var previous = const <int>[];
  for (var counter = 1; okm.length < length; counter++) {
    previous = Hmac(sha256, prk)
        .convert([...previous, ...info, counter])
        .bytes;
    okm.add(previous);
  }
  return Uint8List.fromList(okm.takeBytes().sublist(0, length));
}
