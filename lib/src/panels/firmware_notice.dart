import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../theme/theme.dart';

class FirmwareNotice extends StatelessWidget {
  const FirmwareNotice({super.key, required this.controller});
  final TakeALookController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.symbolChanges,
    builder: (context, _) {
      final notice = controller.firmwareNotice;
      if (notice == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(notice, style: talMuted),
      );
    },
  );
}
