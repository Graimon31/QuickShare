# Benchmarks

Not part of `flutter test` — they take minutes and print numbers rather than
asserting them. Run one deliberately:

```
flutter test benchmark/stack_layers_bench.dart
flutter test benchmark/transfer_throughput_bench.dart
```

`stack_layers_bench` measures each layer the bytes pass through, which is the
only way to tell a slow link from a slow stack. On a 2021 M1 Pro, September
2026:

| layer | throughput |
| --- | --- |
| plain TCP, loopback | 1278 MB/s |
| Dart `SecureSocket` (TLS) | 53 MB/s |
| Dart `HttpServer`/`HttpClient` over TLS | 50 MB/s |
| QHTP server serving a file (read by a raw client) | 52 MB/s |
| SHA-256, pure Dart | 103 MB/s |

Both ends run in one isolate, so each figure counts the work of both sides.
TLS is the ceiling and it is Dart's, not ours: parallel connections do not
raise it (1/2/4/8 streams all land within noise of 55 MB/s aggregate), which
says it is bound by one event loop rather than by the link.

`transfer_throughput_bench` runs a real 400 MB QHTP session over loopback:
19.6 MB/s while both ends hashed on the transfer's own isolate, 27.3 MB/s once
hashing moved to a worker — against a ~25 MB/s expectation for splitting a
50 MB/s TLS budget across two directions in one isolate. That is the pipeline
sitting on the ceiling with nothing much left in it.
