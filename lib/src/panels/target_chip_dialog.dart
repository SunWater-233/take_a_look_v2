import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/file_pickers.dart';
import '../controller/controller.dart';
import '../models/models.dart' show ConnectionStatus;
import '../models/target_catalog.dart';
import '../protocol/commands.dart';
import '../theme/theme.dart';
import 'online_target_pack_dialog.dart';

Future<void> showTargetChipDialog(
  BuildContext context,
  TakeALookController controller,
) => showTalDialog<void>(
  context: context,
  builder: (_) => TargetChipDialog(controller: controller),
);

class TargetChipDialog extends StatefulWidget {
  const TargetChipDialog({required this.controller, super.key});
  final TakeALookController controller;

  @override
  State<TargetChipDialog> createState() => _TargetChipDialogState();
}

class _TargetChipDialogState extends State<TargetChipDialog> {
  final _search = TextEditingController();
  final _listScroll = ScrollController();
  TargetCatalogData? _catalog;
  String _source = 'all';
  String _vendor = '';
  String _family = '';
  String _packFilter = '';
  String? _selectedId;
  String? _error;
  String? _busy;
  JsonObject? _preview;
  bool _loading = true;
  bool _manage = false;
  bool _refreshPending = false;
  int _loadId = 0;
  late int _revision;
  Object? _searchKey;
  List<TargetChip> _searchResult = const [];

  TakeALookController get controller => widget.controller;
  bool get _canSelect => _busy == null && _preview == null;
  List<TargetChip> get _chips {
    final key = (
      _catalog,
      _search.text,
      _source,
      _vendor,
      _family,
      _packFilter,
    );
    if (_searchKey == key) return _searchResult;
    _searchKey = key;
    return _searchResult =
        _catalog?.search(
          query: _search.text,
          source: _source,
          vendor: _vendor,
          family: _family,
          packId: _packFilter,
        ) ??
        const [];
  }

