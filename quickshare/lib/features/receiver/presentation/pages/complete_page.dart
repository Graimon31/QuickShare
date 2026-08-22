import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:open_file/open_file.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/shared/widgets/pressable_scale.dart';

class CompletePage extends StatelessWidget {
  final String fileName;
  final String filePath;

  const CompletePage({super.key, required this.fileName, required this.filePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_rounded,
                          color: AppColors.success, size: 112)
                      .animate()
                      .scale(duration: 500.ms, curve: Curves.easeOutBack)
                      .fadeIn(),
                  const SizedBox(height: 24),
                  Text(
                    'Received!',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.glassFill,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.glassBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.file_present_rounded,
                            color: AppColors.primary, size: 40),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            fileName,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: AppColors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ).animate().slideY(begin: 0.5, end: 0.0).fadeIn(),
                  const SizedBox(height: 32),
                  PressableScale(
                    onPressed: () => OpenFile.open(filePath),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: Text('Open',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.go('/receive'),
                    child: const Text('Receive Another'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
