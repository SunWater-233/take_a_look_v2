import 'dart:async';
import 'package:flutter/material.dart';
import '../controller/controller.dart';
import '../models/models.dart' show ConnectionStatus;
import '../protocol/commands.dart';
import '../theme/theme.dart';

Future<void> showEmberPairingDialog(
  BuildContext context,
  TakeALookController controller,
) => showTalDialog<void>(
  context: context,
  builder: (_) => EmberPairingDialog(controller: controller),
);

class EmberPairingDialog extends StatefulWidget {
  const EmberPairingDialog({super.key, required this.controller});
  final TakeALookController controller;

  @override
  State<EmberPairingDialog> createState() => _EmberPairingDialogState();
}

class _EmberPairingDialogState extends State<EmberPairingDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _computer = TextEditingController();
  List<JsonObject> _devices = [];
  JsonObject _pair = const {'status': 'idle'};
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  String? _error;
  String? _notice;

  TakeALookController get controller => widget.controller;
  String get _status => _pair['status'] as String? ?? 'idle';
  bool get _pending => const {'connecting', 'waiting'}.contains(_status);
  bool get _editable =>
      !_busy &&
      !_pending &&
      controller.connectionStatus == ConnectionStatus.disconnected;

  @override
  void initState() {
    super.initState();
    _host.text = controller.remoteConfig['host'] ?? '';
    _port.text = controller.remoteConfig['gatewayPort'] ?? '4242';
    controller.connectionChanges.addListener(_changed);
    unawaited(_load());
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_pending) {
      unawaited(
        controller
            .requestEmber('cancel')
            .catchError((_) => <String, Object?>{}),
      );
    }
    controller.connectionChanges.removeListener(_changed);
    _host.dispose();
    _port.dispose();
    _computer.dispose();
    super.dispose();
  }

  void _setDevices(JsonObject result) {
    _devices = (result['devices'] as List? ?? [])
        .map((p) => Map<String, Object?>.from(p as Map))
        .toList();
  }

  Future<void> _load({bool scan = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await controller.requestEmber(
        scan ? 'discover' : 'devices',
      );
      if (!mounted) return;
      setState(() => _setDevices(result));
      if (!scan) {
        final state = await controller.requestEmber('status');
        if (mounted) setState(() => _pair = state);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start([JsonObject? phone]) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final state = await controller.requestEmber('pair', {
        'host': phone?['host'] ?? _host.text.trim(),
        'port': phone?['port'] ?? _port.text.trim(),
        'deviceId': phone?['id'] ?? '',
        'name': _computer.text.trim(),
      });
      if (mounted) {
        setState(() => _pair = state);
      } else if (const {'connecting', 'waiting'}.contains(state['status'])) {
        await controller.requestEmber('cancel');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _poll() async {
    if (!_pending || _polling) return;
    _polling = true;
    try {
      final state = await controller.requestEmber('status');
      if (!mounted) return;
      setState(() => _pair = state);
      if (_status == 'paired') {
        final device = Map<String, Object?>.from(state['device'] as Map);
        controller.setRemoteConfig({
          'host': device['host'] as String,
          'gatewayPort': device['port'] as String,
          'deviceId': device['id'] as String,
          'token': '',
        });
        final result = await controller.requestEmber('devices');
        if (mounted) setState(() => _setDevices(result));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _pair = const {'status': 'failed'};
        });
      }
      unawaited(
        controller
            .requestEmber('cancel')
            .catchError((_) => <String, Object?>{}),
      );
    } finally {
      _polling = false;
    }
  }

  Future<void> _cancel() async {
    try {
      await controller.requestEmber('cancel');
      // Keep polling until the phone request has actually been cancelled.
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _forget(JsonObject phone) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await controller.requestEmber('forget', {
        'deviceId': phone['id'],
      });
      if (!mounted) return;
      if (controller.remoteConfig['deviceId'] == phone['id']) {
        controller.setRemoteConfig({'deviceId': ''});
      }
      setState(() {
        _setDevices(result);
        _notice = result['warning'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _select(JsonObject phone) {
    controller.setRemoteConfig({
      'host': phone['host'] as String,
      'gatewayPort': phone['port'] as String,
      'deviceId': phone['id'] as String,
      'token': '',
    });
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final code = _pair['code'] as String?;
    final expiresAt = _pair['expiresAt'] as int?;
    final seconds = expiresAt == null
        ? 120
        : ((expiresAt - DateTime.now().millisecondsSinceEpoch) / 1000)
              .ceil()
              .clamp(0, 120);
    return AlertDialog(
      title: const Text('连接 EmberMobile'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '手机和电脑连接同一局域网，在手机开启 Ember 服务。首次配对后可自动认证，无需重复复制令牌。',
                style: talBody,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(child: Text('附近与已配对手机', style: talBody)),
                  TextButton.icon(
                    key: const ValueKey('ember-discover'),
                    onPressed: _editable ? () => _load(scan: true) : null,
                    icon: const Icon(Icons.refresh, size: 17),
                    label: Text(_busy ? '请稍候…' : '搜索手机'),
                  ),
                ],
              ),
              if (_devices.isEmpty && !_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('尚无手机。点击「搜索手机」，或在下方输入手机地址配对。', style: talBody),
                ),
              for (final phone in _devices)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      const Icon(Icons.smartphone, size: 23),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              phone['name'] as String,
                              style: talBody,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${phone['host']}:${phone['port']} · ${phone['paired'] == true ? '已配对' : '未配对'}${phone['online'] == true ? ' · 附近' : ''}',
                              style: talBody,
                            ),
                          ],
                        ),
                      ),
                      if (phone['paired'] == true) ...[
                        TextButton(
                          onPressed: _editable ? () => _select(phone) : null,
                          child: const Text('使用'),
                        ),
                        IconButton(
                          tooltip: '忘记 ${phone['name']}',
                          onPressed: _editable ? () => _forget(phone) : null,
                          icon: const Icon(Icons.link_off, size: 19),
                        ),
                      ] else
                        TextButton(
                          onPressed: _editable ? () => _start(phone) : null,
                          child: const Text('配对'),
                        ),
                    ],
                  ),
                ),
              const Divider(height: 24),
              TextField(
                controller: _computer,
                enabled: _editable,
                decoration: const InputDecoration(
                  labelText: '电脑名称',
                  hintText: '留空使用当前电脑名称',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('ember-manual-host'),
                      controller: _host,
                      enabled: _editable,
                      decoration: const InputDecoration(
                        labelText: '手机地址',
                        hintText: '手机 IP 或主机名',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _port,
                      enabled: _editable,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '网关端口'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TalButton(
                  key: const ValueKey('ember-manual-pair'),
                  onPressed: _editable ? () => _start() : null,
                  child: const Text('通过地址配对'),
                ),
              ),
              if (_pending) ...[
                const Divider(height: 28),
                Text(
                  _status == 'waiting' ? '核对手机上的校验码' : '正在联系手机…',
                  textAlign: TextAlign.center,
                  style: talBody,
                ),
                if (code != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(
                      '${code.substring(0, 4)} ${code.substring(4)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3,
                      ),
                    ),
                  ),
                Text(
                  code == null
                      ? '等待建立配对请求。'
                      : '两端相同后，在手机点击「同意配对」。剩余 $seconds 秒。',
                  textAlign: TextAlign.center,
                  style: talBody,
                ),
                Center(
                  child: TextButton(
                    onPressed: _cancel,
                    child: const Text('取消配对'),
                  ),
                ),
              ],
              if (_status == 'paired')
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('配对成功，已选择此手机。关闭后可连接目标。', style: talBody),
                ),
              if (_status == 'cancelled')
                const Text('已取消配对，可重新发起。', style: talBody),
              if (_status == 'failed' && _pair['message'] != null)
                Text(
                  _pair['message'] as String,
                  style: talBody.copyWith(color: TalColors.warning),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: talBody.copyWith(color: TalColors.warning),
                  ),
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_notice!, style: talBody),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