  TargetChip? get _selected {
    for (final chip in _chips) {
      if (chip.id == _selectedId) return chip;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _revision = controller.targetCatalogRevision;
    controller.targetCatalogChanges.addListener(_catalogChanged);
    controller.connectionChanges.addListener(_connectionChanged);
    unawaited(_load());
  }

  void _catalogChanged() {
    if (_revision == controller.targetCatalogRevision) return;
    _revision = controller.targetCatalogRevision;
    if (_busy != null) {
      _refreshPending = true;
      return;
    }
    unawaited(_load());
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.targetCatalogChanges.removeListener(_catalogChanged);
    controller.connectionChanges.removeListener(_connectionChanged);
    final preview = _preview;
    if (preview != null) unawaited(_discard(preview));
    _search.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final loadId = ++_loadId;
    try {
      final result = await controller.requestTargetCatalog('listTargets');
      if (!mounted || loadId != _loadId) return;
      setState(() {
        _catalog = TargetCatalogData.fromJson(result);
        _error = null;
        _loading = false;
        _selectedId ??= _catalog!.targets
            .where(
              (chip) =>
                  chip.name == controller.targetName &&
                  chip.packId == controller.targetPackId,
            )
            .firstOrNull
            ?.id;
        _ensureVisibleSelection();
      });
    } on Object catch (error) {
      if (mounted && loadId == _loadId) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  void _ensureVisibleSelection() {
    final visible = _chips;
    if (!visible.any((chip) => chip.id == _selectedId)) {
      _selectedId = visible.firstOrNull?.id;
    }
  }

  void _filter(VoidCallback change) {
    setState(() {
      change();
      _ensureVisibleSelection();
    });
    if (_listScroll.hasClients) _listScroll.jumpTo(0);
  }

  Future<void> _action(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      // Import/remove both publish a catalog revision and request a refresh.
      // Merge those invalidations and keep the action busy until it is visible.
      while (mounted && _refreshPending) {
        _refreshPending = false;
        await _load();
      }
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _discard(JsonObject preview) async {
    try {
      await controller.requestTargetCatalog('discardTargetPackPreview', {
        'previewId': preview['previewId'],
      });
    } on Object catch (_) {
      /* Closing a preview must not create a global error. */
    }
  }

  Future<void> _inspect() => _action('正在校验芯片包…', () async {
    final path = await (controller.targetPackPicker ?? pickTargetPack)();
    if (path == null || !mounted) return;
    if (_preview case final preview?) {
      await _discard(preview);
      if (!mounted) return;
      setState(() => _preview = null);
    }
    final result = await controller.requestTargetCatalog('inspectTargetPack', {
      'path': path,
    });
    if (!mounted) {
      await _discard(result);
      return;
    }
    setState(() => _preview = result);
  });

  Future<void> _online() async {
    final result = await showTalDialog<JsonObject>(
      context: context,
      builder: (_) => OnlineTargetPackDialog(
        controller: controller,
        initialQuery: _search.text,
      ),
    );
    if (!mounted || result == null) return;
    await _action('正在更新芯片库…', () async {
      setState(() {
        _manage = false;
        _source = 'pack';
        _packFilter = result['packId'] as String;
        _vendor = '';
        _family = '';
        _search.text = result['partNumber'] as String? ?? '';
        _selectedId = null;
      });
      _refreshPending = true;
    });
  }

  Future<void> _import() => _action('正在导入芯片包…', () async {
    final preview = _preview;
    if (preview == null) return;
    final result = await controller.requestTargetCatalog('importTargetPack', {
      'previewId': preview['previewId'],
    });
    if (!mounted) return;
    setState(() {
      _preview = null;
      _manage = false;
      // Preserve the query that led the user to import a missing device.
      _source = 'all';
      _vendor = '';
      _family = '';
      _packFilter = '';
      if (result['alreadyInstalled'] == true) _error = '这个芯片包已经在芯片库中。';
    });
    _refreshPending = true;
  });

  Future<void> _use() async {
    final chip = _selected;
    if (_manage || !_canSelect || chip == null || !chip.available || _loading) {
      return;
    }
    var success = false;
    await _action('正在保存目标芯片…', () async {
      await controller.requestTargetCatalog('selectTarget', chip.selection);
      success = true;
    });
    if (mounted && success) Navigator.pop(context);
  }

  Future<void> _remove(TargetPack pack) async {
    final confirmed = await showTalDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除芯片包'),
        content: Text(
          '删除 ${pack.label} ${pack.version}？'
          '${controller.targetPackId == pack.id ? '\n当前选择将标记为芯片包缺失，需要重新导入或选择其他芯片。' : ''}',
        ),
        actions: [
          TalButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TalButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _action('正在删除芯片包…', () async {
      await controller.requestTargetCatalog('removeTargetPack', {
        'packId': pack.id,
      });
      _refreshPending = true;
    });
  }

  void _move(int direction) {
    if (_manage) return;
    final chips = _chips;
    if (chips.isEmpty) return;
    final index = chips.indexWhere((chip) => chip.id == _selectedId);
    final next = (index + direction).clamp(0, chips.length - 1);
    setState(() => _selectedId = chips[next].id);
    if (_listScroll.hasClients) {
      _listScroll.animateTo(
        (next * 72.0).clamp(0, _listScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: _busy == null,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        },
        child: Dialog(
          insetPadding: const EdgeInsets.all(16),
          constraints: BoxConstraints(maxWidth: math.min(920, size.width - 32)),
          child: SizedBox(
            width: math.min(920, size.width - 32),
            height: math.min(650, size.height - 32),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.memory_outlined,
                        size: 20,
                        color: TalColors.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _manage ? '管理芯片包' : '选择目标芯片',
                          style: talStrong.copyWith(fontSize: 17),
                        ),
                      ),
                      TalIconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _busy == null
                            ? () => Navigator.pop(context)
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 480;
                      final add = TalButton.icon(
                        key: const ValueKey('add-target-pack'),
                        icon: const Icon(Icons.add, size: 17),
                        label: const Text('添加芯片包'),
                        onPressed: _busy == null ? _inspect : null,
                      );
                      final online = TalButton.icon(
                        key: const ValueKey('online-target-packs'),
                        icon: const Icon(
                          Icons.cloud_download_outlined,
                          size: 17,
                        ),
                        label: const Text('在线下载'),
                        onPressed: _busy == null && _preview == null
                            ? _online
                            : null,
                      );
                      final search = TextField(
                        key: const ValueKey('target-search'),
                        controller: _search,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: '搜索型号、厂商、系列',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清空搜索',
                                  icon: const Icon(Icons.close, size: 16),
                                  onPressed: () => _filter(_search.clear),
                                ),
                        ),
                        onChanged: (_) => _filter(() {}),
                        onSubmitted: (_) => _use(),
                      );
                      return narrow
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                search,
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [online, add],
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(child: search),
                                const SizedBox(width: 12),
                                online,
                                const SizedBox(width: 8),
                                add,
                              ],
                            );
                    },
                  ),
                  if (_busy != null) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 6),
                    Text(_busy!, style: talMuted),
                  ],
                  if (_error != null) _notice(_error!, error: true),
                  if (_catalog?.warning.isNotEmpty == true)
                    _notice(_catalog!.warning),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _preview != null
                        ? SingleChildScrollView(child: _previewView())
                        : _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _catalog == null
                        ? Center(
                            child: TalButton(
                              onPressed: _load,
                              child: const Text('重新加载芯片库'),
                            ),
                          )
                        : _manage
                        ? _packList()
                        : _targetBrowser(),
                  ),
                  const Divider(height: 24),
                  if (!_manage &&
                      controller.connectionStatus !=
                          ConnectionStatus.disconnected)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('更换芯片后将自动重新连接，开始新的采样记录。', style: talMuted),
                    ),
                  Row(
                    children: [
                      TalButton(
                        key: const ValueKey('manage-target-packs'),
                        onPressed: _busy == null && _preview == null
                            ? () => setState(() => _manage = !_manage)
                            : null,
                        child: Text(_manage ? '返回芯片选择' : '管理芯片包'),
                      ),
                      const Spacer(),
                      if (!_manage) ...[
                        TalButton(
                          onPressed: _busy == null
                              ? () => Navigator.pop(context)
                              : null,
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        TalButton(
                          key: const ValueKey('use-target-chip'),
                          variant: TalButtonVariant.filled,
                          onPressed:
                              _canSelect &&
                                  _selected?.available == true &&
                                  !_loading
                              ? _use
                              : null,
                          child: const Text('使用此芯片'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      style: talMuted.copyWith(
        color: error ? TalColors.error : TalColors.warning,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
  );

  Widget _previewView() {
    final preview = _preview!;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TalColors.surfaceAlt,
        border: Border.all(color: TalColors.controlBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${preview['vendor']}.${preview['name']}  ${preview['version']}',
            style: talStrong,
          ),
          const SizedBox(height: 4),
          Text(
            '${preview['targetCount']} 个可用芯片 · ${_bytes(preview['size'] as int? ?? 0)}',
            style: talMuted,
          ),
          Text(
            (preview['sampleTargets'] as List? ?? []).join('、'),
            style: talMuted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if ((preview['unsupportedCount'] as int? ?? 0) > 0)
            Text(
              '${preview['unsupportedCount']} 个非 Cortex-M 型号不加入芯片库。',
              style: talMuted,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              TalButton(
                key: const ValueKey('confirm-target-pack-import'),
                variant: TalButtonVariant.filled,
                onPressed: _busy == null ? _import : null,
                child: Text(
                  preview['alreadyInstalled'] == true ? '已存在，刷新芯片库' : '导入芯片包',
                ),
              ),
              TalButton(
                onPressed: _busy == null
                    ? () {
                        unawaited(_discard(preview));
                        setState(() => _preview = null);
                      }
                    : null,
                child: const Text('取消导入'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _targetBrowser() {
    final chips = _chips;
    final vendors =
        _catalog!.targets
            .map((chip) => chip.vendor)
            .where((vendor) => vendor.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final families =
        _catalog!.targets
            .where((chip) => _vendor.isEmpty || chip.vendor == _vendor)
            .expand((chip) => chip.families)
            .toSet()
            .toList()
          ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final entry in const {
              'all': '全部',
              'recent': '最近使用',
              'builtin': '内置芯片',
              'pack': '芯片包',
            }.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: _source == entry.key,
                onSelected: (_) => _filter(() {
                  _source = entry.key;
                  _packFilter = '';
                }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TalDropdown<String>(
                key: const ValueKey('target-vendor-filter'),
                value: vendors.contains(_vendor) ? _vendor : '',
                values: ['', ...vendors],
                label: (value) => value.isEmpty ? '全部厂商' : value,
                onChanged: (value) => _filter(() {
                  _vendor = value;
                  _family = '';
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TalDropdown<String>(
                key: const ValueKey('target-family-filter'),
                value: families.contains(_family) ? _family : '',
                values: ['', ...families],
                label: (value) => value.isEmpty ? '全部系列' : value,
                onChanged: (value) => _filter(() => _family = value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _packFilter.isEmpty
              ? '${chips.length} 个匹配芯片'
              : '${chips.length} 个匹配芯片 · 已按芯片包筛选',
          style: talMuted,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final list = chips.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '没有匹配的芯片\n点击“在线下载”搜索安装，或添加本地 .pack 芯片包。',
                          style: talMuted,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _listScroll,
                      itemExtent: 72,
                      itemCount: chips.length,
                      itemBuilder: (context, index) => _chipRow(chips[index]),
                    );
              if (constraints.maxWidth < 660) {
                return Column(
                  children: [
                    Expanded(child: list),
                    if (_selected case final chip?)
                      SizedBox(
                        height: math.min(110, constraints.maxHeight * .35),
                        child: _details(chip, compact: true),
                      ),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: list),
                  const VerticalDivider(width: 25),
                  SizedBox(
                    width: 260,
                    child: _selected == null
                        ? const SizedBox.shrink()
                        : _details(_selected!),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _chipRow(TargetChip chip) => Material(
    color: chip.id == _selectedId ? TalColors.selection : Colors.transparent,
    child: InkWell(
      key: ValueKey('target-chip-${chip.id}'),
      onTap: () => setState(() => _selectedId = chip.id),
      onDoubleTap: () {
        setState(() => _selectedId = chip.id);
        unawaited(_use());
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    chip.partNumber,
                    style: talStrong.copyWith(
                      color: chip.available
                          ? TalColors.text
                          : TalColors.disabled,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (chip.name == controller.targetName &&
                    chip.packId == controller.targetPackId)
                  const Icon(Icons.check, size: 16, color: TalColors.accent),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              chip.available
                  ? '${chip.vendor.isEmpty ? '' : '${chip.vendor} · '}${chip.packLabel}'
                  : '${chip.packLabel} · 芯片包缺失',
              style: talMuted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _details(
    TargetChip chip, {
    bool compact = false,
  }) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          chip.partNumber,
          style: talStrong.copyWith(fontSize: compact ? 13 : 16),
        ),
        const SizedBox(height: 12),
        if (chip.name == 'auto')
          const Text(
            '优先使用探针提供的目标型号；无法确定时使用通用 Cortex-M。通用目标不提供芯片专用烧录算法。',
            style: talMuted,
          ),
        if (chip.vendor.isNotEmpty) _detail('厂商', chip.vendor),
        if (chip.families.isNotEmpty) _detail('系列', chip.families.join(' / ')),
        _detail('内核', chip.cores.isEmpty ? '未提供' : chip.cores.join(' / ')),
        if (chip.memories.isNotEmpty)
          _detail(
            '存储容量',
            chip.memories
                .map(
                  (region) =>
                      '${region['name']} ${_bytes(region['size'] as int)}',
                )
                .join(' · '),
          ),
        _detail('来源', chip.packLabel),
        _detail('目标名称', chip.name),
        if (!chip.available)
          const Text(
            '芯片包缺失，请重新导入。',
            style: TextStyle(color: TalColors.warning),
          ),
        if (chip.memories.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('存储区域', style: talStrong),
          for (final region in chip.memories)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${region['name']}  ${_bytes(region['size'] as int)}\n0x${(region['start'] as int).toRadixString(16).padLeft(8, '0')}',
                style: talMono,
              ),
            ),
        ],
      ],
    ),
  );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: talMuted),
        const SizedBox(height: 3),
        SelectableText(value, style: talBody),
      ],
    ),
  );

  Widget _packList() {
    final packs = _catalog!.packs
        .where(
          (pack) => '${pack.label} ${pack.version}'.toLowerCase().contains(
            _search.text.trim().toLowerCase(),
          ),
        )
        .toList();
    if (packs.isEmpty) {
      return const Center(
        child: Text(
          '没有匹配的芯片包\n点击“添加芯片包”导入本地 .pack 文件。',
          style: talMuted,
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.separated(
      itemCount: packs.length,
      separatorBuilder: (_, _) => const Divider(height: 24),
      itemBuilder: (context, index) {
        final pack = packs[index];
        final inUse =
            controller.connectionKind == 'local' &&
            controller.targetPackId == pack.id &&
            controller.connectionStatus != ConnectionStatus.disconnected;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pack.label, style: talStrong),
            const SizedBox(height: 4),
            Text(
              '${pack.version} · ${pack.targetCount} 个芯片 · ${_bytes(pack.size)}${pack.bundled ? ' · 软件自带' : ''}${inUse ? ' · 正在使用' : ''}${!pack.available ? ' · 文件缺失' : ''}',
              style: talMuted,
            ),
            if (DateTime.tryParse(pack.importedAt) case final date?)
              Text(
                '导入于 ${date.toLocal().toString().split('.').first}',
                style: talMuted,
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TalButton(
                  onPressed: () => _filter(() {
                    _manage = false;
                    _source = 'pack';
                    _packFilter = pack.id;
                    _vendor = '';
                    _family = '';
                    _search.clear();
                  }),
                  child: const Text('查看芯片'),
                ),
                if (!pack.bundled)
                  TalButton(
                    key: ValueKey('remove-target-pack-${pack.id}'),
                    onPressed: _busy == null && !inUse
                        ? () => _remove(pack)
                        : null,
                    child: const Text('删除'),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

String _bytes(int value) {
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KiB';
  return '$value B';
}
