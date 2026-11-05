// What a session code used to be turned into, kept so a test can search for it.
//
// Until the network's name and passphrase became random, both were SHA-256 of
// the code's ten digits with a purpose in front, read off by the same
// arithmetic at both ends. That is gone from the app; the arithmetic lives here
// so that the tests that say "nothing the code derives is on the air" can still
// run the search an eavesdropper would — and show, on the old values, that the
// search finds the code, which is what makes finding nothing mean something.
import 'dart:convert';

import 'package:crypto/crypto.dart';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String _derived(String code, String purpose, int chars) {
  final bytes = sha256.convert(utf8.encode('directdrop/$purpose/$code')).bytes;
  return [for (var i = 0; i < chars; i++) _alphabet[bytes[i] % _alphabet.length]]
      .join();
}

/// The network a ten-digit [code] used to name: `DirectDrop-` and six
/// characters, and a twelve-character passphrase.
({String ssid, String passphrase}) legacyNetworkOf(String code) => (
      ssid: 'DirectDrop-${_derived(code, 'ssid', 6)}',
      passphrase: _derived(code, 'psk', 12),
    );

/// Every ten-digit code that starts with [firstFiveDigits], in order: a hundred
/// thousand of the ten billion, as many as a test can search in a moment. The
/// answer is the same as for all of them, only the haystack is smaller.
Iterable<String> codesStartingWith(String firstFiveDigits) sync* {
  for (var i = 0; i < 100000; i++) {
    yield '$firstFiveDigits${i.toString().padLeft(5, '0')}';
  }
}

/// The codes in the haystack whose old network name is [ssid].
///
/// For a name the old scheme made, this is the code and, by chance, almost never
/// anything else: the name is thirty bits and the haystack seventeen. For a name
/// it did not make, it is nothing.
List<String> codesNamingNetwork(String ssid, String firstFiveDigits) => [
      for (final code in codesStartingWith(firstFiveDigits))
        if (legacyNetworkOf(code).ssid == ssid) code,
    ];
