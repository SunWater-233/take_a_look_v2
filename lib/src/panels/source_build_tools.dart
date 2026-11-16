part of 'source_debug_panel.dart';

class _SourceBuildToolbar extends StatelessWidget {
  const _SourceBuildToolbar({required this.controller, required this.compact});
  final TakeALookController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.sourceToolsChanges,
      controller.connectionChanges,
      controller.debugChanges,
      controller.symbolChanges,
    ]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final project = controller.sourceProject;
        final task = controller.sourceTask;
        final supportsDownload = controller.supportsFirmwareDownload;
        final connected =
            controller.connectionStatus == ConnectionStatus.connected;
        final configured = project.canBuild;
        final firmwarePath = controller.firmwarePath;
        final canDownload =
            supportsDownload && connected && firmwarePath.isNotEmpty;
        final iconsOnly = compact || constraints.maxWidth < 440;
        Future<void> settings() => showDialog<void>(
          context: context,
          builder: (_) => SourceProjectDialog(controller: controller),
        );
        Widget action(
          String key,
          String label,
          IconData icon,
          String kind,
          bool enabled,
          String reason,
        ) {
          final run = enabled && !task.running
              ? () => unawaited(controller.startSourceTask(kind))
              : null;
          if (iconsOnly) {
            return TalIconButton(
              key: ValueKey(key),
              tooltip: enabled ? label : reason,
              onPressed: run,
              icon: Icon(icon, size: 17),
            );
          }
          return Tooltip(
            message: enabled ? label : reason,
            child: TalButton.icon(
              key: ValueKey(key),
              variant: kind == 'buildAndDownload'
                  ? TalButtonVariant.filled
                  : TalButtonVariant.outlined,
              icon: Icon(icon, size: 15),
              label: Text(label),
              onPressed: run,
            ),
          );
        }

        final downloadReason = !supportsDownload
            ? '当前连接不支持下载，请使用本地 pyOCD 或 EmberMobile 连接'
            : !connected
            ? '请先连接调试目标'
            : '请打开 ELF / AXF 文件，或在工程设置中指定固件文件';
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            action(
              'source-build',
              '编译',
              Icons.build_outlined,
              'build',
              configured,
              '请设置源码根目录和编译命令',
            ),
            const SizedBox(width: 4),
            action(
              'source-download',
              '下载',
              Icons.download_outlined,
              'download',
              canDownload,
              downloadReason,
            ),
            const SizedBox(width: 4),
            action(
              'source-build-download',
              '编译并下载',
              Icons.play_arrow,
              'buildAndDownload',
              configured && canDownload,
              !configured ? '请设置源码根目录和编译命令' : downloadReason,
            ),
            TalIconButton(
              key: const ValueKey('source-project-settings'),
              tooltip: '工程设置',
              onPressed: task.running ? null : settings,
              icon: const Icon(Icons.tune, size: 17),
            ),
          ],
        );
        final projectButton = Tooltip(
          message: project.sourceRoot.isEmpty
              ? '设置工程源码根目录'
              : project.sourceRoot,
          child: InkWell(
            onTap: task.running ? null : settings,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_open,
                    size: 17,
                    color: TalColors.muted,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          project.sourceRoot.isEmpty
                              ? '设置工程'
                              : _basename(project.sourceRoot),
                          style: talStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!compact && project.sourceRoot.isNotEmpty)
                          Text(
                            project.sourceRoot,
                            style: talMuted.copyWith(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FirmwareNotice(controller: controller),
            Container(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: TalColors.borderSoft)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: !iconsOnly && constraints.maxWidth < 620
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        projectButton,
                        Align(alignment: Alignment.centerRight, child: actions),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: projectButton),
                        actions,
                      ],
                    ),
            ),
          ],
        );
      },
    ),
  );
}

class SourceProjectDialog extends StatefulWidget {
  const SourceProjectDialog({super.key, required this.controller});
  final TakeALookController controller;
  @override
  State<SourceProjectDialog> createState() => _SourceProjectDialogState();
}

