part of 'panels.dart';

class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.connectionChanges,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _LabeledField(
              label: '连接方式',
              child: IgnorePointer(
                ignoring:
                    controller.connectionStatus !=
                    ConnectionStatus.disconnected,
                child: TalDropdown<String>(
                  key: const ValueKey('connection-kind'),
                  value: controller.connectionKind,
                  values: const ['local', 'ember', 'emberGdb', 'gdb'],
                  label: (value) => const {
                    'local': '本地 USB / pyOCD',
                    'ember': 'EmberMobile',
                    'emberGdb': 'EmberMobile + GDB',
                    'gdb': '远程 GDB',
                  }[value]!,
                  onChanged: controller.setConnectionKind,
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (controller.connectionKind == 'local') ...[
              _LabeledField(
                label: '探针',
                child: TalDropdown<String>(
                  value: controller.probeType,
                  values: const ['自动发现任意探针', 'CMSIS-DAP', 'ST-Link', 'J-Link'],
                  label: (value) => value,
                  onChanged: controller.setProbeType,
                ),
              ),
              const SizedBox(height: 10),
              _LabeledField(
                label: '目标芯片',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TalButton(
                      key: const ValueKey('target-chip-selector'),
                      onPressed: () =>
                          showTargetChipDialog(context, controller),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              controller.targetName == 'auto'
                                  ? '自动选择 / 通用 Cortex-M'
                                  : controller.targetPartNumber,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.search, size: 16),
                        ],
                      ),
                    ),
                    if (controller.targetPackMissing)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          '芯片包缺失，请重新导入。',
                          style: TextStyle(
                            fontSize: 12,
                            color: TalColors.warning,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _LabeledField(
                label: 'SWD 时钟',
                child: TalDropdown<String>(
                  value: controller.swdClock,
                  values: const [
                    '100 kHz',
                    '400 kHz',
                    '1 MHz',
                    '2 MHz',
                    '4 MHz',
                    '8 MHz',
                    '12 MHz',
                    '24 MHz',
                  ],
                  label: (value) => value,
                  onChanged: controller.setSwdClock,
                ),
              ),
              const SizedBox(height: 10),
              _LabeledField(
                label: '序列号',
                child: _SerialNumberField(controller: controller),
              ),
            ] else
              _RemoteConnectionFields(controller: controller),
          ],
        ),
      ),
    );
  }
}

