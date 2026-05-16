part of '../take_a_look_app.dart';

class Panel extends StatelessWidget {
  const Panel({
    required this.icon,
    required this.title,
    required this.child,
    this.actions = const [],
    this.padding = const EdgeInsets.all(12),
    this.chrome,
    super.key,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final List<Widget> actions;
  final EdgeInsets padding;
  final PanelChromeConfig? chrome;

  @override
  Widget build(BuildContext context) {
    final borderColor = chrome?.mergeHighlighted == true
        ? TalColors.cyan
        : TalColors.border;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: TalColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.only(left: 12, right: 6),
              decoration: const BoxDecoration(
                color: TalColors.panelHeader,
                border: Border(bottom: BorderSide(color: TalColors.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: chrome?.onToggleFloat,
                      onPanStart: chrome?.onHeaderPanStart,
                      onPanUpdate: chrome?.onHeaderPanUpdate,
                      onPanEnd: chrome?.onHeaderPanEnd,
                      child: MouseRegion(
                        cursor: chrome == null
                            ? MouseCursor.defer
                            : SystemMouseCursors.grab,
                        child: _PanelTitleArea(
                          icon: icon,
                          title: title,
                          chrome: chrome,
                        ),
                      ),
                    ),
                  ),
                  ...actions,
                  if (chrome != null) ...[
                    IconButton(
                      tooltip: '弹出到独立窗口',
                      onPressed: chrome!.onToggleFloat,
                      icon: const Icon(Icons.open_in_new, size: 18),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Padding(padding: padding, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelTitleArea extends StatelessWidget {
  const _PanelTitleArea({
    required this.icon,
    required this.title,
    required this.chrome,
  });

  final IconData icon;
  final String title;
  final PanelChromeConfig? chrome;

  @override
  Widget build(BuildContext context) {
    final panelChrome = chrome;
    if (panelChrome == null || panelChrome.tabs.length <= 1) {
      return Row(
        children: [
          Icon(icon, size: 18, color: TalColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: TalText.panelTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: panelChrome.tabs.length,
      separatorBuilder: (context, index) => const SizedBox(width: 4),
      itemBuilder: (context, index) {
        final tab = panelChrome.tabs[index];
        final selected = tab.id == panelChrome.activePanel;
        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => panelChrome.onSelectTab(tab.id),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: selected
                    ? TalColors.cyan.withAlpha(34)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? TalColors.cyan : TalColors.borderSoft,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    tab.icon,
                    size: 14,
                    color: selected ? TalColors.cyan : TalColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: selected ? TalText.panelTabActive : TalText.panelTab,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.icon,
    required this.label,
    required this.color,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: TalColors.field,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: TalColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label, style: TalText.pill),
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({required this.color, super.key});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withAlpha(90),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        side: const BorderSide(color: TalColors.borderBright),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

class ToggleActionButton extends StatelessWidget {
  const ToggleActionButton({
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selectedLabel,
    required this.onPressed,
    super.key,
  });

  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String selectedLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(selected ? selectedIcon : icon, size: 18),
      label: Text(selected ? selectedLabel : label),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? TalColors.amber : TalColors.text,
        minimumSize: const Size(0, 36),
        side: BorderSide(
          color: selected ? TalColors.amber : TalColors.borderBright,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: TalColors.field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TalColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TalText.muted),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TalText.metric,
          ),
        ],
      ),
    );
  }
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey(value),
      initialValue: value,
      isExpanded: true,
      dropdownColor: TalColors.surface,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final option in options)
          DropdownMenuItem<String>(
            value: option,
            child: Text(option, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (next) {
        if (next != null) {
          onChanged(next);
        }
      },
    );
  }
}

class _SmallDropdown<T> extends StatelessWidget {
  const _SmallDropdown({
    required this.value,
    required this.values,
    required this.labelBuilder,
    required this.onChanged,
  });

  final T value;
  final List<T> values;
  final String Function(T value) labelBuilder;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: TalColors.field,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: TalColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: TalColors.surface,
          items: [
            for (final item in values)
              DropdownMenuItem<T>(
                value: item,
                child: Text(labelBuilder(item), style: TalText.body),
              ),
          ],
          onChanged: (next) {
            if (next != null) {
              onChanged(next);
            }
          },
        ),
      ),
    );
  }
}