class _SourceProjectDialogState extends State<SourceProjectDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _root;
  late final TextEditingController _command;
  late final TextEditingController _firmware;
  late final TextEditingController _extraPath;
  late String _shell, _after, _encoding;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final project = widget.controller.sourceProject;
    _root = TextEditingController(text: project.sourceRoot);
    _command = TextEditingController(text: project.buildCommand);
    _firmware = TextEditingController(text: project.firmwarePath);
    _extraPath = TextEditingController(text: project.extraPath);
    _shell = project.shell;
    _after = project.afterDownload;
    _encoding = project.outputEncoding;
  }

  @override
  void dispose() {
    _root.dispose();
    _command.dispose();
    _firmware.dispose();
    _extraPath.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final controller = widget.controller;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await controller.saveSourceProject({
        'sourceRoot': _root.text.trim(),
        'buildCommand': _command.text.trim(),
        'firmwarePath': _firmware.text.trim(),
        'shell': _shell,
        'afterDownload': _after,
        'extraPath': _extraPath.text.trim(),
        'outputEncoding': _encoding,
      });
      if (mounted) {
        final route = ModalRoute.of(context);
        if (route != null) Navigator.of(context).removeRoute(route);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _pick(bool root) async {
    final picker = root
        ? widget.controller.sourceRootPicker ?? pickSourceRootDirectory
        : widget.controller.firmwareFilePicker ?? pickFirmwareFile;
    final path = await picker();
    if (!mounted || path == null) return;
    setState(() => (root ? _root : _firmware).text = path);
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.controller.sourceProject;
    final shells = project.shells.isNotEmpty
        ? project.shells
        : [
            for (final id
                in project.platform == 'windows'
                    ? ['powershell', 'cmd']
                    : project.platform == 'macos'
                    ? ['zsh', 'bash', 'sh']
                    : ['bash', 'sh'])
              {
                'id': id,
                'label': id == 'powershell' ? 'PowerShell' : id,
                'available': true,
              },
          ];
    // Material scales floating labels to 75%; keep these at the body text size.
    final fieldLabelStyle = talBody.copyWith(
      color: TalColors.muted,
      fontSize: talBody.fontSize! / .75,
    );
    final fieldPadding = TalUiTheme.of(
      context,
    ).fieldPadding.add(const EdgeInsets.symmetric(vertical: 6));
    InputDecoration decoration(String label, {String? helper}) =>
        InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        );
    Widget selector({
      required String key,
      required String label,
      required String value,
      required List<String> values,
      required String Function(String) valueLabel,
      required ValueChanged<String> onChanged,
    }) {
      final disabled = _saving || values.isEmpty;
      return LabeledField(
        label: label,
        child: ExcludeFocus(
          excluding: disabled,
          child: IgnorePointer(
            ignoring: disabled,
            child: TalDropdown<String>(
              key: ValueKey(key),
              value: value,
              values: values,
              label: valueLabel,
              onChanged: (next) {
                if (!disabled) onChanged(next);
              },
            ),
          ),
        ),
      );
    }

    String shellLabel(String id) {
      final shell = shells.where((item) => item['id'] == id).firstOrNull;
      if (shell == null) return id;
      return '${shell['label']}${shell['available'] == true ? '' : '（未安装）'}';
    }

    Widget fileField(
      String key,
      String label,
      TextEditingController value,
      bool root,
    ) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _SourcePathFormField(
            key: ValueKey(key),
            controller: value,
            enabled: !_saving,
            decoration: decoration(label).copyWith(
              floatingLabelStyle: fieldLabelStyle,
              contentPadding: fieldPadding,
            ),
            validator: root
                ? (text) =>
                      text == null || text.trim().isEmpty ? '请选择源码根目录' : null
                : null,
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TalIconButton(
            tooltip: root ? '浏览源码目录' : '浏览固件文件',
            onPressed: _saving ? null : () => _pick(root),
            icon: Icon(root ? Icons.folder_open : Icons.file_open_outlined),
          ),
        ),
      ],
    );
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 580,
            maxHeight: MediaQuery.sizeOf(context).height * .9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '工程设置 · ${project.platformLabel}',
                          style: talStrong.copyWith(fontSize: 16),
                        ),
                      ),
                      TalIconButton(
                        tooltip: '关闭工程设置',
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  fileField('source-project-root', '源码根目录 *', _root, true),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('source-project-command'),
                    controller: _command,
                    enabled: !_saving,
                    minLines: 6,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textAlignVertical: TextAlignVertical.top,
                    style: talMono,
                    decoration: decoration('编译命令').copyWith(
                      floatingLabelStyle: fieldLabelStyle,
                      contentPadding: fieldPadding,
                      alignLabelWithHint: true,
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      hintText: '例如：cmake --build build',
                    ),
                  ),
                  const SizedBox(height: 7),
                  const Text(
                    '支持多行，Enter 换行。使用所选解释器的语法；仅下载时可留空。',
                    style: talMuted,
                    textAlign: TextAlign.left,
                  ),
                  const SizedBox(height: 16),
                  fileField(
                    'source-project-firmware',
                    '固件文件',
                    _firmware,
                    false,
                  ),
                  const SizedBox(height: 7),
                  const Text(
                    'ELF / AXF；相对路径基于源码根目录，保存后统一为绝对路径。',
                    style: talMuted,
                    textAlign: TextAlign.left,
                  ),
                  const SizedBox(height: 16),
                  selector(
                    key: 'source-project-shell',
                    label: '命令解释器',
                    value: _shell,
                    values: [
                      for (final shell in shells)
                        if (shell['available'] == true) shell['id'] as String,
                    ],
                    valueLabel: shellLabel,
                    onChanged: (value) => setState(() => _shell = value),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    project.platform == 'windows'
                        ? 'Windows 默认 PowerShell：优先使用 PowerShell 7，未安装时使用 Windows PowerShell。'
                        : '仅显示当前平台的解释器。命令和本机目录按工程保存。',
                    style: talMuted,
                  ),
                  const SizedBox(height: 16),
                  selector(
                    key: 'source-project-after-download',
                    label: '下载后动作',
                    value: _after,
                    values: const ['halt', 'run'],
                    valueLabel: (value) => value == 'halt' ? '复位并暂停' : '复位并运行',
                    onChanged: (value) => setState(() => _after = value),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('高级设置', style: talBody),
                    children: [
                      TextFormField(
                        controller: _extraPath,
                        enabled: !_saving,
                        minLines: 2,
                        maxLines: 4,
                        decoration: decoration(
                          '工具链目录',
                          helper: '每行一个目录，加入编译进程的 PATH；相对目录基于源码根目录。',
                        ),
                      ),
                      const SizedBox(height: 16),
                      selector(
                        key: 'source-project-encoding',
                        label: '输出编码',
                        value: _encoding,
                        values: const ['utf-8', 'system'],
                        valueLabel: (value) =>
                            value == 'utf-8' ? 'UTF-8' : '系统编码（旧版工具链）',
                        onChanged: (value) => setState(() => _encoding = value),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SelectableText(
                        _error!,
                        style: talBody.copyWith(color: TalColors.error),
                      ),
                    ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    children: [
                      TalButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      TalButton(
                        key: const ValueKey('source-project-save'),
                        variant: TalButtonVariant.filled,
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? '保存中…' : '保存设置'),
                      ),
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
}

class _SourcePathFormField extends FormField<String> {
  _SourcePathFormField({
    required this.controller,
    required this.decoration,
    required super.enabled,
    super.key,
    super.validator,
  }) : super(
         initialValue: controller.text,
         builder: (field) => (field as _SourcePathFormFieldState)._buildField(),
       );

  final TextEditingController controller;
  final InputDecoration decoration;

  @override
  FormFieldState<String> createState() => _SourcePathFormFieldState();
}

class _SourcePathFormFieldState extends FormFieldState<String> {
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  _SourcePathFormField get widget => super.widget as _SourcePathFormField;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncValue);
  }

  @override
  void didUpdateWidget(covariant _SourcePathFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncValue);
      widget.controller.addListener(_syncValue);
      setValue(widget.controller.text);
    }
  }

  void _syncValue() {
    if (value != widget.controller.text) didChange(widget.controller.text);
  }

  @override
  void reset() {
    widget.controller.text = widget.initialValue ?? '';
    super.reset();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncValue);
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _buildField() => AnimatedBuilder(
    animation: _focus,
    builder: (context, _) => GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.enabled ? _focus.requestFocus : null,
      child: InputDecorator(
        decoration: widget.decoration
            .applyDefaults(InputDecorationTheme.of(context))
            .copyWith(enabled: widget.enabled, errorText: errorText),
        baseStyle: talBody,
        isFocused: _focus.hasFocus,
        isEmpty: widget.controller.text.isEmpty,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            setState(() {});
            return false;
          },
          child: AnimatedBuilder(
            animation: _scroll,
            builder: (context, child) => ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) {
                final position = _scroll.hasClients ? _scroll.position : null;
                final hasMetrics = position?.hasContentDimensions ?? false;
                final fadeLeft = hasMetrics && position!.extentBefore > 0.5;
                final fadeRight = hasMetrics && position!.extentAfter > 0.5;
                final fade = bounds.width > 0
                    ? math.min(24 / bounds.width, 0.5)
                    : 0.0;
                return LinearGradient(
                  colors: [
                    fadeLeft ? Colors.transparent : Colors.white,
                    Colors.white,
                    Colors.white,
                    fadeRight ? Colors.transparent : Colors.white,
                  ],
                  stops: [0, fade, 1 - fade, 1],
                ).createShader(bounds);
              },
              child: child,
            ),
            // Mask only the editable content; keep the border, label and helper
            // fully visible. Scroll metrics also update after picking or resizing.
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              scrollController: _scroll,
              enabled: widget.enabled,
              style: talBody,
              textDirection: TextDirection.ltr,
              decoration: null,
            ),
          ),
        ),
      ),
    ),
  );
}

