part of 'source_debug_panel.dart';

extension _SourceSearchView on _SourceDebugPanelState {
  Widget _buildSearchField() {
    final query = _searchController.text.trim();
    final filesOnly = _searchMode == SourceSearchMode.files;
    final status = _searching
        ? '搜索中…'
        : query.isEmpty
        ? filesOnly
              ? '输入文件名'
              : '输入变量名或文本'
        : _searchResults.isEmpty
        ? '无结果'
        : '${_activeSearchIndex + 1} / ${_searchResults.length}';
    final ui = TalUiTheme.of(context);
    return LayoutBuilder(
      key: _searchFieldLayoutKey,
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final buttonWidth = math.min(ui.iconButtonSize, width / 6);
        return Container(
          key: const ValueKey('source-search-area'),
          color: TalColors.surfaceAlt,
          height: ui.iconButtonSize + 1,
          child: Row(
            children: [
              const SizedBox(width: 10),
              const Icon(Icons.search, size: 16, color: TalColors.muted),
              const SizedBox(width: 7),
              Expanded(
                child: TextField(
                  key: const ValueKey('source-search-field'),
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  maxLines: 1,
                  onChanged: _queueSearch,
                  onSubmitted: (_) => _confirmSearchResult(),
                  style: const TextStyle(
                    color: TalColors.text,
                    fontSize: 12,
                    fontFamily: talFontFamily,
                    fontFamilyFallback: talFontFamilyFallback,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: filesOnly ? '查找文本文件名或路径' : '查找变量、文件名或源码内容',
                    hintStyle: talMuted.copyWith(fontSize: 12),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              SizedBox(
                width: math.min(106, width * .23),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: talMuted.copyWith(fontSize: 11),
                ),
              ),
              for (final (name, label, icon, action) in [
                (
                  'previous',
                  '上一个结果（↑）',
                  Icons.keyboard_arrow_up,
                  _searchResults.isEmpty ? null : () => _moveSearchResult(-1),
                ),
                (
                  'next',
                  '下一个结果（↓）',
                  Icons.keyboard_arrow_down,
                  _searchResults.isEmpty ? null : () => _moveSearchResult(1),
                ),
                ('close', '关闭搜索（Esc）', Icons.close, _closeSearch),
              ])
                SizedBox(
                  width: buttonWidth,
                  child: _DebugToolbarButton(
                    key: ValueKey('source-search-$name'),
                    tooltip: label,
                    icon: icon,
                    onPressed: action,
                  ),
                ),
              const SizedBox(width: 4),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchResults() => LayoutBuilder(
    builder: (context, constraints) {
      final labelWidth = math.min(220.0, constraints.maxWidth / 2);
      return Container(
        height: math.min(
          168.0,
          _searchResults.length * _SourceDebugPanelState._searchResultHeight,
        ),
        decoration: const BoxDecoration(
          color: TalColors.surface,
          border: Border.symmetric(
            horizontal: BorderSide(color: TalColors.borderSoft),
          ),
        ),
        child: ListView.builder(
          key: const ValueKey('source-search-results'),
          controller: _searchResultsController,
          itemExtent: _SourceDebugPanelState._searchResultHeight,
          itemCount: _searchResults.length,
          itemBuilder: (context, index) {
            final result = _searchResults[index];
            final selected = index == _activeSearchIndex;
            final variableName = result.variableName;
            final filename = _basename(result.path);
            final label =
                variableName ??
                (result.isFile
                    ? filename
                    : '$filename:${result.line}:${result.column}');
            return Tooltip(
              message: result.isFile || variableName != null
                  ? result.preview
                  : result.path,
              child: InkWell(
                key: ValueKey('source-search-result-$index'),
                onTap: () => _activateSearchResult(index),
                child: ColoredBox(
                  color: selected
                      ? TalColors.selection.withValues(alpha: 0.55)
                      : Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(
                          variableName != null
                              ? Icons.data_object
                              : result.isFile
                              ? Icons.insert_drive_file_outlined
                              : Icons.find_in_page_outlined,
                          size: 14,
                          color: TalColors.muted,
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: labelWidth,
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: TalColors.text,
                              fontSize: 11,
                              fontFamily: talFontFamily,
                              fontFamilyFallback: talFontFamilyFallback,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            result.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: talMuted.copyWith(
                              fontSize: 11,
                              fontFamily: talFontFamily,
                              fontFamilyFallback: talFontFamilyFallback,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
