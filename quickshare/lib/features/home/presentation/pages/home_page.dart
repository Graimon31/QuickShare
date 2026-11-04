import 'dart:io' show Platform;
import 'dart:ui';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quickshare/core/platform/device_platform.dart';
import 'package:quickshare/core/router/send_routes.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/theme/app_motion.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_choice.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_preconditions.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Where on the home screen a file was dropped.
enum HomeDropTarget { internet, airdrop }

/// The transport a file dropped on [target] is sent over.
///
/// A drop has already chosen its file, so it skips the question the AirDrop
/// card would ask and takes the local network, which is what dropping a file
/// on the old Send card always did. Only the internet card has a mode of its
/// own to give.
@visibleForTesting
TransportType dropModeFor(HomeDropTarget target) => switch (target) {
      HomeDropTarget.internet => TransportType.internet,
      HomeDropTarget.airdrop => TransportType.wifi,
    };

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _auroraController;

  /// Whether the AirDrop card is showing its two ways to send.
  bool _airdropOpen = false;

  /// The transport whose preconditions are being decided, so a second tap
  /// cannot start a second dialog on top of the first.
  TransportType? _checking;

  /// The AirDrop buttons, so they can be scrolled into view once open.
  final GlobalKey _optionsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _auroraController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 35),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!Platform.isIOS && !MediaQuery.of(context).disableAnimations) {
        _auroraController.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _auroraController.dispose();
    super.dispose();
  }

  void _toggleAirdrop() => setState(() => _airdropOpen = !_airdropOpen);

  /// On a window or a phone too short to hold both buttons under the card,
  /// opening AirDrop would leave the second one half off the screen. Scroll
  /// just far enough to show them both — after the frame, because the height
  /// they are measured against is only final once the layout has run.
  void _revealOptions() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final options = _optionsKey.currentContext;
      if (!mounted || options == null || !_airdropOpen) return;
      final still = MediaQuery.of(context).disableAnimations;
      Scrollable.ensureVisible(
        options,
        duration: still ? Duration.zero : AppMotion.expand,
        curve: AppMotion.expandCurve,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  /// Opens the file screen for [mode] — after checking that [mode] can run.
  ///
  /// The check belongs here, at the button, and not after the files are
  /// chosen: with Bluetooth or Wi-Fi off, nobody should browse for a folder
  /// only to be told the way they picked was never going to work. A refusal
  /// has already told the person what is missing, and they stay on this
  /// screen with the same choices in front of them.
  Future<void> _openFiles(TransportType mode) async {
    if (_checking != null) return;
    setState(() => _checking = mode);
    final bool allowed;
    try {
      allowed = await TransportPreconditions.ensure(context, mode);
    } finally {
      if (mounted) setState(() => _checking = null);
    }
    if (!allowed || !mounted) return;
    context.push(SendRoutes.filesFor(mode));
  }

  void _onDrop(HomeDropTarget target, List<String> paths) {
    if (paths.isEmpty) return;
    // Home is outside the Sender ShellRoute. Pass the drop through
    // navigation so FilePickerPage dispatches it where SenderBloc is
    // provided; the file screen runs the transport check before it starts.
    context.push(
      SendRoutes.filesFor(dropModeFor(target)),
      extra: {'qhtpPaths': paths},
    );
  }

  Future<void> _openReceive() async {
    final ready = await TransportPreconditions.ensureReceiver(context);
    if (!ready || !mounted) return;
    context.push(DevicePlatform.isDesktop ? '/receive/code' : '/receive');
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DevicePlatform.isDesktop;
    final isIos = Platform.isIOS;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final l10n = AppLocalizations.of(context);
    // Small screens trade some breathing room for height: two cards and a
    // receive button have to share a 375 × 812 phone — or the 680 × 748
    // window the macOS app opens in — with the title, and Receive must not be
    // the thing that falls below the fold. Open AirDrop adds two buttons more
    // and scrolls.
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 480;
    final tight = narrow || size.height < 800;
    final bluetoothOffered = TransportType.bluetooth.offeredHere;

    return Scaffold(
      backgroundColor: AppColors.voidBg,
      body: Stack(
        children: [
          // 1. Vibrant Animated Aurora Background Blobs
          // iOS keeps a static gradient instead of large, animated image blurs.
          if (isIos)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topRight,
                  radius: 1.35,
                  colors: [
                    Color(0x6640E0D0),
                    Color(0x3322D3EE),
                    AppColors.voidBg,
                  ],
                  stops: [0, 0.38, 1],
                ),
              ),
              child: SizedBox.expand(),
            )
          else if (!reduceMotion)
            AnimatedBuilder(
              animation: _auroraController,
              builder: (context, child) {
                final val = _auroraController.value;
                final dx1 = 70 * (val - 0.5);
                final dy1 = 90 * (val - 0.5);
                final dx2 = -80 * (val - 0.5);
                final dy2 = -60 * (val - 0.5);

                return Stack(
                  children: [
                    // Aurora Vivid Teal/Cyan Wave (Top-Right / Right)
                    Positioned(
                      top: -30 + dy1,
                      right: -20 + dx1,
                      child: _buildBlurBlob(
                        color: AppColors.primary,
                        size: 480,
                        blur: 68,
                        opacity: 0.50,
                      ),
                    ),
                    // Aurora Bright Green Wave (Right Middle)
                    Positioned(
                      top: 130 + dy2,
                      right: -50 + dx2,
                      child: _buildBlurBlob(
                        color: AppColors.secondary,
                        size: 440,
                        blur: 64,
                        opacity: 0.45,
                      ),
                    ),
                    // Aurora Deep Cyan/Teal (Bottom-Left)
                    Positioned(
                      bottom: -50 + (dy1 * 0.7),
                      left: -70 + (dx1 * 0.7),
                      child: _buildBlurBlob(
                        color: AppColors.secondaryDark,
                        size: 460,
                        blur: 72,
                        opacity: 0.42,
                      ),
                    ),
                  ],
                );
              },
            )
          else
            Stack(
              children: [
                Positioned(
                  top: -30,
                  right: -20,
                  child: _buildBlurBlob(
                    color: AppColors.primary,
                    size: 480,
                    blur: 68,
                    opacity: 0.50,
                  ),
                ),
                Positioned(
                  top: 130,
                  right: -50,
                  child: _buildBlurBlob(
                    color: AppColors.secondary,
                    size: 440,
                    blur: 64,
                    opacity: 0.45,
                  ),
                ),
                Positioned(
                  bottom: -50,
                  left: -70,
                  child: _buildBlurBlob(
                    color: AppColors.secondaryDark,
                    size: 460,
                    blur: 72,
                    opacity: 0.42,
                  ),
                ),
              ],
            ),

          // 2. Main Centered Glass UI Content
          SafeArea(
            child: ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(
                    horizontal: narrow ? 20.0 : 32.0,
                    vertical: tight ? 28.0 : 40.0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 12),

                        // Visible Glowing Gradient Title
                        Center(
                          child: ShaderMask(
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: [AppColors.secondary, AppColors.primary],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ).createShader(bounds),
                            child: Text(
                              'DirectDrop',
                              style: GoogleFonts.inter(
                                fontSize: 38,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ),
                        ).animate().fadeIn(duration: 400.ms),

                        const SizedBox(height: 14),

                        // Subtitle
                        Text(
                          l10n.appTagline,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            height: 1.5,
                            color: Colors.white.withValues(alpha: 0.88),
                            fontWeight: FontWeight.w400,
                          ),
                          textAlign: TextAlign.center,
                        ).animate().fadeIn(delay: 150.ms, duration: 400.ms),

                        SizedBox(height: tight ? 26 : 36),

                        // Way 1: over the internet. Opens the file screen at
                        // once, and takes a dropped file with it.
                        _DropZone(
                          onFilesDropped: (paths) =>
                              _onDrop(HomeDropTarget.internet, paths),
                          builder: (context, dragOver) => _GlassCard(
                            title: l10n.homeInternetTitle,
                            subtitle: l10n.homeInternetSubtitle,
                            icon: TransportType.internet.icon,
                            badgeGradient: const RadialGradient(
                              colors: [
                                AppColors.accent,
                                AppColors.secondaryDark
                              ],
                              center: Alignment(-0.25, -0.25),
                              radius: 0.9,
                            ),
                            badgeGlowColor: AppColors.secondaryDark,
                            compact: tight,
                            dragOver: dragOver,
                            busy: _checking == TransportType.internet,
                            onTap: () => _openFiles(TransportType.internet),
                          ),
                        )
                            .animate()
                            .fadeIn(delay: 250.ms, duration: 400.ms)
                            .slideY(begin: 0.08, end: 0),

                        SizedBox(height: tight ? 16 : 22),

                        // Way 2: AirDrop. Not a transport itself — it opens
                        // the two that are, right here, and a file dropped on
                        // any part of it goes the local-network way.
                        _DropZone(
                          onFilesDropped: (paths) =>
                              _onDrop(HomeDropTarget.airdrop, paths),
                          builder: (context, dragOver) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _GlassCard(
                                title: l10n.airdropName,
                                subtitle: l10n.homeAirdropSubtitle,
                                icon: Icons.wifi_tethering_rounded,
                                badgeGradient: const RadialGradient(
                                  colors: [
                                    Color(0xFFE0F2FE),
                                    Color(0xFF0EA5E9)
                                  ],
                                  center: Alignment(-0.25, -0.25),
                                  radius: 0.9,
                                ),
                                badgeGlowColor: AppColors.primaryDeep,
                                compact: tight,
                                dragOver: dragOver,
                                expanded: _airdropOpen,
                                onTap: _toggleAirdrop,
                              ),
                              _Expandable(
                                expanded: _airdropOpen,
                                onOpened: _revealOptions,
                                child: Padding(
                                  key: _optionsKey,
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _OptionButton(
                                        type: TransportType.wifi,
                                        busy: _checking == TransportType.wifi,
                                        onTap: () =>
                                            _openFiles(TransportType.wifi),
                                      ),
                                      if (bluetoothOffered) ...[
                                        const SizedBox(height: 10),
                                        _OptionButton(
                                          type: TransportType.bluetooth,
                                          busy: _checking ==
                                              TransportType.bluetooth,
                                          onTap: () => _openFiles(
                                              TransportType.bluetooth),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                            .animate()
                            .fadeIn(delay: 380.ms, duration: 400.ms)
                            .slideY(begin: 0.08, end: 0),

                        SizedBox(height: tight ? 22 : 30),

                        // Receiving is not a third way to send, so it is not
                        // a third card. The sender's QR code or digits are
                        // what choose the path, and this only opens the
                        // place to enter them.
                        _ReceiveButton(
                          title: l10n.homeReceiveTitle,
                          hint: isDesktop
                              ? l10n.homeReceiveSubtitleDesktop
                              : l10n.homeReceiveSubtitleMobile,
                          onTap: _openReceive,
                        )
                            .animate()
                            .fadeIn(delay: 500.ms, duration: 400.ms)
                            .slideY(begin: 0.08, end: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Settings, out of the way of what this screen is for.
          //
          // Last in the Stack on purpose. A Stack hit-tests its children in
          // reverse, so whatever is declared after this takes the tap: with
          // the gear above the main content, the scroll view underneath — it
          // fills the screen and is opaque to pointers — swallowed every tap
          // on the top-right corner and the button silently did nothing.
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: IconButton(
                  tooltip: AppLocalizations.of(context).homeSettingsTooltip,
                  icon: const Icon(Icons.settings_outlined,
                      color: AppColors.textSecondary),
                  onPressed: () => context.go('/settings'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlurBlob({
    required Color color,
    required double size,
    required double blur,
    required double opacity,
  }) {
    return RepaintBoundary(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: opacity),
          ),
        ),
      ),
    );
  }
}


/// Hover, press and keyboard-focus state, handed to whatever is drawn inside.
typedef _Touch = ({bool hovered, bool pressed, bool focused});

/// What every tappable thing on this screen shares: a mouse cursor, hover and
/// press feedback, a focus node the keyboard can reach and activate with
/// Enter or Space, and one screen-reader node that says what it is.
///
/// [expanded] is null for something that does not open anything. Otherwise it
/// is the state a screen reader announces ("expanded", "collapsed") and
/// follows the control as it changes.
class _Interactive extends StatefulWidget {
  final VoidCallback onTap;
  final String label;
  final bool? expanded;
  final Widget Function(BuildContext context, _Touch touch) builder;

  const _Interactive({
    required this.onTap,
    required this.label,
    required this.builder,
    this.expanded,
  });

  @override
  State<_Interactive> createState() => _InteractiveState();
}

class _InteractiveState extends State<_Interactive> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  void _activate() {
    HapticFeedback.lightImpact();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      expanded: widget.expanded,
      label: widget.label,
      onTap: _activate,
      // The explicit actions a screen reader offers for something that opens:
      // "expand" while it is closed, "collapse" while it is open.
      onExpand: widget.expanded == false ? _activate : null,
      onCollapse: widget.expanded == true ? _activate : null,
      excludeSemantics: true,
      child: FocusableActionDetector(
        onFocusChange: (focused) => setState(() => _focused = focused),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: _activate,
            child: widget.builder(
              context,
              (hovered: _hovered, pressed: _pressed, focused: _focused),
            ),
          ),
        ),
      ),
    );
  }
}

/// Takes files dragged in from the desktop's file manager.
///
/// Flutter's DragTarget handles in-app draggables. DropTarget adds the native
/// Finder/Explorer/Linux file-manager pipeline for desktop users. [builder]
/// is told whether something is being held over the zone, so the card inside
/// can say "drop here".
class _DropZone extends StatefulWidget {
  final Widget Function(BuildContext context, bool dragOver) builder;
  final void Function(List<String> paths) onFilesDropped;

  const _DropZone({required this.builder, required this.onFilesDropped});

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  bool _dragOver = false;

  @override
  Widget build(BuildContext context) {
    final supportsNativeDrop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;

    Widget content = widget.builder(context, _dragOver);
    if (supportsNativeDrop) {
      final inner = content;
      content = DragTarget<String>(
        onWillAcceptWithDetails: (_) {
          setState(() => _dragOver = true);
          return true;
        },
        onLeave: (_) => setState(() => _dragOver = false),
        onAcceptWithDetails: (details) {
          setState(() => _dragOver = false);
          widget.onFilesDropped([details.data]);
        },
        builder: (context, candidateData, rejectedData) => inner,
      );
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragOver = true),
      onDragExited: (_) => setState(() => _dragOver = false),
      onDragDone: (details) {
        setState(() => _dragOver = false);
        final paths = details.files
            .map((file) => file.path)
            .where((path) => path.isNotEmpty)
            .toList();
        if (paths.isNotEmpty) widget.onFilesDropped(paths);
      },
      child: content,
    );
  }
}

/// A group of options that opens under the control that owns it.
///
/// Closed it is nothing at all — not hidden, absent, so neither a finger, the
/// keyboard nor a screen reader can reach what is not there. Opening and
/// closing animate in the screen's own motion (a fade and a short slide with
/// the height), and with the system's "reduce motion" on they happen at once.
class _Expandable extends StatefulWidget {
  final bool expanded;
  final Widget child;

  /// Called when it has finished opening.
  final VoidCallback? onOpened;

  const _Expandable({
    required this.expanded,
    required this.child,
    this.onOpened,
  });

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.expandCurve,
    reverseCurve: AppMotion.collapseCurve,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onOpened?.call();
    });
  }

  @override
  void didUpdateWidget(_Expandable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    final still = MediaQuery.of(context).disableAnimations;
    _controller
      ..duration = still ? Duration.zero : AppMotion.expand
      ..reverseDuration = still ? Duration.zero : AppMotion.collapse;
    if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // While it is closing the options are still drawn, but they are already
    // out of reach: a tap, a Tab or a screen reader must not land on something
    // that is on its way out.
    final reachable = widget.expanded;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.isDismissed) return const SizedBox.shrink();
        return SizeTransition(
          sizeFactor: _curve,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: _curve,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.06),
                end: Offset.zero,
              ).animate(_curve),
              child: child,
            ),
          ),
        );
      },
      child: ExcludeSemantics(
        excluding: !reachable,
        child: ExcludeFocus(
          excluding: !reachable,
          child: IgnorePointer(
            ignoring: !reachable,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Premium Glassmorphic Interactive Action Card
class _GlassCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final RadialGradient badgeGradient;
  final Color badgeGlowColor;
  final VoidCallback onTap;

  /// Non-null for a card that opens something: it then draws a chevron that
  /// turns with the state, and tells a screen reader which state it is in.
  final bool? expanded;

  /// Something is being dragged over the card.
  final bool dragOver;

  /// The transport behind this card is being checked.
  final bool busy;

  /// A small screen: the same card with less air around it.
  final bool compact;

  const _GlassCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.badgeGradient,
    required this.badgeGlowColor,
    required this.onTap,
    this.expanded,
    this.dragOver = false,
    this.busy = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final still = MediaQuery.of(context).disableAnimations;

    return _Interactive(
      onTap: onTap,
      label: '$title. $subtitle',
      expanded: expanded,
      builder: (context, touch) {
        final lifted = touch.hovered || dragOver;
        final scale = touch.pressed ? 0.98 : (lifted ? 1.02 : 1.0);
        final translateY = lifted ? -3.0 : 0.0;

        final borderColor = dragOver
            ? AppColors.primary
            : (touch.hovered
                ? AppColors.secondary
                : const Color.fromRGBO(255, 255, 255, 0.45));
        final borderWidth = dragOver ? 2.2 : 1.5;
        final badge = compact ? 60.0 : 72.0;

        final Widget cardInner = Container(
          width: double.infinity, // Full horizontal stretch inside its parent
          decoration: BoxDecoration(
            color: dragOver
                ? const Color.fromRGBO(34, 211, 238, 0.18)
                : const Color.fromRGBO(255, 255, 255, 0.13),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: borderWidth),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.40),
                blurRadius: 36,
                offset: const Offset(0, 10),
              ),
              if (lifted)
                BoxShadow(
                  color: badgeGlowColor.withValues(alpha: 0.35),
                  blurRadius: 28,
                  spreadRadius: 2,
                ),
            ],
          ),
          child: Stack(
            children: [
              // Top Inset Glass Highlight Line
              Positioned(
                top: 0,
                left: 20,
                right: 20,
                child: Container(
                  height: 1.5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.0),
                        Colors.white.withValues(alpha: 0.50),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),

              // Glassmorphic Content Padding & Centered Layout
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 20.0 : 32.0,
                  vertical: compact ? 24.0 : 34.0,
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Circular Badge with Radial Gradient & Strong Glow
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: badge,
                        height: badge,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: badgeGradient,
                          boxShadow: [
                            BoxShadow(
                              color: badgeGlowColor
                                  .withValues(alpha: lifted ? 0.90 : 0.70),
                              blurRadius: lifted ? 32 : 24,
                              spreadRadius: lifted ? 3 : 1,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            icon,
                            size: compact ? 32 : 38,
                            color: Colors.white,
                          ),
                        ),
                      ),

                      SizedBox(height: compact ? 14 : 18),

                      // Card Title (Centered)
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: compact ? 22 : 24,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          letterSpacing: -0.3,
                        ),
                      ),

                      const SizedBox(height: 6),

                      // Subtitle (Centered)
                      Text(
                        dragOver ? l10n.homeDropHere : subtitle,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          color: dragOver
                              ? AppColors.primary
                              : const Color.fromRGBO(255, 255, 255, 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // What the card does next: a spinner while its transport is
              // being checked, otherwise the chevron of a card that opens.
              if (busy)
                const Positioned(
                  top: 16,
                  right: 18,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  ),
                )
              else if (expanded != null)
                Positioned(
                  top: 14,
                  right: 16,
                  child: AnimatedRotation(
                    turns: expanded! ? 0.5 : 0,
                    duration: still ? Duration.zero : AppMotion.expand,
                    curve: AppMotion.expandCurve,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 26,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ),
            ],
          ),
        );

        final Widget cardContent = AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, translateY, 0.0, 1.0)
            ..scaleByDouble(scale, scale, scale, 1.0),
          child: cardInner,
        );

        // iOS uses the opaque card treatment without a backdrop readback blur.
        final Widget glassCard = ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Platform.isIOS
              ? cardContent
              : BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: cardContent,
                ),
        );

        // The keyboard-focus ring is drawn over the card's own edge, so
        // tabbing onto it does not nudge the layout by a pixel or two.
        return Container(
          foregroundDecoration: touch.focused
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.primary, width: 2),
                )
              : null,
          child: glassCard,
        );
      },
    );
  }
}

