abstract class Either<L, R> {
  const Either();

  B fold<B>(B Function(L l) ifLeft, B Function(R r) ifRight);

  bool get isLeft => this is Left<L, R>;
  bool get isRight => this is Right<L, R>;

  Either<L, B> map<B>(B Function(R r) f) {
    return fold(
      (l) => Left<L, B>(l),
      (r) => Right<L, B>(f(r)),
    );
  }

  Either<L, B> flatMap<B>(Either<L, B> Function(R r) f) {
    return fold(
      (l) => Left<L, B>(l),
      (r) => f(r),
    );
  }
}

class Left<L, R> extends Either<L, R> {
  final L value;

  const Left(this.value);

  @override
  B fold<B>(B Function(L l) ifLeft, B Function(R r) ifRight) {
    return ifLeft(value);
  }
}

class Right<L, R> extends Either<L, R> {
  final R value;

  const Right(this.value);

  @override
  B fold<B>(B Function(L l) ifLeft, B Function(R r) ifRight) {
    return ifRight(value);
  }
}
