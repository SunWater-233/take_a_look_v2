import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../protocol/commands.dart';
import '../theme/theme.dart';

class OnlineTargetPackDialog extends StatefulWidget {
  const OnlineTargetPackDialog({
    required this.controller,
    this.initialQuery = '',
    super.key,
  });

  final TakeALookController controller;
  final String initialQuery;

  @override
  State<OnlineTargetPackDialog> createState() => _OnlineTargetPackDialogState();
}

class _OnlineTargetPackDialogState extends State<OnlineTargetPackDialog> {
  late final _search = TextEditingController(text: widget.initialQuery);
  JsonObject? _job;
  List<JsonObject> _packs = const [];
  String? _error;
  String _resultQuery = '';
  bool _requesting = false;
  bool _searched = false;
  bool _cancelling = false;
  bool get _running => _requesting || _job?['status'] == 'running';

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().length >= 2) {
      unawaited(_start('search'));
    }
  }

  Future<JsonObject> _request(JsonObject params) =>
      widget.controller.requestTargetCatalog('onlineTargetPacks', params);

  Future<void> _start(
    String operation, {
    bool refresh = false,
    JsonObject? pack,
  }) async {
    if (_running) return;
    setState(() {
      _requesting = true;
      _error = null;
      _job = null;
      _cancelling = false;
    });
    try {
      var job = await _request({
        'operation': operation,
        'query': operation == 'download' ? _resultQuery : _search.text.trim(),
        if (refresh) 'refresh': true,
        if (pack != null) 'packId': pack['id'],
      });
      // Sequential polling keeps one request in flight and never blocks the
      // hardware command queue. A job ID prevents a late response replacing it.
      while (mounted) {
        setState(() {
          _job = job;
          _requesting = false;
        });
        if (job['status'] != 'running') break;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
        job = await _request({'operation': 'status', 'jobId': job['jobId']});
      }
      if (!mounted) return;
      if (job['status'] == 'succeeded') {
        final result = Map<String, Object?>.from(job['result']! as Map);
        if (operation == 'download') {
          Navigator.pop(context, result);
        } else {
          setState(() {
            _packs = (result['packs']! as List)
                .map((item) => Map<String, Object?>.from(item as Map))
                .toList();
            _resultQuery = result['query']! as String;
            _searched = true;
            if ((result['total']! as int) > _packs.length) {
              _error = '匹配较多，仅显示前 ${_packs.length} 个芯片包，请缩小搜索范围。';
            }
            if (result['warning'] case final String warning
                when warning.isNotEmpty) {
              _error = warning;
            }
          });
        }
      } else if (job['status'] == 'failed') {
        setState(() => _error = job['message'] as String? ?? '操作失败，请重试。');
      }
    } on Object catch (error) {
      if (mounted) {
        final job = _job;
        if (job?['status'] == 'running') {
          unawaited(_cancelJob(job!));
        }
        setState(() {
          _job = null;
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _cancelJob(JsonObject job) async {
    try {
      await _request({'operation': 'cancel', 'jobId': job['jobId']});
    } on Object catch (_) {
      // A disappearing backend is already reported by the polling request.
    }
  }

  Future<void> _cancel() async {
    if (_cancelling || _job == null) return;
    setState(() => _cancelling = true);
    await _cancelJob(_job!);
  }

  @override
  void dispose() {
    if (_job?['status'] == 'running') unawaited(_cancelJob(_job!));
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final received = (_job?['bytesReceived'] as num?)?.toInt() ?? 0;
    final total = (_job?['totalBytes'] as num?)?.toInt() ?? 0;
    final downloading = _job?['phase'] == 'download';
    return PopScope(
      canPop: !_running,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        constraints: BoxConstraints(maxWidth: math.min(800, size.width - 32)),
        child: SizedBox(
          width: math.min(800, size.width - 32),
          height: math.min(580, size.height - 32),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('在线下载芯片包', style: talStrong.copyWith(fontSize: 17)),
                const SizedBox(height: 8),
                const Text('搜索芯片型号、厂商或芯片包。下载完成后自动加入芯片库。', style: talMuted),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('online-target-search'),
                  controller: _search,
                  enabled: !_running,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '例如 STM32H723、GD32E508、nRF52840',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onSubmitted: (_) => _start('search'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TalButton(
                      key: const ValueKey('search-online-target-packs'),
                      variant: TalButtonVariant.filled,
                      onPressed: _running ? null : () => _start('search'),
                      child: const Text('搜索'),
                    ),
                    TalButton(
                      key: const ValueKey('refresh-online-target-index'),
                      onPressed: _running
                          ? null
                          : () => _start('search', refresh: true),
                      child: const Text('更新在线索引'),
                    ),
                    if (_running)
                      TalButton(
                        key: const ValueKey('cancel-online-target-job'),
                        onPressed: _cancelling || _job == null ? null : _cancel,
                        child: Text(_cancelling ? '正在取消…' : '取消任务'),
                      ),
                  ],
                ),
                if (_running) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: downloading && total > 0
                        ? (received / total).clamp(0.0, 1.0)
                        : null,
                    minHeight: 3,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_job?['message'] ?? '正在启动任务…'}'
                    '${downloading ? '  ${_bytes(received)}${total > 0 ? ' / ${_bytes(total)}' : ''}' : ''}',
                    style: talMuted,
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: talMuted.copyWith(color: TalColors.warning),
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: _packs.isEmpty
                      ? Center(
                          child: Text(
                            _running
                                ? '正在查询在线芯片库…'
                                : _searched
                                ? '没有匹配的芯片包。请尝试型号前缀，或更新在线索引。'
                                : '输入型号开始搜索。首次搜索会下载在线索引。',
                            style: talMuted,
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.separated(
                          itemCount: _packs.length,
                          separatorBuilder: (_, _) => const Divider(height: 24),
                          itemBuilder: (context, index) {
                            final pack = _packs[index];
                            final installed =
                                (pack['installedPackId'] as String? ?? '')
                                    .isNotEmpty;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${pack['vendor']}.${pack['name']}  ${pack['version']}',
                                  style: talStrong,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${pack['matchCount']} 个匹配芯片 · ${(pack['matchingParts']! as List).join('、')}',
                                  style: talMuted,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                TalButton.icon(
                                  key: ValueKey(
                                    'download-online-pack-${pack['id']}',
                                  ),
                                  icon: Icon(
                                    installed ? Icons.check : Icons.download,
                                    size: 17,
                                  ),
                                  label: Text(installed ? '已安装，查看芯片' : '下载并安装'),
                                  onPressed: _running
                                      ? null
                                      : () {
                                          if (installed) {
                                            Navigator.pop(context, <
                                              String,
                                              Object?
                                            >{
                                              'packId': pack['installedPackId'],
                                              'partNumber':
                                                  (pack['matchingParts']!
                                                          as List)
                                                      .first,
                                            });
                                          } else {
                                            unawaited(
                                              _start('download', pack: pack),
                                            );
                                          }
                                        },
                                ),
                              ],
                            );
                          },
                        ),
                ),
                const Divider(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: TalButton(
                    onPressed: _running ? null : () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _bytes(int value) => '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
