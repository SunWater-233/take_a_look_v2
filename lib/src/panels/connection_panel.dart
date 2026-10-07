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
                    'ember': 'EmberMobile 私有协议',
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
                child: TalDropdown<String>(
                  value: controller.targetName,
                  values: const [
                    'auto',
                    'stm32f407vg',
                    'stm32g431rb',
                    'nrf52840',
                  ],
                  label: (value) => value,
                  onChanged: controller.setTargetName,
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
        field('host', '远程地址', '手机 IP 或主机名'),
        if (ember) ...[
          field('gatewayPort', '网关端口', '4242'),
          field('token', '访问令牌', '手机显示的本次访问令牌', secret: true),
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
          field('gdbPath', 'GDB 程序', '留空从 PATH 查找，或填写完整路径'),
        ],
        Text(
          ember
              ? '先在手机授权探针、连接目标并启动网关。v2 使用 UDP 4243；访问令牌包含证书指纹。实时优先会跳过旧样本，RTT-Plus 始终可靠传输。'
                    '${gdb ? '此模式会连接或启动手机 GDB，连接后目标将暂停；运行时采样请使用 RTT。' : '支持内存读取和 RTT；写变量请切换到 GDB 模式。'}'
              : '连接已有 GDB Server。请选择适合目标架构的 GDB；此模式不提供运行态内存采样或 RTT。',
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
    onChanged: (value) =>
        widget.controller.setRemoteConfig({widget.name: value}),
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
