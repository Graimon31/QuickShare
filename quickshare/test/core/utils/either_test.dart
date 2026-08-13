import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/utils/either.dart';

void main() {
  group('Either', () {
    test('Left isLeft is true', () => expect(Left<String, int>('err').isLeft, isTrue));
    test('Right isRight is true', () => expect(Right<String, int>(42).isRight, isTrue));
    test('fold returns left value', () {
      final result = Left<String, int>('error').fold((l) => l, (r) => 'right');
      expect(result, equals('error'));
    });
    test('fold returns right value', () {
      final result = Right<String, int>(42).fold((l) => 'left', (r) => r.toString());
      expect(result, equals('42'));
    });
  });
}
