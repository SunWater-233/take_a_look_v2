part of 'watch_panel.dart';

/// Edits a snapshot of the current value. Telemetry only updates the display;
/// hardware writes happen exclusively on Enter, never on blur or cancellation.
class _WatchValueCell extends StatefulWidget {
  const _WatchValueCell({
    super.key,
    required this.controller,
    required this.watch,
    required this.prefix,
    required this.onSelect,
  });
  final TakeALookController controller;
  final WatchItem watch;
  final String prefix;
  final VoidCallback onSelect;
  @override
  State<_WatchValueCell> createState() => _WatchValueCellState();
}

class _WatchValueCellState extends State<_WatchValueCell> {
  final _editor = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false, _writing = false;
  String? _error;
  int _revision = 0;
  String get _key => widget.watch.symbol.key;
  String get _prefix => widget.prefix;
  bool get _canWrite =>
      widget.watch.symbol.writable &&
      widget.controller.supportsMemoryWrite &&
      widget.controller.connectionStatus == ConnectionStatus.connected;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (!_focus.hasFocus && _editing && mounted) {
      setState(() => _editing = false);
    }
  }

  void _begin() {
    if (!_canWrite || _editing || _writing) return;
    widget.onSelect();
    _editor.text =
        widget.controller.watchInputDrafts[_key] ??
        (widget.watch.updatedAtMs == null ? '' : widget.watch.editValueLabel);
    _editor.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _editor.text.length,
    );
    setState(() {
      _editing = true;
      _error = null;
      _revision++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focus.requestFocus();
    });
  }

  void _cancel() {
    _revision++;
    widget.controller.watchInputDrafts.remove(_key);
    setState(() {
      _editing = false;
      _error = null;
    });
    _focus.unfocus();
  }

  Future<void> _submit() async {
    if (_writing) return;
    if (!_canWrite || _editor.text.trim().isEmpty) {
      setState(() => _error = _canWrite ? '请输入新值' : '当前无法写入，请检查连接和变量权限');
      return;
    }
    final owner = widget.controller, key = _key, text = _editor.text;
    final revision = _revision;
    setState(() {
      _writing = true;
      _error = null;
    });
    final success = await owner.writeWatch(key, text);
    if (success &&
        revision == _revision &&
        owner.watchInputDrafts[key] == text) {
      owner.watchInputDrafts.remove(key);
    }
    if (!mounted) return;
    setState(() {
      _writing = false;
      if (revision != _revision) return;
      if (success) {
        _editing = false;
      } else {
        _error =
            owner.lastBackendError?['message'] as String? ?? '写入失败，请检查输入后重试';
      }
    });
    if (success && revision == _revision) _focus.unfocus();
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = talMono.copyWith(fontSize: 12);
    final Widget content;
    if (_editing) {
      content = CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
        child: TextField(
          key: ValueKey('$_prefix-watch-input-$_key'),
          controller: _editor,
          focusNode: _focus,
          style: style,
          textAlign: TextAlign.right,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: TalColors.input,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 5,
            ),
            border: const OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(3),
              borderSide: BorderSide(
                color: _error == null ? TalColors.accent : TalColors.error,
              ),
            ),
            suffixIconConstraints: const BoxConstraints.tightFor(
              width: 14,
              height: 14,
            ),
            suffixIcon: _writing
                ? const Padding(
                    padding: EdgeInsets.all(2),
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : _error != null
                ? Icon(
                    Icons.error_outline,
                    key: ValueKey('$_prefix-watch-write-error-$_key'),
                    size: 12,
                    color: TalColors.error,
                  )
                : null,
          ),
          onChanged: (value) {
            widget.controller.watchInputDrafts[_key] = value;
            setState(() {
              _revision++;
              _error = null;
            });
          },
          onEditingComplete: () {},
          onSubmitted: (_) => _submit(),
          onTapOutside: (_) => _focus.unfocus(),
        ),
      );
    } else {
      content = AnimatedBuilder(
        animation: widget.controller.telemetryChanges,
        builder: (_, _) => LayoutBuilder(
          builder: (context, constraints) => Text(
            widget.watch.updatedAtMs == null &&
                    widget.watch.valueDiagnostic == null
                ? '—'
                : _displayValue(context, style, constraints.maxWidth),
            key: ValueKey('$_prefix-watch-value-$_key'),
            style: style.copyWith(
              color: _error == null && widget.watch.valueDiagnostic == null
                  ? null
                  : TalColors.error,
            ),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    // Keep the recognizer mounted while switching between text and the editor.
    // Disposing it mid-gesture can release a pending tap to the parent row.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!_editing) widget.onSelect();
      },
      onDoubleTap: _begin,
      child: Tooltip(
        triggerMode: TooltipTriggerMode.manual,
        message:
            _error ??
            widget.watch.valueDiagnostic ??
            (_writing
                ? '正在写入并等待回读'
                : _editing
                ? '回车写入，Esc 取消'
                : _canWrite
                ? '双击编辑，回车写入'
                : widget.watch.symbol.writable
                ? '当前无法写入'
                : '只读变量'),
        child: Semantics(
          liveRegion: _error != null,
          label: _error,
          child: content,
        ),
      ),
    );
  }

  String _displayValue(BuildContext context, TextStyle style, double width) {
    final watch = widget.watch;
    if (watch.valueDiagnostic != null) return watch.valueLabel;
    if (!watch.isFloatingPoint || !watch.value.isFinite) {
      return watch.valueLabel;
    }
    final value = double.parse(watch.editValueLabel);
    if (!value.isFinite) return watch.editValueLabel;
    bool fits(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final fits = painter.width <= width;
      painter.dispose();
      return fits;
    }

    // Prefer fixed decimals. Use scientific notation when a small/large value
    // would otherwise look like zero or lose its integer digits in a narrow cell.
    final magnitude = value == 0
        ? 0
        : (math.log(value.abs()) / math.ln10).floor();
    final decimals = (watch.valuePrecision - 1 - magnitude).clamp(0, 20);
    for (var places = decimals; places >= 0; places--) {
      final text = value.toStringAsFixed(places);
      if (value != 0 && double.tryParse(text) == 0) break;
      if (fits(text)) return text;
    }
    for (var digits = watch.valuePrecision; digits >= 1; digits--) {
      final text = value.toStringAsExponential(digits - 1);
      if (fits(text)) return text;
    }
    return watch.editValueLabel;
  }
}
