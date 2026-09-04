import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/core/media/media_library.dart';
import 'package:quickshare/core/storage/folder_picker.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/presentation/pages/media_picker_page.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_preconditions.dart';
import 'package:quickshare/features/sender/presentation/widgets/wifi_speed_prompt.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class FilePickerPage extends StatefulWidget {
  final List<String>? qhtpPaths;

  const FilePickerPage({super.key, this.qhtpPaths});

  @override
  State<FilePickerPage> createState() => _FilePickerPageState();
}

class _FilePickerPageState extends State<FilePickerPage> {
  TransportType _selectedMode = TransportType.wifi;
  bool _selectionInFlight = false;

  @override
  void initState() {
    super.initState();
    final paths = widget.qhtpPaths;
    if (paths != null && paths.isNotEmpty) {
      _selectionInFlight = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context
              .read<SenderBloc>()
              .add(StartQhtpSend(paths, mode: _selectedMode));
        }
      });
    }
  }

  /// Everything sendable, in one trip: files and folders, mixed, however
  /// many.
  ///
  /// There used to be two buttons here, and the split was never real. iOS
  /// opens the same browser for both, and `NSOpenPanel` has always been able
  /// to return a mixed selection — only `file_picker`'s API forced the user
  /// to decide, before the dialog opened, whether what they were about to
  /// point at was a file or a folder. Getting that wrong meant backing out
  /// and starting again, and on iOS the folders-only mode drew no checkboxes
  /// at all, so several folders could not be said even in principle.
  ///
  /// Multi-select rather than one at a time, because every wire protocol
  /// here carries a manifest: nothing has to be bundled into a single object
  /// first, which is equally why a whole tree costs no more to express than
  /// one file.
  ///
  /// Media is not rejected here. `image_picker` hands back a transcoded copy
  /// on iOS, and re-encoding somebody's photo is exactly what this app must
  /// not do — but that never applied to this route: the document picker
  /// returns the file itself, so a `.jpg` chosen here is already the
  /// original. [_pickMedia] stays for reaching the photo library, which the
  /// document browser cannot see into.
  Future<void> _pickItems() async {
    if (_selectionInFlight) return;
    setState(() => _selectionInFlight = true);
    final paths = await const FolderPicker()
        .pickItems(dialogTitle: AppLocalizations.of(context).pickerSendFiles);

    if (paths.isEmpty) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }
    if (!mounted) return;

    context.read<SenderBloc>().add(StartQhtpSend(paths, mode: _selectedMode));
  }

  /// Photos and videos, straight from the library and untouched.
  ///
  /// Its own screen rather than the system picker: `image_picker` hands back
  /// a transcoded copy on iOS, and sending a re-encoded photo is exactly what
  /// this app is supposed not to do.
  Future<void> _pickMedia() async {
    if (_selectionInFlight) return;
    setState(() => _selectionInFlight = true);

    final entries = await Navigator.of(context).push<List<MediaEntry>>(
      MaterialPageRoute(builder: (_) => const MediaPickerPage()),
    );

    if (entries == null || entries.isEmpty) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }
    if (mounted) {
      context.read<SenderBloc>().add(StartQhtpSend(
            entries.map((e) => e.file.path).toList(growable: false),
            mode: _selectedMode,
          ));
    }
  }

  /// Picking a mode is gated on what the mode needs: Wi-Fi on a live local
  /// network, Bluetooth on a powered radio, Internet on any connection at
  /// all. Without that, selecting the mode already creates a session that
  /// cannot work.
  ///
  /// Picking Bluetooth is additionally the moment to ask about Wi-Fi, not
  /// the moment the files are already chosen: the direct link is what makes
  /// this mode fast, and it needs the Wi-Fi radio awake — not a network, just
  /// the radio.
  Future<void> _selectMode(TransportType type) async {
    if (_selectionInFlight) return;
    final allowed = await TransportPreconditions.ensure(context, type);
    if (!allowed || !mounted) return;
    setState(() => _selectedMode = type);
    if (type == TransportType.bluetooth) {
      await const WifiSpeedPrompt().ask(context);
    }
  }

  /// Folders, on the platforms that cannot browse for both at once.
  ///
  /// Windows and Linux only. `IFileOpenDialog` picks files *or* folders per
  /// invocation and GTK's chooser is the same, so there is no single act of
  /// browsing there to fold this into — and dropping the button would drop
  /// folder sending on those platforms entirely. macOS and iOS reach folders
  /// through [_pickItems] like everything else.
  Future<void> _pickFolder() async {
    if (_selectionInFlight) return;
    setState(() => _selectionInFlight = true);
    final folders = await const FolderPicker()
        .pick(dialogTitle: AppLocalizations.of(context).pickerSelectFolder);
    if (folders.isNotEmpty && mounted) {
      context
          .read<SenderBloc>()
          .add(StartQhtpSend(folders, mode: _selectedMode));
    } else if (mounted) {
      setState(() => _selectionInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          AppLocalizations.of(context).pickerTitle,
          style: GoogleFonts.inter(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
      ),
      body: BlocConsumer<SenderBloc, SenderState>(
        listener: (context, state) {
          // This screen is not rebuilt when the user comes back to it.
          //
          // `/send/qr` is a route *under* `/send`, so the QR code is pushed on
          // top of this page rather than replacing it: the state object here
          // survives the whole trip and is still holding whatever it held
          // when the session started. Popping back therefore revealed a page
          // that believed a selection was still in flight, and every button
          // on it — both pickers and all three mode tiles — returned at its
          // first line. The screen looked alive and answered nothing.
          //
          // Leaving the QR screen cancels the session, so the bloc says when
          // that is over. Anything other than a session being set up means
          // this page is usable again.
          if (state is! ServerStarting && _selectionInFlight) {
            _selectionInFlight = false;
          }

          if (state is FileSelected) {
            // As soon as file is chosen, automatically start sending with chosen transport mode
            context.read<SenderBloc>().add(
                  StartSendingWithTransport(state.file, _selectedMode),
                );
          } else if (state is QRReady) {
            context.go('/send/qr');
          } else if (state is BluetoothAdvertising) {
            context.go('/send/bluetooth');
          } else if (state is RelayTooExpensive) {
            _selectionInFlight = false;
            context.go('/send/fallback', extra: <String, int?>{
              'sessionBytes': state.sessionBytes,
              'limitBytes': state.limitBytes,
            });
          } else if (state is NoUsablePathFound) {
            _selectionInFlight = false;
            context.go('/send/fallback', extra: const <String, int?>{
              'sessionBytes': null,
              'limitBytes': null,
            });
          } else if (state is SenderError) {
            _selectionInFlight = false;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: AppColors.error,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        },
        builder: (context, state) {
          if (state is ServerStarting) return _indexingView(state);

          return ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 580),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Mode selector header
                      Text(
                        AppLocalizations.of(context).pickerStepMethod,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.90),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Mode choices: Wi-Fi, Bluetooth, Internet.
                      // RadioGroup owns the selection now; the individual
                      // Radio widgets no longer carry groupValue/onChanged.
                      RadioGroup<TransportType>(
                        groupValue: _selectedMode,
                        onChanged: (val) {
                          if (val != null) _selectMode(val);
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildModeTile(
                              type: TransportType.wifi,
                              title: AppLocalizations.of(context)
                                  .pickerMethodWifiTitle,
                              subtitle: AppLocalizations.of(context)
                                  .pickerMethodWifiSubtitle,
                              icon: Icons.wifi_rounded,
                            ),
                            const SizedBox(height: 10),
                            if (defaultTargetPlatform == TargetPlatform.macOS ||
                                defaultTargetPlatform == TargetPlatform.iOS ||
                                defaultTargetPlatform ==
                                    TargetPlatform.android ||
                                defaultTargetPlatform ==
                                    TargetPlatform.windows ||
                                defaultTargetPlatform ==
                                    TargetPlatform.linux) ...[
                              _buildModeTile(
                                type: TransportType.bluetooth,
                                title: AppLocalizations.of(context)
                                    .pickerMethodBluetoothTitle,
                                subtitle: AppLocalizations.of(context)
                                    .pickerMethodBluetoothSubtitle,
                                icon: Icons.bluetooth_rounded,
                              ),
                              const SizedBox(height: 10),
                            ],
                            _buildModeTile(
                              type: TransportType.internet,
                              title: AppLocalizations.of(context)
                                  .pickerMethodInternetTitle,
                              subtitle: AppLocalizations.of(context)
                                  .pickerMethodInternetSubtitle,
                              icon: Icons.language_rounded,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 28),

                      Text(
                        AppLocalizations.of(context).pickerStepWhat,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.90),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // One entry point per place things actually live: the
                      // photo library, which no document browser can see
                      // into, and the file system, which holds files and
                      // folders alike. The old third button asked the user
                      // to classify their own selection before the dialog
                      // even opened; see [_pickItems].
                      if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                        _buildPickerCard(
                          title: AppLocalizations.of(context).pickerSendMedia,
                          icon: Icons.photo_library_rounded,
                          gradient: const LinearGradient(
                            colors: [AppColors.primary, AppColors.primaryDeep],
                          ),
                          onTap: _pickMedia,
                        ),
                        const SizedBox(height: 16),
                      ],

                      if (FolderPicker.supportsUnifiedPick)
                        _buildPickerCard(
                          title: AppLocalizations.of(context).pickerSendFiles,
                          subtitle: AppLocalizations.of(context)
                              .pickerSendFilesHint,
                          icon: Icons.folder_copy_rounded,
                          gradient: const LinearGradient(
                            colors: [
                              AppColors.secondary,
                              AppColors.secondaryDark
                            ],
                          ),
                          onTap: _pickItems,
                        ).animate().fadeIn(duration: 350.ms)
                      else
                        // Windows and Linux: their common dialogs pick files
                        // or folders per invocation, never both, so the split
                        // survives where the platform still imposes it.
                        Row(
                          children: [
                            Expanded(
                              child: _buildPickerCard(
                                title: AppLocalizations.of(context)
                                    .pickerSelectFile,
                                icon: Icons.insert_drive_file_rounded,
                                gradient: const LinearGradient(
                                  colors: [
                                    AppColors.secondary,
                                    AppColors.secondaryDark
                                  ],
                                ),
                                onTap: _pickItems,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _buildPickerCard(
                                title: AppLocalizations.of(context)
                                    .pickerSelectFolder,
                                icon: Icons.folder_open_rounded,
                                gradient: const LinearGradient(
                                  colors: [
                                    AppColors.primary,
                                    AppColors.primaryDeep
                                  ],
                                ),
                                onTap: _pickFolder,
                              ),
                            ),
                          ],
                        ).animate().fadeIn(duration: 350.ms),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The "indexing" screen, with a count and a way out.
  ///
  /// Both halves were missing, and together they made a slow selection
  /// indistinguishable from a broken app. Walking a folder on a phone's file
  /// provider is one directory read after another and can genuinely take
  /// minutes, but nothing on screen moved while it happened — and there was
  /// no back button, no cancel, and every control underneath was disabled
  /// behind the in-flight guard. Whatever went wrong, the only way out was
  /// to kill the app.
  Widget _indexingView(ServerStarting state) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TransferPhaseLoader(
            phaseLabel: l10n.pickerIndexing,
            detail: state.indexedItems > 0
                ? l10n.pickerIndexingFound(
                    state.indexedItems, _formatBytes(state.indexedBytes))
                : l10n.pickerStartingSession,
            icon: Icons.cloud_upload_outlined,
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: _cancelIndexing,
            icon: const Icon(Icons.close_rounded, color: Colors.white70),
            label: Text(
              l10n.commonCancel,
              style: GoogleFonts.inter(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  /// Abandons a session that is still being set up.
  ///
  /// [CancelSending] does the teardown and, just as importantly, invalidates
  /// the setup still in flight — without that the walk would finish some time
  /// later and push the user to a QR screen for the session they had just
  /// left.
  void _cancelIndexing() {
    _selectionInFlight = false;
    context.read<SenderBloc>().add(CancelSending());
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }

  Widget _buildPickerCard({
    required String title,
    required IconData icon,
    required LinearGradient gradient,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            height: 140,
            decoration: BoxDecoration(
              color: const Color.fromRGBO(255, 255, 255, 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color.fromRGBO(255, 255, 255, 0.30),
                width: 1.2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: gradient,
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeTile({
    required TransportType type,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isSelected = _selectedMode == type;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: InkWell(
          onTap: () => _selectMode(type),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color.fromRGBO(34, 211, 238, 0.15)
                  : const Color.fromRGBO(255, 255, 255, 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? AppColors.primary
                    : const Color.fromRGBO(255, 255, 255, 0.20),
                width: isSelected ? 1.8 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: isSelected
                      ? AppColors.primary
                      : Colors.white.withValues(alpha: 0.70),
                  size: 24,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                Radio<TransportType>(
                  value: type,
                  activeColor: AppColors.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
