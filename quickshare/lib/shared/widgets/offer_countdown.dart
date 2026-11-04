import 'dart:async';

import 'package:flutter/material.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// How long the code and QR on screen have left, as `M:SS`.
///
/// Read off the wall clock on every tick rather than counted down: a screen
/// that was asleep, or a frame that ran long, must not drift from the deadline
/// the bloc rotates at. Never shows less than `0:00`; at zero it simply waits
/// for the new deadline, which arrives with the new code.
class OfferCountdown extends StatefulWidget {
  final DateTime expiresAt;

  /// The clock to read. `DateTime.now` unless a test supplies one.
  final DateTime Function()? now;

  const OfferCountdown({super.key, required this.expiresAt, this.now});

  @override
  State<OfferCountdown> createState() => _OfferCountdownState();
}

class _OfferCountdownState extends State<OfferCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _format(Duration left) {
    // Rounded up, so the last second reads 0:01 and not 0:00 while there is
    // still time on the clock.
    final seconds = (left.inMilliseconds / 1000).ceil();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final now = (widget.now ?? DateTime.now)();
    var left = widget.expiresAt.difference(now);
    if (left.isNegative) left = Duration.zero;
    return Text(
      AppLocalizations.of(context).offerCodeChangesIn(_format(left)),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
    );
  }
}