class _RemoteConnectionFields extends StatelessWidget {
  const _RemoteConnectionFields({required this.controller});
  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    final ember = controller.connectionKind != 'gdb';
    final gdb = controller.connectionKind != 'ember';
    Widget field(
      String name,
      String label,
      String hint, {
      bool secret = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _LabeledField(
        label: label,
        child: _RemoteConnectionField(
          key: ValueKey('remote-$name'),
          controller: controller,
          name: name,
          hint: hint,
          secret: secret,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (ember) ...[
          SizedBox(
            width: double.infinity,
            child: TalButton(
              key: const ValueKey('ember-pairing'),
              onPressed:
                  controller.connectionStatus == ConnectionStatus.disconnected
                  ? () => showEmberPairingDialog(context, controller)
                  : null,
              child: const Row(
                children: [
                  Icon(Icons.phonelink_ring_outlined, size: 17),
                  SizedBox(width: 8),
                  Text('配对 / 管理手机'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            (controller.remoteConfig['deviceId'] ?? '').isNotEmpty
                ? '已选择配对手机，留空令牌即可自动连接。'
                : '首次配对时核对两端校验码，在手机同意后即可记住设备。',
            style: talBody,
          ),
          const SizedBox(height: 12),
        ],
        field('host', '远程地址', '手机 IP 或主机名'),
        if (ember) ...[
          field('gatewayPort', '网关端口', '4242'),
          field('token', '访问令牌', '已配对可留空；或粘贴手机本次令牌', secret: true),
          field('core', '核心编号', '0'),
          _LabeledField(
            label: 'RTT 传输',
            child: IgnorePointer(
              ignoring:
                  controller.connectionStatus != ConnectionStatus.disconnected,
              child: TalDropdown<String>(
                value: controller.remoteConfig['rttDelivery'] ?? 'reliable',
                values: const ['reliable', 'latest'],
                label: (value) => value == 'latest' ? '实时优先（Normal）' : '可靠传输',
                onChanged: (value) =>
                    controller.setRemoteConfig({'rttDelivery': value}),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (controller.state.connection.gatewayProtocolVersion != null)
            Text(
              controller.state.connection.gatewayProtocolVersion == 2
                  ? '已连接 v2 · QUIC 二进制推送'
                  : '已连接 v1 · 兼容模式',
              style: talBody,
            ),
        ],
        if (gdb) ...[
          field('gdbPort', 'GDB 端口', '3333'),
          if (!ember) ...[
            _LabeledField(
              label: '使用方式',
              child: IgnorePointer(
                ignoring:
                    controller.connectionStatus !=
                    ConnectionStatus.disconnected,
                child: TalDropdown<String>(
                  value: controller.remoteConfig['gdbMode'] ?? 'debug',
                  values: const ['debug', 'memory'],
                  label: (value) => value == 'memory' ? '高速内存采样（只读）' : '断点调试',
                  onChanged: (value) =>
                      controller.setRemoteConfig({'gdbMode': value}),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (!controller.isGdbMemoryMode)
            field('gdbPath', 'GDB 程序', '留空从 PATH 查找，或填写完整路径'),
        ],
        Text(
          ember
              ? '配对后，先在手机授权探针、连接目标，再连接工作台。实时优先会跳过旧样本，RTT-Plus 始终可靠传输。'
                    '${gdb ? '此模式会连接或启动手机 GDB，连接后目标将暂停；运行时采样请使用 RTT。' : '支持内存读取和 RTT；写变量请切换到 GDB 模式。'}'
              : controller.isGdbMemoryMode
              ? '使用标准 GDB 协议直接读取，不需要 GDB 程序。目标需支持运行中读内存。服务端可能在连接时暂停目标，可在调试工具栏点击继续运行；此模式不提供写入、单步、复位、断点或 RTT。'
              : '连接已有 GDB Server。请选择适合目标架构的 GDB；断点调试模式需暂停目标后读取内存。',
          style: talBody,
        ),
      ],
    );
  }
}

class _RemoteConnectionField extends StatefulWidget {
  const _RemoteConnectionField({
    super.key,
    required this.controller,
    required this.name,
    required this.hint,
    this.secret = false,
  });
  final TakeALookController controller;
  final String name;
  final String hint;
  final bool secret;

  @override
  State<_RemoteConnectionField> createState() => _RemoteConnectionFieldState();
}

class _RemoteConnectionFieldState extends State<_RemoteConnectionField> {
  late final TextEditingController editor = TextEditingController(
    text: widget.controller.remoteConfig[widget.name] ?? '',
  );
  final FocusNode focus = FocusNode();

  @override
  void didUpdateWidget(covariant _RemoteConnectionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final value = widget.controller.remoteConfig[widget.name] ?? '';
    if (!focus.hasFocus && editor.text != value) editor.text = value;
  }

  @override
  void dispose() {
    editor.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: editor,
    focusNode: focus,
    enabled:
        widget.controller.connectionStatus == ConnectionStatus.disconnected,
    obscureText: widget.secret,
    autocorrect: false,
    enableSuggestions: false,
    onChanged: (value) => widget.controller.setRemoteConfig({
      widget.name: value,
      if (const {'host', 'gatewayPort'}.contains(widget.name)) 'deviceId': '',
    }),
    style: talBody,
    decoration: InputDecoration(hintText: widget.hint),
  );
}

class _SerialNumberField extends StatefulWidget {
  const _SerialNumberField({required this.controller});

  final TakeALookController controller;

  @override
  State<_SerialNumberField> createState() => _SerialNumberFieldState();
}

class _SerialNumberFieldState extends State<_SerialNumberField> {
  late final TextEditingController editor;
  late final FocusNode focusNode;

  @override
  void initState() {
    super.initState();
    editor = TextEditingController(text: widget.controller.serialNumber);
    focusNode = FocusNode();
    widget.controller.connectionChanges.addListener(_syncFromController);
  }

  @override
  void didUpdateWidget(covariant _SerialNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.connectionChanges.removeListener(_syncFromController);
    widget.controller.connectionChanges.addListener(_syncFromController);
    _syncFromController();
  }

  void _syncFromController() {
    final value = widget.controller.serialNumber;
    if (focusNode.hasFocus || editor.text == value) return;
    editor.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    widget.controller.connectionChanges.removeListener(_syncFromController);
    editor.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: editor,
      focusNode: focusNode,
      onChanged: widget.controller.setSerialNumber,
      style: talBody,
      decoration: const InputDecoration(hintText: '留空表示自动选择'),
    );
  }
}
