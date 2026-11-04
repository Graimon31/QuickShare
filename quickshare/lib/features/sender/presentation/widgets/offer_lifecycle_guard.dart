import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

/// Tells the sender bloc when the app comes back to the foreground.
///
/// An offer's code is replaced on a deadline, and a timer only measures the
/// time the process ran: a laptop that slept through the deadline, or a phone
/// that spent it in a pocket, has not run for it. Coming back is the moment to
/// read the wall clock — and on a phone, to ask whether the system took the
/// server away while nobody was looking.
///
/// Wraps the screens that show an offer. Going away says nothing; only
/// returning does.
class OfferLifecycleGuard extends StatefulWidget {
  final Widget child;

  const OfferLifecycleGuard({super.key, required this.child});

  @override
  State<OfferLifecycleGuard> createState() => _OfferLifecycleGuardState();
}

class _OfferLifecycleGuardState extends State<OfferLifecycleGuard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<SenderBloc>().add(OfferResumed());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
