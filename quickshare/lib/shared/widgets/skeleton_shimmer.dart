import 'package:flutter/material.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/theme/app_motion.dart';

class SkeletonShimmer extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;

  const SkeletonShimmer({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppMotion.shimmer);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.glassFill,
          borderRadius: widget.borderRadius,
        ),
        child: SizedBox(width: widget.width, height: widget.height),
      );
    }

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final shift = (_controller.value * 2) - 1;
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment(shift - 1.2, -0.2),
              end: Alignment(shift + 1.2, 0.2),
              colors: const [
                Color.fromRGBO(255, 255, 255, 0.06),
                Color.fromRGBO(255, 255, 255, 0.25),
                Color.fromRGBO(255, 255, 255, 0.06),
              ],
              stops: const [0.2, 0.5, 0.8],
            ).createShader(bounds),
            child: child,
          );
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.glassFill,
            borderRadius: widget.borderRadius,
          ),
          child: SizedBox(width: widget.width, height: widget.height),
        ),
      ),
    );
  }
}
