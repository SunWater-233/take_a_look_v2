import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/theme.dart';
import 'update_controller.dart';
import 'update_models.dart';

Future<void> showAppUpdateDialog(
  BuildContext context,
  AppUpdateController updates, {
  Future<void> Function()? onInstall,
}) async {
  if (updates.dialogOpen) return;
  updates.dialogOpen = true;
  try {
    unawaited(updates.initialize());
    await showTalDialog<void>(
      context: context,
      builder: (_) => _UpdateDialog(updates: updates, onInstall: onInstall),
    );
  } finally {
    updates.dialogOpen = false;
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.updates, this.onInstall});
  final AppUpdateController updates;
  final Future<void> Function()? onInstall;
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  String? _linkError;

  Future<void> _openRelease() async {
    final url =
        widget.updates.release?.page ??
        Uri.https('github.com', '/$updateRepository/releases');
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('浏览器未能打开。');
      }
    } catch (_) {
      if (mounted) setState(() => _linkError = '无法打开浏览器，请复制此地址：\n$url');
    }
  }

  Future<void> _install() async {
    final confirmed = await showTalDialog<bool>(
      context: context,
      builder: (context) => TalDialog(
        title: const Text('重启并更新'),
        content: const Text(
          '将保存当前工作区，停止采集并断开设备，然后关闭所有窗口安装更新。完成后会重新打开工作区，设备连接由你手动恢复。',
        ),
        actions: [
          TalButton(
            variant: TalButtonVariant.text,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续使用'),
          ),
          TalButton(
            variant: TalButtonVariant.filled,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重启并更新'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await widget.onInstall?.call();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.updates,
    builder: (context, _) {
      final updates = widget.updates;
      final transfer = updates.transfer;
      final downloading = transfer == UpdateTransfer.downloading;
      final installing = transfer == UpdateTransfer.installing;
      final ready = transfer == UpdateTransfer.ready;
      final status = !updates.initialized
          ? '正在读取版本信息…'
          : updates.checking
          ? '正在检查更新…'
          : updates.currentVersion.isEmpty
          ? '无法读取当前版本，可前往 GitHub 下载完整发布包。'
          : updates.hasUpdate
          ? '发现新版本 ${updates.release!.tag}${updates.release!.isPrerelease ? '（预览版）' : ''}'
          : updates.checked && updates.release == null
          ? (updates.includePrereleases
                ? '尚无可用的公开版本，或仓库暂不可访问。'
                : '尚无公开正式版本，或仓库暂不可访问。')
          : updates.checked
          ? '当前已是最新版本。'
          : '点击“立即检查”获取最新版本。';
      return PopScope(
        canPop: !installing,
        child: TalDialog(
          title: const Text('关于与更新'),
          content: SizedBox(
            width: 540,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Take A Look',
                  style: TextStyle(
                    fontFamily: talBrandFontFamily,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: TalColors.heading,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '当前版本：${updates.currentVersion.isEmpty ? '读取中…' : updates.currentVersion}',
                  style: talMuted,
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  key: const ValueKey('update-auto-check'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动检测更新'),
                  subtitle: const Text('启动时在后台检查，每 24 小时最多一次'),
                  value: updates.autoCheck,
                  onChanged: !updates.initialized || installing
                      ? null
                      : (value) => unawaited(updates.setAutoCheck(value)),
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('update-include-prereleases'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('接收预览版更新'),
                  subtitle: const Text('包含 GitHub 预发布及 beta、rc 等测试版本'),
                  value: updates.includePrereleases,
                  onChanged: !updates.initialized || updates.busy
                      ? null
                      : (value) =>
                            unawaited(updates.setIncludePrereleases(value)),
                ),
                const Divider(),
                const SizedBox(height: 8),
                Text(status, style: talStrong),
                if (updates.checking || installing) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (updates.hasUpdate &&
                    updates.release!.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 170),
                    child: SingleChildScrollView(
                      child: SelectableText(updates.release!.notes),
                    ),
                  ),
                ],
                if (downloading || ready) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: updates.totalBytes > 0
                        ? updates.receivedBytes / updates.totalBytes
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ready
                        ? '下载完成，SHA-256 校验通过。'
                        : '已下载 ${_size(updates.receivedBytes)} / ${_size(updates.totalBytes)}',
                  ),
                ],
                if (installing) ...[
                  const SizedBox(height: 8),
                  const Text('正在准备更新程序，请稍候…'),
                ],
                if (updates.hasUpdate &&
                    updates.asset == null &&
                    !updates.busy) ...[
                  const SizedBox(height: 12),
                  Text(
                    updates.package == null
                        ? '此运行目录不支持自动安装，可前往 GitHub 下载完整发布包。'
                        : '此发布尚无与当前系统及安装方式匹配的唯一安装包。',
                    style: talMuted,
                  ),
                ],
                if (updates.lastUpdateMessage != null &&
                    updates.error != updates.lastUpdateMessage) ...[
                  const SizedBox(height: 12),
                  SelectableText(updates.lastUpdateMessage!, style: talMuted),
                ],
                if (updates.error != null || _linkError != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    _linkError ?? updates.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TalButton(
                  variant: TalButtonVariant.text,
                  onPressed: installing ? null : () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
                TalButton(
                  variant: TalButtonVariant.text,
                  onPressed: installing ? null : _openRelease,
                  child: const Text('GitHub 发布页'),
                ),
                if (updates.hasUpdate && !updates.busy && !ready)
                  TalButton(
                    variant: TalButtonVariant.text,
                    onPressed: () => unawaited(updates.ignoreVersion()),
                    child: const Text('忽略此版本'),
                  ),
                if (downloading)
                  TalButton(
                    onPressed: updates.cancelDownload,
                    child: const Text('取消下载'),
                  )
                else if (ready)
                  TalButton(
                    variant: TalButtonVariant.filled,
                    onPressed: installing || widget.onInstall == null
                        ? null
                        : _install,
                    child: const Text('重启并更新'),
                  )
                else ...[
                  TalButton(
                    onPressed: updates.busy || !updates.initialized
                        ? null
                        : () => unawaited(updates.check()),
                    child: const Text('立即检查'),
                  ),
                  if (updates.hasUpdate && updates.asset != null)
                    TalButton(
                      variant: TalButtonVariant.filled,
                      onPressed: updates.busy
                          ? null
                          : () => unawaited(updates.download()),
                      child: const Text('下载更新'),
                    ),
                ],
              ],
            ),
          ],
        ),
      );
    },
  );

  String _size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
