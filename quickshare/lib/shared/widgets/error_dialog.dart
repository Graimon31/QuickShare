import 'package:flutter/material.dart';

class ErrorDialog extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onGoHome;

  const ErrorDialog({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
    this.onGoHome,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(
        Icons.error_outline,
        color: Colors.redAccent,
        size: 48,
      ),
      title: Text(title),
      content: Text(
        message,
        textAlign: TextAlign.center,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        if (onGoHome != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onGoHome!();
            },
            child: const Text('Go Home'),
          ),
        if (onRetry != null)
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              onRetry!();
            },
            child: const Text('Retry'),
          ),
      ],
    );
  }
}
