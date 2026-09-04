# Benchmarks

Not part of `flutter test` — they take minutes and print numbers rather than
asserting them. Run one deliberately:

```
flutter test benchmark/stack_layers_bench.dart
flutter test benchmark/transfer_throughput_bench.dart
flutter test benchmark/ui_isolate_stall_bench.dart
```

All figures below are from a 2021 M1 Pro, September 2026.

## Where the time goes

`stack_layers_bench` measures each layer the bytes pass through, which is the
only way to tell a slow link from a slow stack.

| layer | throughput |
| --- | --- |
| plain TCP, loopback | 1278 MB/s |
| Dart `SecureSocket` (TLS) | 53 MB/s |
| Dart `HttpServer`/`HttpClient` over TLS | 50 MB/s |
| QHTP server serving a file (read by a raw client) | 52 MB/s |
| SHA-256, pure Dart | 103 MB/s |

Both ends run in one isolate here, so each figure counts the work of both
sides at once — a single side has roughly twice this to itself. TLS is the
ceiling and it is Dart's, not the link's: parallel connections do not raise it
(1/2/4/8 streams all land within noise of 55 MB/s aggregate), which says it is
bound by one event loop.

## What sharing an isolate costs

`ui_isolate_stall_bench` is the one worth reading. The sender runs on an
isolate of its own in both runs, as it does on a real network; what changes is
only where the *receiving* happens. The main isolate meanwhile pretends to be
a screen — a frame's worth of work, over and over.

| receiving | 200 MB took | rate | frames late |
| --- | --- | --- | --- |
| on the main isolate, beside the screen | 10138 ms | 19.7 MB/s | 0 / 3240 |
| on a worker isolate | 2774 ms | **72.1 MB/s** | 2 / 783 |

Not a small effect: sharing a thread with the interface cost the transfer
**3.7×** of its throughput. Note which side was starving — no frames were
dropped in the slow run, because the screen was winning every contest and the
transfer was what waited. That is a Desktop→iOS transfer "hanging": reads
falling behind, the sender stalled on a window that never opened.

Read 3.7× as an upper bound. The stand-in screen here draws flat out, which a
real app's does not, so the gain on a device depends on how busy the interface
actually is — largest on a phone, where the cores are weakest and the screen
still has to be drawn.

The 72 MB/s is worth noticing too: it is ~575 Mbit/s, well above the ~420
Mbit/s that "Dart TLS caps at 53 MB/s" suggests, because that figure counts
both ends. One side, alone on its own isolate, has considerably more room.

## The pipeline itself

`transfer_throughput_bench` runs a real 400 MB QHTP session over loopback with
both ends in one isolate: 19.6 MB/s while both hashed on the transfer's own
isolate, 27.3 MB/s once hashing moved to a worker — against a ~25 MB/s
expectation for splitting a 50 MB/s TLS budget across two directions in one
isolate. That is the pipeline sitting on its ceiling with little left in it.
