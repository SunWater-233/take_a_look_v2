part of 'panels.dart';

class _AnalysisStatsHeaderCell extends StatefulWidget {
  const _AnalysisStatsHeaderCell({
    required this.label,
    required this.width,
    required this.columnIndex,
    required this.onResize,
    required this.selected,
    required this.onSelect,
    required this.hideLabel,
    required this.canHide,
    required this.onHide,
    required this.onShowAll,
    required this.onTouchContextMenu,
    super.key,
  });

  final String label;
  final double width;
  final int columnIndex;
  final _ColumnResizeCallback onResize;
  final bool selected;
  final ValueChanged<int> onSelect;
  final String hideLabel;
  final bool canHide;
  final VoidCallback onHide;
  final VoidCallback onShowAll;
  final ValueChanged<_ContextMenuRequest> onTouchContextMenu;

  @override
  State<_AnalysisStatsHeaderCell> createState() =>
      _AnalysisStatsHeaderCellState();
}

class _AnalysisStatsHeaderCellState extends State<_AnalysisStatsHeaderCell> {
  final MenuController _menuController = MenuController();
  TalMenuAnimationLease? _menuAnimationLease;

  @override
  void dispose() {
    _releaseMenuAnimation();
    super.dispose();
  }

  void _openDesktopMenu(Offset position) {
    if (!_menuController.isOpen && _menuAnimationLease == null) {
      _menuAnimationLease = beginTalMenuAnimation();
    }
    _menuController.open(position: position);
  }

  void _handleMenuAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _releaseMenuAnimation();
  }

  void _releaseMenuAnimation() {
    _menuAnimationLease?.release();
    _menuAnimationLease = null;
  }

  void _handleContextMenu(_ContextMenuRequest request) {
    if (request.touchOptimized) {
      if (_menuController.isOpen) _menuController.close();
      widget.onTouchContextMenu(request);
      return;
    }
    final box = context.findRenderObject()! as RenderBox;
    _openDesktopMenu(box.globalToLocal(request.globalPosition));
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      key: const ValueKey('analysis-header-menu-anchor'),
      controller: _menuController,
      style: Theme.of(context).menuTheme.style,
      consumeOutsideTap: true,
      animated: true,
      onAnimationStatusChanged: _handleMenuAnimationStatus,
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('analysis-header-menu-hide'),
          onPressed: widget.canHide ? widget.onHide : null,
          child: Text(widget.hideLabel),
        ),
        MenuItemButton(
          key: const ValueKey('analysis-header-menu-show-all'),
          onPressed: widget.onShowAll,
          child: const Text('显示全列'),
        ),
      ],
      child: _ResizableTableHeaderCell(
        label: widget.label,
        width: widget.width,
        columnIndex: widget.columnIndex,
        keyPrefix: 'analysis-stats',
        onResize: widget.onResize,
        selected: widget.selected,
        onSelect: widget.onSelect,
        onContextMenu: (_, request) => _handleContextMenu(request),
      ),
    );
  }
}

class _AnalysisStatsCell extends StatefulWidget {
  const _AnalysisStatsCell({
    required this.width,
    required this.selected,
    required this.onTap,
    required this.onMenuOpen,
    required this.onCopy,
    required this.onOnly,
    required this.onAll,
    required this.onTouchContextMenu,
    required this.child,
    super.key,
  });

  final double width;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onMenuOpen;
  final VoidCallback onCopy;
  final VoidCallback onOnly;
  final VoidCallback onAll;
  final ValueChanged<_ContextMenuRequest> onTouchContextMenu;
  final Widget child;

  @override
  State<_AnalysisStatsCell> createState() => _AnalysisStatsCellState();
}

class _AnalysisStatsCellState extends State<_AnalysisStatsCell> {
  final MenuController _menuController = MenuController();
  TalMenuAnimationLease? _menuAnimationLease;

  @override
  void dispose() {
    _releaseMenuAnimation();
    super.dispose();
  }

  void _openDesktopMenu(Offset position) {
    widget.onMenuOpen();
    if (!_menuController.isOpen && _menuAnimationLease == null) {
      _menuAnimationLease = beginTalMenuAnimation();
    }
    _menuController.open(position: position);
  }

  void _handleMenuAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _releaseMenuAnimation();
  }

  void _releaseMenuAnimation() {
    _menuAnimationLease?.release();
    _menuAnimationLease = null;
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      key: const ValueKey('analysis-cell-menu-anchor'),
      controller: _menuController,
      style: Theme.of(context).menuTheme.style,
      consumeOutsideTap: true,
      animated: true,
      onAnimationStatusChanged: _handleMenuAnimationStatus,
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('analysis-cell-menu-copy'),
          onPressed: widget.onCopy,
          child: const Text('复制'),
        ),
        MenuItemButton(
          key: const ValueKey('analysis-cell-menu-only'),
          onPressed: widget.onOnly,
          child: const Text('仅绘制该栏'),
        ),
        MenuItemButton(
          key: const ValueKey('analysis-cell-menu-all'),
          onPressed: widget.onAll,
          child: const Text('全部绘制'),
        ),
      ],
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: () {
          if (_menuController.isOpen) _menuController.close();
          final box = context.findRenderObject()! as RenderBox;
          widget.onTouchContextMenu(
            _ContextMenuRequest(
              globalPosition: box.localToGlobal(box.size.center(Offset.zero)),
              touchOptimized: true,
            ),
          );
        },
        onSecondaryTapUp: (details) => _openDesktopMenu(details.localPosition),
        child: Container(
          width: widget.width,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: widget.selected ? TalColors.selection : Colors.transparent,
            border: const Border(
              right: BorderSide(color: TalColors.borderSoft),
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

PopupMenuEntry<String> _analysisPopupItem({
  required String value,
  required String label,
  bool enabled = true,
  required bool touchOptimized,
}) {
  return PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    height: TalUiTheme.forTouch(touchOptimized).menuItemHeight,
    child: Text(label),
  );
}
