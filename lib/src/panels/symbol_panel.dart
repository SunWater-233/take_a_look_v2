part of '../panels.dart';

class _SymbolPanel extends StatefulWidget {
  const _SymbolPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_SymbolPanel> createState() => _SymbolPanelState();
}

class _SymbolPanelState extends State<_SymbolPanel> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller.symbolChanges,
      builder: (context, _) {
        final symbols = widget.controller.symbols
            .where((item) => item.matches(search.text))
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      decoration: BoxDecoration(
                        color: TalColors.input,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: TalColors.border),
                      ),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.controller.symbolFile.isEmpty
                            ? '尚未读取 .elf / .axf'
                            : widget.controller.symbolFile,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.controller.symbolFile.isEmpty
                            ? talMuted
                            : talBody,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 76,
                    child: OutlinedButton(
                      onPressed: widget.controller.chooseSymbolFile,
                      child: const Text('选择文件'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 56,
                    child: OutlinedButton(
                      onPressed: widget.controller.symbols.isEmpty
                          ? null
                          : widget.controller.refreshSymbols,
                      child: const Text('刷新'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SizedBox(
                height: 32,
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  style: talBody,
                  decoration: const InputDecoration(
                    hintText: '按变量名或地址过滤',
                    prefixIcon: Icon(Icons.search, size: 17),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: _TableHeader(
                columns: [_ColumnSpec('来源文件 / 变量', 1), _ColumnSpec('地址', 0.46)],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: TalColors.input,
                    border: Border(
                      left: BorderSide(color: TalColors.border),
                      right: BorderSide(color: TalColors.border),
                      bottom: BorderSide(color: TalColors.border),
                    ),
                  ),
                  child: symbols.isEmpty
                      ? const SizedBox.expand()
                      : ListView.builder(
                          itemCount: symbols.length,
                          itemBuilder: (context, index) {
                            final item = symbols[index];
                            final selected = widget.controller.selectedSymbols
                                .contains(item.key);
                            return InkWell(
                              onTap: () =>
                                  widget.controller.toggleSymbol(item.key),
                              child: Container(
                                height: 42,
                                color: selected
                                    ? TalColors.selection
                                    : TalColors.input,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Row(
                                  children: [
                                    Checkbox(
                                      value: selected,
                                      onChanged: (_) => widget.controller
                                          .toggleSymbol(item.key),
                                    ),
                                    const Icon(
                                      Icons.data_object,
                                      size: 15,
                                      color: TalColors.accent,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: talBody,
                                          ),
                                          Text(
                                            item.source,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: talMuted,
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(
                                      width: 112,
                                      child: Text(
                                        item.addressLabel,
                                        style: talMono,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
            Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: TalColors.surface,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.controller.symbols.isEmpty
                          ? '读取完成后，变量会按来源文件分层展示。'
                          : '${widget.controller.symbols.length} 个变量，已选择 ${widget.controller.selectedSymbols.length} 个',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: talMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 160,
                    child: OutlinedButton(
                      onPressed: widget.controller.selectedSymbols.isEmpty
                          ? null
                          : widget.controller.addSelectedToWatch,
                      child: const Text('加入实时调参'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
