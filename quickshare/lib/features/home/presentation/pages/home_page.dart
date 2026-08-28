import 'dart:io' show Platform;
import 'dart:ui';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _auroraController;

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

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final isIos = Platform.isIOS;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

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
                padding: const EdgeInsets.symmetric(
                    horizontal: 32.0, vertical: 40.0),
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
                          AppLocalizations.of(context).appTagline,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            height: 1.5,
                            color: Colors.white.withValues(alpha: 0.88),
                            fontWeight: FontWeight.w400,
                          ),
                          textAlign: TextAlign.center,
                        ).animate().fadeIn(delay: 150.ms, duration: 400.ms),

                        const SizedBox(height: 36),

                        // Card 1: Send File (Glassmorphism + Drag & Drop Target)
                        _GlassCard(
                          title: AppLocalizations.of(context).homeSendTitle,
                          subtitle: AppLocalizations.of(context).homeSendSubtitle,
                          icon: Icons.upload_rounded,
                          badgeGradient: const RadialGradient(
                            colors: [AppColors.accent, AppColors.secondaryDark],
                            center: Alignment(-0.25, -0.25),
                            radius: 0.9,
                          ),
                          badgeGlowColor: AppColors.secondaryDark,
                          onTap: () => context.push('/send'),
                          allowDragDrop: true,
                          onFilesDropped: (paths) {
                            if (paths.isNotEmpty) {
                              // Home is outside the Sender ShellRoute. Pass
                              // the drop through navigation so FilePickerPage
                              // dispatches it where SenderBloc is provided.
                              context
                                  .push('/send', extra: {'qhtpPaths': paths});
                            }
                          },
                        )
                            .animate()
                            .fadeIn(delay: 250.ms, duration: 400.ms)
                            .slideY(begin: 0.08, end: 0),

                        const SizedBox(height: 22),

                        // Card 2: Receive File (Glassmorphism)
                        _GlassCard(
                          title: AppLocalizations.of(context).homeReceiveTitle,
                          subtitle: isDesktop
                              ? AppLocalizations.of(context).homeReceiveSubtitleDesktop
                              : AppLocalizations.of(context).homeReceiveSubtitleMobile,
                          icon: Icons.download_rounded,
                          badgeGradient: const RadialGradient(
                            colors: [Color(0xFFE0F2FE), Color(0xFF0EA5E9)],
                            center: Alignment(-0.25, -0.25),
                            radius: 0.9,
                          ),
                          badgeGlowColor: AppColors.primaryDeep,
                          onTap: () => context
                              .push(isDesktop ? '/receive/code' : '/receive'),
                        )
                            .animate()
                            .fadeIn(delay: 380.ms, duration: 400.ms)
                            .slideY(begin: 0.08, end: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Settings, out of the way of the two things this screen is for.
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

/// Premium Glassmorphic Interactive Action Card
class _GlassCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final RadialGradient badgeGradient;
  final Color badgeGlowColor;
  final VoidCallback onTap;
  final bool allowDragDrop;
  final void Function(List<String> paths)? onFilesDropped;

  const _GlassCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.badgeGradient,
    required this.badgeGlowColor,
    required this.onTap,
    this.allowDragDrop = false,
    this.onFilesDropped,
  });

  @override
  State<_GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<_GlassCard> {
  bool _isHovered = false;
  bool _isPressed = false;
  bool _isFocused = false;
  bool _isDragOver = false;

  void _handleTap() {
    HapticFeedback.lightImpact();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final supportsNativeDrop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    final scale = _isPressed ? 0.98 : (_isHovered || _isDragOver ? 1.02 : 1.0);
    final translateY = _isHovered || _isDragOver ? -3.0 : 0.0;

    final borderColor = _isDragOver
        ? AppColors.primary
        : (_isHovered
            ? AppColors.secondary
            : const Color.fromRGBO(255, 255, 255, 0.45));

    final borderWidth = _isDragOver ? 2.2 : 1.5;

    final Widget cardInner = Container(
      width:
          double.infinity, // Ensures full horizontal stretch inside container
      decoration: BoxDecoration(
        color: _isDragOver
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
          if (_isHovered || _isDragOver)
            BoxShadow(
              color: widget.badgeGlowColor.withValues(alpha: 0.35),
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
            padding:
                const EdgeInsets.symmetric(horizontal: 32.0, vertical: 34.0),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Circular Badge with Radial Gradient & Strong Glow
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: widget.badgeGradient,
                      boxShadow: [
                        BoxShadow(
                          color: widget.badgeGlowColor.withValues(
                              alpha: _isHovered || _isDragOver ? 0.90 : 0.70),
                          blurRadius: _isHovered || _isDragOver ? 32 : 24,
                          spreadRadius: _isHovered || _isDragOver ? 3 : 1,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Icon(
                        widget.icon,
                        size: 38,
                        color: Colors.white,
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Card Title (Centered)
                  Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),

                  const SizedBox(height: 6),

                  // Subtitle (Centered)
                  Text(
                    _isDragOver ? AppLocalizations.of(context).homeDropHere : widget.subtitle,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      color: _isDragOver
                          ? AppColors.primary
                          : const Color.fromRGBO(255, 255, 255, 0.85),
                    ),
                  ),
                ],
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

    // Keyboard & Focus Outline detector
    final Widget interactiveCard = FocusableActionDetector(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      actions: {
        ActivateIntent:
            CallbackAction<ActivateIntent>(onInvoke: (_) => _handleTap()),
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) => setState(() => _isPressed = false),
          onTapCancel: () => setState(() => _isPressed = false),
          onTap: _handleTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              border: _isFocused
                  ? Border.all(color: AppColors.primary, width: 2)
                  : null,
            ),
            child: glassCard,
          ),
        ),
      ),
    );

    // Flutter's DragTarget handles in-app draggables. DropTarget adds the
    // native Finder/Explorer/Linux file-manager pipeline for desktop users.
    Widget dropContent = interactiveCard;
    if (widget.allowDragDrop && supportsNativeDrop) {
      dropContent = DragTarget<String>(
        onWillAcceptWithDetails: (_) {
          setState(() => _isDragOver = true);
          return true;
        },
        onLeave: (_) => setState(() => _isDragOver = false),
        onAcceptWithDetails: (details) {
          setState(() => _isDragOver = false);
          widget.onFilesDropped?.call([details.data]);
        },
        builder: (context, candidateData, rejectedData) => interactiveCard,
      );
    }

    if (widget.allowDragDrop) {
      return DropTarget(
        onDragEntered: (_) => setState(() => _isDragOver = true),
        onDragExited: (_) => setState(() => _isDragOver = false),
        onDragDone: (details) {
          setState(() => _isDragOver = false);
          final paths = details.files
              .map((file) => file.path)
              .where((path) => path.isNotEmpty)
              .toList();
          if (paths.isNotEmpty) widget.onFilesDropped?.call(paths);
        },
        child: dropContent,
      );
    }

    return dropContent;
  }
}