/// One of the ways AirDrop opens into: a glass row with the transport's name,
/// one line on what it needs, and a way forward.
class _OptionButton extends StatelessWidget {
  final TransportType type;
  final bool busy;
  final VoidCallback onTap;

  const _OptionButton({
    required this.type,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = l10n.transportTitle(type);
    final subtitle = l10n.transportSubtitle(type);
    final gradient = type == TransportType.bluetooth
        ? const LinearGradient(
            colors: [AppColors.primary, AppColors.primaryDeep])
        : const LinearGradient(
            colors: [AppColors.secondary, AppColors.secondaryDark]);

    return _Interactive(
      onTap: onTap,
      label: '$title. $subtitle',
      builder: (context, touch) {
        final Widget row = AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: touch.pressed
                ? const Color.fromRGBO(255, 255, 255, 0.07)
                : (touch.hovered
                    ? const Color.fromRGBO(255, 255, 255, 0.17)
                    : const Color.fromRGBO(255, 255, 255, 0.11)),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: touch.focused
                  ? AppColors.primary
                  : (touch.hovered
                      ? AppColors.secondary
                      : AppColors.glassBorder),
              width: touch.focused ? 2 : 1.2,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: gradient,
                ),
                child: Icon(type.icon, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        height: 1.3,
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
            ],
          ),
        );

        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Platform.isIOS
              ? row
              : BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: row,
                ),
        );
      },
    );
  }
}

/// Receiving, as an action of its own below the two ways to send.
///
/// Quieter than the cards on purpose: it is not a way to send, and it needs no
/// choice of transport — the sender's QR code or digits decide the path.
class _ReceiveButton extends StatelessWidget {
  final String title;
  final String hint;
  final VoidCallback onTap;

  const _ReceiveButton({
    required this.title,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _Interactive(
      onTap: onTap,
      label: '$title. $hint',
      builder: (context, touch) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: touch.hovered
                ? const Color.fromRGBO(255, 255, 255, 0.12)
                : const Color.fromRGBO(255, 255, 255, 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: touch.focused
                  ? AppColors.primary
                  : (touch.hovered
                      ? AppColors.secondary
                      : AppColors.glassBorder),
              width: touch.focused ? 2 : 1.2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.download_rounded,
                      color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.78),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
