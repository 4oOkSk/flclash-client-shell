import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import 'item.dart';

class ConnectionsView extends ConsumerStatefulWidget {
  final Future<List<TrackerInfo>> Function()? connectionsReader;
  final Future<void> Function(String)? connectionCloser;
  final Future<void> Function()? allConnectionsCloser;

  const ConnectionsView({
    super.key,
    @visibleForTesting this.connectionsReader,
    @visibleForTesting this.connectionCloser,
    @visibleForTesting this.allConnectionsCloser,
  });

  @override
  ConsumerState<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends ConsumerState<ConnectionsView>
    with WidgetsBindingObserver, ActivePollingMixin<ConnectionsView> {
  final _connectionsStateNotifier = ValueNotifier<TrackerInfosState>(
    const TrackerInfosState(),
  );
  final ScrollController _scrollController = ScrollController();
  final _closing = <String>{};
  bool _closingAll = false;
  bool _stale = false;
  int _readRevision = 0;

  @override
  Duration get pollInterval => const Duration(seconds: 1);

  List<Widget> _buildActions() {
    return [
      if (_stale)
        IconButton(
          tooltip: context.appLocalizations.retry,
          onPressed: _refreshConnections,
          icon: const Icon(Icons.refresh),
        ),
      IconButton(
        tooltip: context.appLocalizations.closeAllConnections,
        onPressed: _closingAll || _closing.isNotEmpty ? null : _closeAll,
        icon: _closingAll
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.delete_sweep_outlined),
      ),
    ];
  }

  void _onSearch(String value) {
    _connectionsStateNotifier.value = _connectionsStateNotifier.value.copyWith(
      query: value,
    );
  }

  void _onKeywordsUpdate(List<String> keywords) {
    _connectionsStateNotifier.value = _connectionsStateNotifier.value.copyWith(
      keywords: keywords,
    );
  }

  @override
  Future<void> poll(PollGuard isCurrent) => _refreshConnections(isCurrent);

  Future<void> _refreshConnections([PollGuard? guard]) async {
    if (!mounted) return;
    final revision = ++_readRevision;
    bool current() =>
        mounted && revision == _readRevision && (guard?.call() ?? true);
    try {
      final connectionsReader = widget.connectionsReader;
      final trackerInfos = connectionsReader != null
          ? await connectionsReader()
          : await coreController.getConnections();
      if (!current()) return;
      if (_stale) setState(() => _stale = false);
      _applyConnections(trackerInfos);
    } catch (error) {
      commonPrint.log(
        'updateConnections error: ${error.runtimeType}',
        logLevel: coreFailureLogLevel(error),
      );
      if (current() && !_stale) setState(() => _stale = true);
    }
  }

  void _applyConnections(List<TrackerInfo> trackerInfos) {
    _connectionsStateNotifier.value = _connectionsStateNotifier.value.copyWith(
      trackerInfos: trackerInfos,
    );
  }

  Future<void> _handleCloseConnection(String id) async {
    if (_closingAll || _closing.contains(id)) return;
    setState(() => _closing.add(id));
    try {
      if (widget.connectionCloser case final close?) {
        await close(id);
      } else {
        await coreController.closeConnection(id);
      }
      await _refreshConnections();
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.connectionCloseFailed);
      }
    } finally {
      if (mounted) setState(() => _closing.remove(id));
    }
  }

  Future<void> _closeAll() async {
    if (_closingAll || _closing.isNotEmpty) return;
    setState(() => _closingAll = true);
    try {
      final text = context.appLocalizations;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(text.closeAllConnections),
          content: Text(text.closeAllConnectionsConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(text.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(text.closeAllConnections),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      if (widget.allConnectionsCloser case final close?) {
        await close();
      } else {
        await coreController.closeConnections();
      }
      await _refreshConnections();
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.connectionCloseFailed);
      }
    } finally {
      if (mounted) setState(() => _closingAll = false);
    }
  }

  @override
  void dispose() {
    _connectionsStateNotifier.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      title: appLocalizations.connections,
      onKeywordsUpdate: _onKeywordsUpdate,
      searchState: AppBarSearchState(onSearch: _onSearch),
      actions: _buildActions(),
      body: Column(
        children: [
          if (_stale && _connectionsStateNotifier.value.trackerInfos.isNotEmpty)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      Icons.history,
                      size: 18,
                      color: context.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        appLocalizations.connectionSnapshotStale,
                        style: context.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ValueListenableBuilder<TrackerInfosState>(
              valueListenable: _connectionsStateNotifier,
              builder: (context, state, _) {
                final connections = state.list;
                if (connections.isEmpty) {
                  return NullStatus(
                    label: _stale
                        ? appLocalizations.connectionReadFailed
                        : appLocalizations.nullTip(
                            appLocalizations.connections,
                          ),
                    illustration: const ConnectionEmptyIllustration(),
                  );
                }
                return SuperListView.separated(
                  controller: _scrollController,
                  itemCount: connections.length,
                  separatorBuilder: (_, _) => const Divider(height: 0),
                  itemBuilder: (_, index) {
                    final trackerInfo = connections[index];
                    return TrackerInfoItem(
                      key: Key(trackerInfo.id),
                      trackerInfo: trackerInfo,
                      onClickKeyword: (value) {
                        context.commonScaffoldState?.addKeyword(value);
                      },
                      trailing: IconButton(
                        tooltip: appLocalizations.close,
                        icon: _closing.contains(trackerInfo.id)
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.close),
                        onPressed:
                            _closingAll || _closing.contains(trackerInfo.id)
                            ? null
                            : () => _handleCloseConnection(trackerInfo.id),
                      ),
                      detailTitle: appLocalizations.details(
                        appLocalizations.connection,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
