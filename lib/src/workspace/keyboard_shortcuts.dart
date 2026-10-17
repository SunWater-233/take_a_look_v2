import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'panel_types.dart';

/// Shared command bindings for window handlers, panel handlers and menu hints.
/// Physical keys keep commands available under IMEs; logical keys also support
/// alternate keyboard layouts. Ctrl and Command are both accepted.
enum WorkspaceShortcut {
  resetUiScale(
    PhysicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit0,
    alternate: (PhysicalKeyboardKey.numpad0, LogicalKeyboardKey.numpad0),
  ),
  saveLayout(PhysicalKeyboardKey.keyS, LogicalKeyboardKey.keyS, shift: true),
  findSource(PhysicalKeyboardKey.keyF, LogicalKeyboardKey.keyF),
  closeSource(PhysicalKeyboardKey.keyW, LogicalKeyboardKey.keyW),
  selectAllWatches(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA),
  undoWatchDeletion(PhysicalKeyboardKey.keyZ, LogicalKeyboardKey.keyZ);

  const WorkspaceShortcut(
    this.physicalKey,
    this.logicalKey, {
    this.shift = false,
    this.alternate,
  });

  final PhysicalKeyboardKey physicalKey;
  final LogicalKeyboardKey logicalKey;
  final bool shift;
  final (PhysicalKeyboardKey, LogicalKeyboardKey)? alternate;

  SingleActivator get menuActivator =>
      SingleActivator(logicalKey, control: true, shift: shift);

  bool matches(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return event is KeyDownEvent &&
        !event.synthesized &&
        (event.physicalKey == physicalKey ||
            event.logicalKey == logicalKey ||
            event.physicalKey == alternate?.$1 ||
            event.logicalKey == alternate?.$2) &&
        (keyboard.isControlPressed || keyboard.isMetaPressed) &&
        !keyboard.isAltPressed &&
        keyboard.isShiftPressed == shift;
  }
}

/// A window-local fallback after focused controls have had the first chance to
/// handle keys. Text editing and modal routes retain their normal shortcuts.
class WorkspaceKeyboardShortcuts extends StatefulWidget {
  const WorkspaceKeyboardShortcuts({
    required this.child,
    this.onKeyEvent,
    super.key,
  });

  final Widget child;
  final OnKeyEventCallback? onKeyEvent;

  @override
  State<WorkspaceKeyboardShortcuts> createState() =>
      _WorkspaceKeyboardShortcutsState();
}

class _WorkspaceKeyboardShortcutsState
    extends State<WorkspaceKeyboardShortcuts> {
  _PanelKeyboardScopeState? activePanel;
  final panels = <_PanelKeyboardScopeState>{};

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addLateKeyEventHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    FocusManager.instance.removeLateKeyEventHandler(_handleKeyEvent);
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final result = widget.onKeyEvent?.call(event) ?? KeyEventResult.ignored;
    if (result != KeyEventResult.ignored) return result;
    final panel = activePanel;
    if (panel != null && panel.mounted) {
      final result = panel.handleKeyEvent(event);
      if (result != KeyEventResult.ignored) return result;
    }
    // A visible source editor owns the window's find/close-file commands even
    // after a file picker or another panel has taken keyboard focus.
    for (final candidate in panels.toList()) {
      if (!candidate.mounted || identical(candidate, panel)) continue;
      final result = candidate.handleWindowKeyEvent(event);
      if (result != KeyEventResult.ignored) return result;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) =>
      _WindowKeyboardContext(state: this, child: widget.child);
}

class _WindowKeyboardContext extends InheritedWidget {
  const _WindowKeyboardContext({required this.state, required super.child});
  final _WorkspaceKeyboardShortcutsState state;

  @override
  bool updateShouldNotify(_WindowKeyboardContext oldWidget) =>
      oldWidget.state != state;
}

/// Gives each docked or detached panel its own focus history, including its
/// header. Selecting a different tab explicitly activates the new panel.
class PanelKeyboardScope extends StatefulWidget {
  const PanelKeyboardScope({
    required this.panel,
    required this.child,
    super.key,
  });
  final Object panel;
  final Widget child;

