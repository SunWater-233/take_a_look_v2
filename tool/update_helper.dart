import 'dart:io';

import 'package:take_a_look_v2/src/updates/update_installer.dart';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--self-test') {
    stdout.writeln('Take A Look updater schema 1');
    return;
  }
  if (args.length != 2 || !['--job', '--apply'].contains(args.first)) {
    stderr.writeln('Usage: take_a_look_updater --job /absolute/path/job.json');
    exitCode = 2;
    return;
  }
  await runUpdateHelper(File(args[1]), elevated: args.first == '--apply');
}
