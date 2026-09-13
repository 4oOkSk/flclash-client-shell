import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/diagnostic_journal.dart';
import 'package:fl_clash/common/diagnostic_upload.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DiagnosticExportItem extends ConsumerStatefulWidget {
  final CoreController? controller;
  final DiagnosticJournal? journal;

  const DiagnosticExportItem({super.key, this.controller, this.journal});

  @override
  ConsumerState<DiagnosticExportItem> createState() =>
      _DiagnosticExportItemState();
}

class _DiagnosticExportItemState extends ConsumerState<DiagnosticExportItem> {
  bool _busy = false;
  bool _saving = false;
  double _progress = 0;
  String? _uploadedUrl;
  DiagnosticUpload? _upload;

  DiagnosticJournal get _journal => widget.journal ?? diagnosticJournal;

  Future<List<int>> _snapshot() async {
    final controller = widget.controller ?? coreController;
    _journal.record('status', {
      'phase': ref.read(coreStatusProvider).name,
      'tunRequested': system.isAndroid
          ? true
          : ref.read(patchClashConfigProvider).tun.enable,
      'mode': ref
          .read(privateRouteStatusProvider)
          .applied
          ?.managedRouting
          ?.mode
          .wireValue,
      'ipv6': ref.read(patchClashConfigProvider).ipv6,
    });
    try {
      final status = parseClientRuntimeDiagnostics(
        await controller.clientDiagnostics(),
      );
      _journal.record('status', {
        'source': 'core',
        'session': status['client.sessionPresent'],
        'dnsCompleted': status['dns.completed'],
        'dnsFailed': status['dns.failed'],
        'protectFailures': status['vpn.protectFailures'],
      });
      for (final message in await controller.getPlatformDiagnosticLogs()) {
        _journal.observe(message, source: 'platform');
      }
    } catch (_) {
      _journal.record('status', {'source': 'core', 'result': 'failed'});
    }
    return _journal.snapshot();
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      if (_uploadedUrl == null) {
        _journal.record('upload', {'result': 'begin'});
        final bytes = await _snapshot();
        if (!mounted) return;
        final controller = widget.controller ?? coreController;
        final upload = DiagnosticUpload(
          (body) => controller.clientDiagnosticUpload(kClientApiBase, body),
        );
        _upload = upload;
        _uploadedUrl = await upload.upload(
          bytes,
          progress: (value) {
            if (mounted) setState(() => _progress = value);
          },
        );
        _journal.record('upload', {'result': 'success'});
      }
      if (!mounted) return;
      var copied = false;
      try {
        await Clipboard.setData(ClipboardData(text: _uploadedUrl!));
        copied = true;
      } catch (_) {}
      if (!mounted) return;
      setState(() => _upload = null);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.appLocalizations.clientDiagnosticUploaded),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copied
                    ? context.appLocalizations.clientDiagnosticLinkCopied
                    : context.appLocalizations.clientDiagnosticCopyLinkFailed,
              ),
              const SizedBox(height: 12),
              SelectableText(_uploadedUrl!),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.appLocalizations.confirm),
            ),
          ],
        ),
      );
      if (copied) _uploadedUrl = null;
    } catch (error) {
      final cancelled =
          error is DiagnosticUploadException && error.code == 'cancelled';
      _journal.record('upload', {'result': cancelled ? 'cancelled' : 'failed'});
      if (mounted && !cancelled) {
        context.showSnackBar(
          context.appLocalizations.clientCopyDiagnosticsFailed,
        );
      }
    } finally {
      _upload = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _saving = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _saving = true;
    });
    try {
      final bytes = await _snapshot();
      await picker.saveFile(
        'HarborProxy-diagnostics.jsonl',
        Uint8List.fromList(bytes),
      );
    } catch (_) {
      if (mounted) {
        context.showSnackBar(
          context.appLocalizations.clientDiagnosticSaveFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _saving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _upload?.cancelled = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.appLocalizations;
    return Column(
      children: [
        ListItem(
          leading: const Icon(Icons.cloud_upload_outlined),
          title: Text(text.clientCopyDiagnostics),
          subtitle: Text(
            _busy && _upload != null
                ? (_progress < 1
                      ? text.clientDiagnosticUploading(
                          (_progress * 100).round(),
                        )
                      : text.clientDiagnosticProcessing)
                : text.clientCopyDiagnosticsHint,
          ),
          trailing: _busy && !_saving && _uploadedUrl == null
              ? SizedBox(
                  width: 40,
                  height: 40,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      if (_upload != null)
                        IconButton(
                          tooltip: text.cancel,
                          iconSize: 16,
                          onPressed: () {
                            _upload?.cancelled = true;
                          },
                          icon: const Icon(Icons.close),
                        ),
                    ],
                  ),
                )
              : null,
          onTap: _busy ? null : _share,
        ),
        const ClientListDivider(),
        ListItem(
          leading: const Icon(Icons.save_alt_outlined),
          title: Text(text.clientDiagnosticSave),
          subtitle: Text(text.clientDiagnosticSaveHint),
          trailing: _saving
              ? const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : null,
          onTap: _busy ? null : _save,
        ),
      ],
    );
  }
}
