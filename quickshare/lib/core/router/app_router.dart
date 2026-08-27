import 'package:flutter/material.dart';
import 'package:animations/animations.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/theme/app_motion.dart';
import 'package:quickshare/features/home/presentation/pages/home_page.dart';
import 'package:quickshare/features/settings/presentation/pages/settings_page.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/file_picker_page.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/features/sender/presentation/pages/local_network_page.dart';
import 'package:quickshare/features/sender/presentation/pages/network_fallback_page.dart';
import 'package:quickshare/features/sender/presentation/pages/qr_display_page.dart';
import 'package:quickshare/features/sender/presentation/pages/sender_progress_page.dart';
import 'package:quickshare/features/sender/presentation/pages/bluetooth_send_page.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/presentation/pages/qr_scan_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/download_progress_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/transfer_preview_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/complete_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/code_receive_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/bluetooth_receive_page.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

CustomTransitionPage<void> _qsPage(
  GoRouterState state,
  Widget child, {
  required bool sharedAxis,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: AppMotion.page,
    reverseTransitionDuration: AppMotion.pageReverse,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.of(context).disableAnimations) return child;
      if (sharedAxis) {
        return SharedAxisTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          transitionType: SharedAxisTransitionType.horizontal,
          fillColor: AppColors.voidBg,
          child: child,
        );
      }
      return FadeThroughTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        fillColor: AppColors.voidBg,
        child: child,
      );
    },
  );
}