  @override
  State<PanelKeyboardScope> createState() => _PanelKeyboardScopeState();
}

class _PanelKeyboardScopeState extends State<PanelKeyboardScope> {
  final _focusScope = FocusScopeNode(debugLabel: 'workspace-panel');
  final _bindings = <Object, PanelKeyboardListener>{};
  _WorkspaceKeyboardShortcutsState? _window;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _window?.panels.remove(this);
    _window = context
        .dependOnInheritedWidgetOfExactType<_WindowKeyboardContext>()
        ?.state;
    _window?.panels.add(this);
    _window?.activePanel ??= this;
  }

  @override
  void didUpdateWidget(covariant PanelKeyboardScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.panel != widget.panel) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent != false) {
          _activate(restoreFocus: true);
        }
      });
    }
  }

  void _activate({bool restoreFocus = false}) {
    _window?.activePanel = this;
    if (restoreFocus || !_focusScope.hasFocus) {
      final preferredFocus = _bindings.values.firstOrNull?.focusNode;
      if (preferredFocus != null && preferredFocus.context != null) {
        preferredFocus.requestFocus();
      } else {
        _focusScope.requestFocus();
      }
    }
  }

  KeyEventResult handleKeyEvent(KeyEvent event) {
    for (final binding in _bindings.values) {
      final result = binding.onKeyEvent(event);
      if (result != KeyEventResult.ignored) return result;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult handleWindowKeyEvent(KeyEvent event) {
    for (final binding in _bindings.values) {
      final result =
          binding.onWindowKeyEvent?.call(event) ?? KeyEventResult.ignored;
      if (result != KeyEventResult.ignored) return result;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    if (_window?.activePanel == this) _window?.activePanel = null;
    _window?.panels.remove(this);
    _focusScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PanelKeyboardContext(
    state: this,
    child: FocusScope(
      node: _focusScope,
      autofocus: true,
      onFocusChange: (focused) {
        if (focused) _window?.activePanel = this;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _activate(),
        child: widget.child,
      ),
    ),
  );
}

class _PanelKeyboardContext extends InheritedWidget {
  const _PanelKeyboardContext({required this.state, required super.child});
  final _PanelKeyboardScopeState state;

  @override
  bool updateShouldNotify(_PanelKeyboardContext oldWidget) =>
      oldWidget.state != state;
}

/// Attaches a panel's focus node and registers the same handler for header focus
/// and lost-focus fallback. Focused input controls always handle keys first.
class PanelKeyboardListener extends StatefulWidget {
  const PanelKeyboardListener({
    required this.focusNode,
    required this.onKeyEvent,
    required this.child,
    this.onWindowKeyEvent,
    this.autofocus = false,
    super.key,
  });
  final FocusNode focusNode;
  final OnKeyEventCallback onKeyEvent;
  final OnKeyEventCallback? onWindowKeyEvent;
  final bool autofocus;
  final Widget child;

  @override
  State<PanelKeyboardListener> createState() => _PanelKeyboardListenerState();
}

class _PanelKeyboardListenerState extends State<PanelKeyboardListener> {
  _PanelKeyboardScopeState? _panel;
  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _panel?._bindings.remove(this);
    _panel = context
        .dependOnInheritedWidgetOfExactType<_PanelKeyboardContext>()
        ?.state;
    _visible = WorkspacePanelVisibility.of(context);
    if (_visible) _panel?._bindings[this] = widget;
  }

  @override
  void didUpdateWidget(covariant PanelKeyboardListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_visible) _panel?._bindings[this] = widget;
  }

  @override
  void dispose() {
    _panel?._bindings.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    autofocus: _visible && widget.autofocus,
    canRequestFocus: _visible,
    onKeyEvent: (_, event) =>
        _visible ? widget.onKeyEvent(event) : KeyEventResult.ignored,
    child: widget.child,
  );
}
