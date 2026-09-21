part of '../panels.dart';

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
          ],
        ),
      ),
    );
  }
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
