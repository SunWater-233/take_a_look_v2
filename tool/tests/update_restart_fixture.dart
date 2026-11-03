import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--doctor') return;
  if (args.length != 2) {
    throw ArgumentError('Expected --wait FILE or --record FILE');
  }
  if (args.first == '--wait') {
    while (!await File(args[1]).exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  } else if (args.first == '--record') {
    await File(args[1]).writeAsString('restarted', flush: true);
  } else {
    throw ArgumentError('Unknown fixture command');
  }
}
