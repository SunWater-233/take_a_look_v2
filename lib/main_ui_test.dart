import 'dart:io';

import 'src/app/app.dart';
import 'src/app/bootstrap.dart';
import 'src/ui_test/ui_test_app.dart';
import 'src/ui_test/ui_test_session.dart';
import 'src/workspace/workspace_layout.dart';

Future<void> main(List<String> args) async {
  final launch = detachedPanelLaunchFromEntrypointArguments(args);
  Directory? directory;
  if (launch == null) {
    final override = Platform.environment['TAL_UI_TEST_DATA_DIR'];
    directory = Directory(
      override ??
          '${WorkspaceLayoutRepository.defaultFile().parent.parent.path}/TakeALookUiTest',
    );
    await directory.create(recursive: true);
    await File(
      '${directory.path}/motor_control.c',
    ).writeAsString(UiTestSession.sourceText);
  }
  await launchWorkbench(
    args,
    title: 'Take A Look - UI 测试版（模拟数据）',
    appBuilder: (launch) => launch == null
        ? UiTestApp(
            directory: directory!,
            smokeTest: args.contains('--smoke-test'),
          )
        : TakeALookApp(
            detachedPanel: launch.panel,
            detachedPanels: launch.groupPanels,
            secondaryWindowRole: launch.role,
          ),
  );
}
