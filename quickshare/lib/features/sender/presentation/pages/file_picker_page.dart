import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/core/media/media_library.dart';
import 'package:quickshare/core/storage/folder_picker.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/byte_format.dart';
import 'package:quickshare/features/sender/presentation/pages/media_picker_page.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_choice.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_preconditions.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

/// Where files are chosen, for a transport that was already chosen on the
/// home screen.
///
/// The screen used to start with a list of transports to pick from. That
/// question is asked on the home screen now and arrives in the address
/// (`/send?mode=internet`, see `SendRoutes`), so what is left here is only
/// what to send.
class FilePickerPage extends StatefulWidget {
  final List<String>? qhtpPaths;

  /// The transport this screen sends over. Null only when a page is built
  /// without one — a route never does, because the address is checked before
  /// it gets here — and then it is the local network.
  final TransportType? mode;

  const FilePickerPage({super.key, this.qhtpPaths, this.mode});

  @override
  State<FilePickerPage> createState() => _FilePickerPageState();
}

class _FilePickerPageState extends State<FilePickerPage> {
  late TransportType _mode = widget.mode ?? TransportType.wifi;

  bool _selectionInFlight = false;

  @override
  void initState() {
    super.initState();
    final paths = widget.qhtpPaths;
    if (paths != null && paths.isNotEmpty) {
      // A drag-and-drop onto the home card. It arrives here already chosen,
      // so it goes through the same gate a picked selection does.
      _selectionInFlight = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startSend(paths);
      });
    }
  }

  @override
  void didUpdateWidget(FilePickerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The pages under `/send` (the QR code, the progress screen) are pushed on
    // top of this one, and the router rebuilds it with an address that has no
    // `mode` in it. That must not change what this screen sends over; only an
    // address that actually names a transport does.
    final next = widget.mode;
    if (next != null && next != _mode) _mode = next;
  }

  /// Starts a session for [paths] over this screen's transport — after
  /// checking that transport can actually run.
  ///
  /// Every route into a transfer passes through here, and it is the one that
  /// cannot be skipped: a drag-and-drop arrives with its files already
  /// chosen, and the radio can be switched off while the system file dialog is
  /// open. Before this check existed, dropping a file with Wi-Fi off built a
  /// session and a QR code for a network that was not there.
  ///
  /// The pickers run the same check *before* they open ([_transportReady]),
  /// so in the ordinary case nobody browses for files a transport was never
  /// going to be able to send.
  Future<void> _startSend(List<String> paths) async {
    if (!mounted) return;
    if (!await _transportReady()) {
      if (mounted) {
        // The gate has already told the person what is missing. Release the
        // guard so they can try again once they have fixed it.
        setState(() => _selectionInFlight = false);
      }
      return;
    }
    if (!mounted) return;
    context.read<SenderBloc>().add(StartQhtpSend(paths, mode: _mode));
  }

  /// True when this screen's transport can run right now. Otherwise the person
  /// has been told what is missing and nothing should be started.
  ///
  /// Wi-Fi needs a live local network, Bluetooth a powered radio (and, where
  /// the direct link is Apple's, the Wi-Fi radio awake), the internet any
  /// connection at all — see [TransportPreconditions.ensure].
  Future<bool> _transportReady() async {
    final allowed = await TransportPreconditions.ensure(context, _mode);
    if (!allowed) {
      AppLogger.info('${_mode.name} is not usable here', tag: 'SENDER');
    }
    return allowed && mounted;
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
    if (!await _transportReady()) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }
    if (!mounted) return;
    final paths = await const FolderPicker()
        .pickItems(dialogTitle: AppLocalizations.of(context).pickerSendFiles);

    if (paths.isEmpty) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }
    await _startSend(paths);
  }

  /// Photos and videos, straight from the library and untouched.
  ///
  /// Its own screen rather than the system picker: `image_picker` hands back
  /// a transcoded copy on iOS, and sending a re-encoded photo is exactly what
  /// this app is supposed not to do.
  Future<void> _pickMedia() async {
    if (_selectionInFlight) return;
    setState(() => _selectionInFlight = true);
    if (!await _transportReady()) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }
    if (!mounted) return;

    final entries = await Navigator.of(context).push<List<MediaEntry>>(
      MaterialPageRoute(builder: (_) => const MediaPickerPage()),
    );

    if (entries == null || entries.isEmpty) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }
    await _startSend(
        entries.map((e) => e.file.path).toList(growable: false));
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
    if (!await _transportReady()) {
      if (mounted) setState(() => _selectionInFlight = false);
      return;
    }
    if (!mounted) return;
    final folders = await const FolderPicker()
        .pick(dialogTitle: AppLocalizations.of(context).pickerSelectFolder);
    if (folders.isNotEmpty) {
      await _startSend(folders);
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
        // The way this screen sends, so it is plain which one the home screen
        // opened. Two lines are allowed: "Передача по локальной сети" does not
        // fit one at a phone's width with larger text.
        toolbarHeight: 64,
        title: Text(
          AppLocalizations.of(context).transportTitle(_mode),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
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
          // on it — every picker it has, and the mode tiles it had then —
          // returned at its first line. The screen looked alive and answered nothing.
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
                  StartSendingWithTransport(state.file, _mode),
                );
          } else if (state is QRReady) {
            context.go('/send/qr');
          } else if (state is BluetoothAdvertising) {
            context.go('/send/bluetooth');
          } else if (state is RelayTooExpensive) {
            _selectionInFlight = false;
            context.go('/send/fallback', extra: <String, Object?>{
              'sessionBytes': state.sessionBytes,
              'limitBytes': state.limitBytes,
            });
          } else if (state is NoUsablePathFound) {
            _selectionInFlight = false;
            context.go('/send/fallback', extra: <String, Object?>{
              'sessionBytes': null,
              'limitBytes': null,
              // Why, so the page can say which of four things happened
              // instead of blaming the relay for all of them.
              'noPathCode': state.failureCode,
            });
          } else if (state is SenderError) {
            _selectionInFlight = false;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  localizedFailure(
                      AppLocalizations.of(context),
                      code: state.code,
                      fallback: state.message),
                  style: const TextStyle(color: Colors.white),
                ),
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
                    state.indexedItems, ByteFormat.size(state.indexedBytes))
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
}