/// Application router configuration using GoRouter.
///
/// Provides declarative routing for all pages in the app.
/// BLoC providers are scoped to their respective feature routes
/// using ShellRoute to ensure proper lifecycle management.
class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: [
      // Home
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => _qsPage(
          state,
          const HomePage(),
          sharedAxis: false,
        ),
      ),

      // Bluetooth receive uses the optional QR token to select the matching
      // Mac automatically; without it, the page keeps manual discovery.
      GoRoute(
        path: '/receive/bluetooth',
        pageBuilder: (context, state) => _qsPage(
          state,
          BluetoothReceivePage(
            sessionToken: state.uri.queryParameters['token'],
          ),
          sharedAxis: true,
        ),
      ),

      // === Sender Flow ===
      // Wrapped in ShellRoute to share SenderBloc across sender pages
      ShellRoute(
        builder: (context, state, child) {
          return BlocProvider(
            create: (_) => sl<SenderBloc>(),
            child: child,
          );
        },
        routes: [
          GoRoute(
            path: '/send',
            pageBuilder: (context, state) {
              final extra = state.extra;
              final paths = extra is Map
                  ? (extra['qhtpPaths'] as List?)?.whereType<String>().toList()
                  : null;
              return _qsPage(
                state,
                FilePickerPage(qhtpPaths: paths),
                sharedAxis: false,
              );
            },
            // A relative path only resolves against its *parent* GoRoute, so
            // `fallback`/`local-network`/`qr` have to be declared here, nested
            // under `/send` — they used to sit as siblings of it in this same
            // ShellRoute's list instead, which registered them nowhere at all
            // (not at /send/fallback, not even at /fallback). Every
            // `context.go('/send/qr')` and `context.go('/send/fallback')` call
            // in the sender pages hit go_router's `errorBuilder` ("Page not
            // found") instead of the real page.
            routes: [
              GoRoute(
                path: 'fallback',
                builder: (context, state) {
                  final extra = state.extra as Map<String, int?>?;
                  return NetworkFallbackPage(
                    sessionBytes: extra?['sessionBytes'],
                    limitBytes: extra?['limitBytes'],
                    onBack: () => context.go('/send'),
                    onUseLocalNetwork: () => context.go('/send'),
                    // iOS cannot raise a hotspot from inside an app, so the
                    // button is simply absent there rather than failing when
                    // tapped.
                    onCreateNetwork: LocalHotspotService().canHost
                        ? () {
                            context.read<SenderBloc>().add(StartLocalNetwork());
                            context.go('/send/local-network');
                          }
                        : null,
                  );
                },
              ),
              GoRoute(
                path: 'local-network',
                builder: (context, state) =>
                    LocalNetworkPage(onCancel: () => context.go('/send')),
              ),
              GoRoute(
                path: 'qr',
                pageBuilder: (context, state) => _qsPage(
                  state,
                  const QRDisplayPage(),
                  sharedAxis: true,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/send/bluetooth',
            pageBuilder: (context, state) => _qsPage(
              state,
              const BluetoothSendPage(),
              sharedAxis: true,
            ),
          ),
          GoRoute(
            path: '/send/progress',
            pageBuilder: (context, state) => _qsPage(
              state,
              const SenderProgressPage(),
              sharedAxis: true,
            ),
          ),
        ],
      ),

      // === Receiver Flow ===
      // Wrapped in ShellRoute to share ReceiverBloc across receiver pages
      ShellRoute(
        builder: (context, state, child) {
          return BlocProvider(
            create: (_) => sl<ReceiverBloc>(),
            child: child,
          );
        },
        routes: [
          GoRoute(
            path: '/receive',
            pageBuilder: (context, state) => _qsPage(
              state,
              const QRScanPage(),
              sharedAxis: false,
            ),
          ),
          GoRoute(
            path: '/receive/code',
            pageBuilder: (context, state) {
              final room = state.uri.queryParameters['room'];
              final sig = state.uri.queryParameters['sig'];
              final payload = state.uri.queryParameters['p'];
              String? initial;
              if (payload != null && payload.isNotEmpty) {
                initial = DeepLinkService.buildPayloadLink(
                  payload,
                  name: state.uri.queryParameters['n'],
                  bytes: int.tryParse(state.uri.queryParameters['s'] ?? ''),
                  itemCount:
                      int.tryParse(state.uri.queryParameters['c'] ?? ''),
                );
              } else if (room != null && room.isNotEmpty) {
                initial = (sig != null && sig.isNotEmpty)
                    ? 'directdrop://join?room=$room&sig=${Uri.encodeComponent(sig)}'
                    : 'directdrop://join?room=$room';
              }
              return _qsPage(
                state,
                CodeReceivePage(initialCode: initial),
                sharedAxis: false,
              );
            },
          ),
          GoRoute(
            path: '/receive/preview',
            pageBuilder: (context, state) => _qsPage(
              state,
              // Payload lives in ReceiverBloc after QRCodeScanned — do not
              // require go_router `extra` (null extra used to crash silently).
              const TransferPreviewPage(),
              sharedAxis: true,
            ),
          ),
          GoRoute(
            path: '/receive/download',
            pageBuilder: (context, state) {
              final extra = state.extra as Map<String, dynamic>?;
              return _qsPage(
                state,
                DownloadProgressPage(
                  initialPayload: extra?['payload'] as QRPayload?,
                ),
                sharedAxis: true,
              );
            },
          ),
          GoRoute(
            path: '/receive/complete',
            pageBuilder: (context, state) {
              final extra = state.extra as Map<String, dynamic>?;
              return _qsPage(
                state,
                CompletePage(
                  filePath: extra?['filePath'] as String? ?? '',
                  fileName: extra?['fileName'] as String? ?? 'Unknown',
                  items: (extra?['items'] as List?)?.cast<ReceivedItem>() ??
                      const [],
                ),
                sharedAxis: true,
              );
            },
          ),
        ],
      ),

      GoRoute(
        path: '/settings',
        pageBuilder: (context, state) => _qsPage(
          state,
          const SettingsPage(),
          sharedAxis: true,
        ),
      ),

      // Error page
      GoRoute(
        path: '/error',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return _ErrorPage(
            message:
                extra?['message'] as String? ?? 'An unexpected error occurred',
            canRetry: extra?['canRetry'] as bool? ?? false,
            retryRoute: extra?['retryRoute'] as String?,
          );
        },
      ),
    ],

    // Global error page for unknown routes
    errorBuilder: (context, state) => const _ErrorPage(
      message: 'Page not found',
      canRetry: false,
    ),
  );

  const AppRouter._();
}

/// Generic error page used for routing errors and explicit error navigation.
class _ErrorPage extends StatelessWidget {
  final String message;
  final bool canRetry;
  final String? retryRoute;

  const _ErrorPage({
    required this.message,
    required this.canRetry,
    this.retryRoute,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 80,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 24),
              Text(
                'Oops!',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              if (canRetry && retryRoute != null)
                FilledButton.icon(
                  onPressed: () => context.go(retryRoute!),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.home_rounded),
                label: const Text('Go Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
