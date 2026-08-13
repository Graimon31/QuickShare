import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:quickshare/core/theme/app_motion.dart';

/// One hit target with press feedback. Keeping the callback in InkWell avoids
/// the old GestureDetector + InkWell double invocation.
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final double pressedScale;
  final BorderRadius borderRadius;
  final bool haptic;

  const PressableScale({
    super.key,
    required this.child,
    this.onPressed,
    this.pressedScale = 0.96,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.haptic = true,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!mounted || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return AnimatedScale(
      scale: enabled && _pressed ? widget.pressedScale : 1,
      duration: _pressed ? AppMotion.press : AppMotion.pressOut,
      curve: AppMotion.pageCurve,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled
              ? () {
                  if (widget.haptic) HapticFeedback.lightImpact();
                  widget.onPressed!();
                }
              : null,
          onHighlightChanged: enabled ? _setPressed : null,
          borderRadius: widget.borderRadius,
          child: widget.child,
        ),
      ),
    );
  }
}
