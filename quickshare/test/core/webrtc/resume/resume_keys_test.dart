// What a reconnection message is allowed to be: sealed under keys only the two
// ends of this transfer can derive, for one kind, one link and one transfer.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/webrtc/resume/resume_keys.dart';

Uint8List _seed(int fill) => Uint8List.fromList(List.filled(16, fill));
Uint8List _fingerprint(String of) =>
    Uint8List.fromList(sha256.convert(of.codeUnits).bytes);

void main() {
  final keys =
      ResumeKeys.derive(seed: _seed(7), offerFingerprint: _fingerprint('a'));
  final plain = Uint8List.fromList(List.generate(300, (i) => i % 251));

  test('what is sealed opens, as the same kind, for the same link', () async {
    final sealed = await keys.seal(
        kind: ResumeKind.offer, generation: 2, plaintext: plain);
    final opened =
        await keys.open(kind: ResumeKind.offer, envelope: sealed);
    expect(opened, isNotNull);
    expect(opened!.generation, 2);
    expect(opened.plaintext, plain);
  });

  test('the generation is readable without a key, and cannot be changed',
      () async {
    final sealed = await keys.seal(
        kind: ResumeKind.offer, generation: 3, plaintext: plain);
    expect(ResumeKeys.peekGeneration(sealed), 3);

    final lied = Uint8List.fromList(sealed);
    lied[3] = 9; // claims to be link 9
    expect(ResumeKeys.peekGeneration(lied), 9);
    expect(await keys.open(kind: ResumeKind.offer, envelope: lied), isNull,
        reason: 'the generation is part of what is authenticated');
  });

  test('an offer is not an answer, and an answer is not an offer', () async {
    final offer = await keys.seal(
        kind: ResumeKind.offer, generation: 2, plaintext: plain);
    final answer = await keys.seal(
        kind: ResumeKind.answer, generation: 2, plaintext: plain);
    expect(await keys.open(kind: ResumeKind.answer, envelope: offer), isNull);
    expect(await keys.open(kind: ResumeKind.offer, envelope: answer), isNull);
  });

  test('a stranger without the seed cannot make a message that opens',
      () async {
    final stranger = ResumeKeys.derive(
        seed: _seed(8), offerFingerprint: _fingerprint('a'));
    final forged = await stranger.seal(
        kind: ResumeKind.offer, generation: 2, plaintext: plain);
    expect(await keys.open(kind: ResumeKind.offer, envelope: forged), isNull);
  });

  test('keys belong to one transfer: the same seed under another offer is '
      'another set of keys', () async {
    final other = ResumeKeys.derive(
        seed: _seed(7), offerFingerprint: _fingerprint('b'));
    expect(other.offerTopic, isNot(keys.offerTopic));
    expect(other.answerTopic, isNot(keys.answerTopic));
    final sealed = await other.seal(
        kind: ResumeKind.offer, generation: 2, plaintext: plain);
    expect(await keys.open(kind: ResumeKind.offer, envelope: sealed), isNull);
  });

  test('the two topics differ, are the length the Worker accepts and do not '
      'show the seed', () {
    expect(keys.offerTopic, isNot(keys.answerTopic));
    expect(keys.offerTopic.length, 22);
    expect(keys.answerTopic.length, 22);
    expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(keys.offerTopic), isTrue);
  });

  test('altering any byte fails; truncating or padding fails', () async {
    final sealed = await keys.seal(
        kind: ResumeKind.answer, generation: 4, plaintext: plain);
    for (final at in [0, 4, 16, sealed.length ~/ 2, sealed.length - 1]) {
      final bent = Uint8List.fromList(sealed)..[at] ^= 0x01;
      expect(await keys.open(kind: ResumeKind.answer, envelope: bent), isNull,
          reason: 'byte $at');
    }
    expect(
        await keys.open(
            kind: ResumeKind.answer,
            envelope: Uint8List.sublistView(sealed, 0, sealed.length - 1)),
        isNull);
    expect(
        await keys.open(
            kind: ResumeKind.answer,
            envelope: Uint8List.fromList([...sealed, 0])),
        isNull);
  });

  test('an envelope too short or too long to be one is refused before any '
      'cryptography', () async {
    expect(ResumeKeys.peekGeneration(Uint8List(10)), isNull);
    expect(ResumeKeys.peekGeneration(Uint8List(ResumeKeys.maxEnvelopeBytes + 1)),
        isNull);
    expect(
        await keys.open(kind: ResumeKind.offer, envelope: Uint8List(0)), isNull);
  });

  test('the same message sealed twice is two different envelopes', () async {
    final a = await keys.seal(
        kind: ResumeKind.offer, generation: 2, plaintext: plain);
    final b = await keys.seal(
        kind: ResumeKind.offer, generation: 2, plaintext: plain);
    expect(a, isNot(b));
  });

  test('a seed or fingerprint of the wrong size is refused', () {
    expect(
        () => ResumeKeys.derive(
            seed: Uint8List(15), offerFingerprint: _fingerprint('a')),
        throwsArgumentError);
    expect(
        () => ResumeKeys.derive(
            seed: _seed(1), offerFingerprint: Uint8List(31)),
        throwsArgumentError);
  });

  test('generation 0 and one past 32 bits are not links', () async {
    expect(
        () => keys.seal(
            kind: ResumeKind.offer, generation: 0, plaintext: plain),
        throwsArgumentError);
    expect(
        () => keys.seal(
            kind: ResumeKind.offer, generation: 0x100000000, plaintext: plain),
        throwsArgumentError);
  });
}
