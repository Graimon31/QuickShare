import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mime/mime.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/core/media/media_library.dart';
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

  /// Files, any number of them.
  ///
  /// Multi-select rather than one at a time: every wire protocol here
  /// carries a manifest, so nothing has to be bundled into a single object
  /// first — which is equally why [_pickFolder] can hand over a whole tree.
  Future<void> _pickFile() async {
    if (_selectionInFlight) return;
    setState(() => _selectionInFlight = true);
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = result?.files
        .map((f) => f.path)
        .whereType<String>()
        .toList(growable: false);

    if (paths == null || paths.isEmpty) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }

    // "Files" means files that are not photos or videos. No system picker can
    // express that filter, so media is rejected after the fact instead.
    final kept = <String>[];
    var mediaSkipped = false;
    for (final path in paths) {
      final mime = lookupMimeType(path) ?? '';
      if (mime.startsWith('image/') || mime.startsWith('video/')) {
        mediaSkipped = true;
      } else {
        kept.add(path);
      }
    }
    if (!mounted) return;
    if (mediaSkipped) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).pickerFilesMediaRejected),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    if (kept.isEmpty) {
      setState(() => _selectionInFlight = false);
      return;
    }

    context.read<SenderBloc>().add(StartQhtpSend(kept, mode: _selectedMode));
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

  Future<void> _pickFolder() async {
    if (_selectionInFlight) return;
    setState(() => _selectionInFlight = true);
    final folderPath = await FilePicker.platform.getDirectoryPath();
    if (folderPath != null && mounted) {
      context
          .read<SenderBloc>()
          .add(StartQhtpSend([folderPath], mode: _selectedMode));
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
          if (state is ServerStarting) {
            return Center(
              child: TransferPhaseLoader(
                phaseLabel: AppLocalizations.of(context).pickerIndexing,
                detail: AppLocalizations.of(context).pickerStartingSession,
                icon: Icons.cloud_upload_outlined,
              ),
            );
          }

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

                      if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                        _buildPickerCard(
                          title:
                              AppLocalizations.of(context).pickerPhotosVideos,
                          icon: Icons.photo_library_rounded,
                          gradient: const LinearGradient(
                            colors: [AppColors.primary, AppColors.primaryDeep],
                          ),
                          onTap: _pickMedia,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Select File / Select Folder (each action immediately starts transfer).
                      Row(
                        children: [
                          Expanded(
                            child: _buildPickerCard(
                              title:
                                  AppLocalizations.of(context).pickerSelectFile,
                              icon: Icons.insert_drive_file_rounded,
                              gradient: const LinearGradient(
                                colors: [
                                  AppColors.secondary,
                                  AppColors.secondaryDark
                                ],
                              ),
                              onTap: _pickFile,
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

  Widget _buildPickerCard({
    required String title,
    required IconData icon,
    required LinearGradient gradient,
    required VoidCallback onTap,
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
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
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