class _SourceTaskOutput extends StatefulWidget {
  const _SourceTaskOutput({
    required this.controller,
    required this.maxHeight,
    required this.onOpenLocation,
    this.embedded = false,
  });
  final TakeALookController controller;
  final double maxHeight;
  final void Function(String path, int line) onOpenLocation;
  final bool embedded;
  @override
  State<_SourceTaskOutput> createState() => _SourceTaskOutputState();
}

class _SourceTaskOutputState extends State<_SourceTaskOutput> {
  final _scroll = ScrollController();
  bool _expanded = false;
  String _taskId = '';
  int _outputRevision = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _openLine(String text) {
    final match =
        RegExp(r'^(.+?):(\d+)(?::\d+)?:').firstMatch(text.trim()) ??
        RegExp(r'^(.+)\((\d+)(?:,\d+)?\)').firstMatch(text.trim());
    if (match == null) return;
    var path = match.group(1)!;
    if (!path.startsWith('/') &&
        !RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path) &&
        !path.startsWith('\\\\')) {
      path =
          '${widget.controller.sourceProject.sourceRoot}${Platform.pathSeparator}$path';
    }
    widget.onOpenLocation(path, int.parse(match.group(2)!));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller.sourceToolsChanges,
    builder: (context, _) {
      final task = widget.controller.sourceTask;
      if (task.id != _taskId) {
        _taskId = task.id;
        _expanded = task.id.isNotEmpty;
      }
      if (_outputRevision != task.outputRevision) {
        _outputRevision = task.outputRevision;
        if (!_scroll.hasClients || _scroll.position.extentAfter < 40) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
        }
      }
      final expanded = (widget.embedded || _expanded) && widget.maxHeight >= 85;
      final tone = task.status == 'failed'
          ? TalColors.error
          : task.status == 'succeeded'
          ? TalColors.success
          : TalColors.muted;
      return Container(
        decoration: const BoxDecoration(
          color: TalColors.surface,
          border: Border(top: BorderSide(color: TalColors.borderSoft)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: TalUiTheme.of(context).targetExtent(34),
              child: LayoutBuilder(
                builder: (context, bounds) => Row(
                  children: [
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.terminal,
                      size: 15,
                      color: TalColors.muted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      bounds.maxWidth < 480 ? '输出' : '编译 / 下载输出',
                      style: talMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${task.message}${task.details['outputTruncated'] == true ? ' · 仅保留最近输出' : ''}',
                        style: talMuted.copyWith(color: tone),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (task.canCancel)
                      TalIconButton(
                        key: const ValueKey('source-build-cancel'),
                        tooltip: '停止编译',
                        onPressed: widget.controller.cancelSourceTask,
                        icon: const Icon(Icons.stop, size: 16),
                      ),
                    if (bounds.maxWidth >= 480)
                      TalIconButton(
                        tooltip: '复制输出',
                        onPressed: task.lines.isEmpty
                            ? null
                            : () => Clipboard.setData(
                                ClipboardData(
                                  text: task.lines
                                      .map((line) => line['text'])
                                      .join('\n'),
                                ),
                              ),
                        icon: const Icon(Icons.copy, size: 15),
                      ),
                    if (bounds.maxWidth >= 480)
                      TalIconButton(
                        tooltip: '清空输出',
                        onPressed: task.running
                            ? null
                            : widget.controller.clearSourceOutput,
                        icon: const Icon(Icons.delete_outline, size: 16),
                      ),
                    if (bounds.maxWidth < 480)
                      PopupMenuButton<String>(
                        tooltip: '输出操作',
                        icon: const Icon(Icons.more_horiz, size: 17),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'copy',
                            enabled: task.lines.isNotEmpty,
                            child: const Text('复制输出'),
                          ),
                          PopupMenuItem(
                            value: 'clear',
                            enabled: !task.running,
                            child: const Text('清空输出'),
                          ),
                        ],
                        onSelected: (action) {
                          if (action == 'copy') {
                            Clipboard.setData(
                              ClipboardData(
                                text: task.lines
                                    .map((line) => line['text'])
                                    .join('\n'),
                              ),
                            );
                          } else {
                            widget.controller.clearSourceOutput();
                          }
                        },
                      ),
                    if (!widget.embedded)
                      TalIconButton(
                        key: const ValueKey('source-output-toggle'),
                        tooltip: expanded ? '折叠输出' : '展开输出',
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: Icon(
                          expanded ? Icons.expand_more : Icons.expand_less,
                          size: 17,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (expanded)
              SizedBox(
                height:
                    (widget.maxHeight - TalUiTheme.of(context).targetExtent(34))
                        .clamp(
                          40.0,
                          widget.embedded
                              ? math.max(40.0, widget.maxHeight)
                              : 230.0,
                        ),
                child: task.lines.isEmpty
                    ? const Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: EdgeInsets.all(10),
                          child: Text('编译和下载的输出将显示在这里。', style: talMuted),
                        ),
                      )
                    : Scrollbar(
                        controller: _scroll,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                          itemCount: task.lines.length,
                          itemBuilder: (context, index) {
                            final line = task.lines[index];
                            final text = line['text'] as String? ?? '';
                            return InkWell(
                              onTap: () => _openLine(text),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 1,
                                ),
                                child: Text(
                                  text,
                                  style: talMono.copyWith(
                                    color: line['stream'] == 'stderr'
                                        ? TalColors.error
                                        : TalColors.muted,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
          ],
        ),
      );
    },
  );
}
