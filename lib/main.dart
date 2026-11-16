import 'dart:io';

import 'src/app/app.dart';
import 'src/app/bootstrap.dart';

Future<void> main(List<String> args) => launchWorkbench(
  args,
  appBuilder: (launch) => TakeALookApp(
    detachedPanel: launch?.panel,
    detachedPanels: launch?.groupPanels,
    secondaryWindowRole: launch?.role ?? SecondaryWindowRole.detachedPanel,
    enableBackend: launch == null,
    updateSession:
        launch == null &&
            args.length == 2 &&
            args.first == '--restore-after-update'
        ? File(args[1])
        : null,
  ),
);
