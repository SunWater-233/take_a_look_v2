/// Capabilities advertised by the hardware process, shared by all windows.
class ConnectionCapabilities {
  const ConnectionCapabilities({
    required this.memorySampling,
    required this.memoryWrite,
    required this.rtt,
    required this.firmwareDownload,
    required this.targetControl,
  });

  final bool memorySampling;
  final bool memoryWrite;
  final bool rtt;
  final bool firmwareDownload;
  final bool targetControl;

  /// Offline/demo sessions and older backends have no advertised capabilities.
  factory ConnectionCapabilities.forConfiguration(
    String kind,
    Map<String, String> config,
  ) {
    final memoryOnly = kind == 'gdb' && config['gdbMode'] == 'memory';
    return ConnectionCapabilities(
      memorySampling: kind == 'local' || kind == 'ember' || memoryOnly,
      memoryWrite: kind != 'ember' && !memoryOnly,
      rtt: kind != 'gdb',
      firmwareDownload: const {'local', 'ember', 'emberGdb'}.contains(kind),
      targetControl: !memoryOnly,
    );
  }

  factory ConnectionCapabilities.fromJson(
    Map values, {
    required ConnectionCapabilities fallback,
  }) => ConnectionCapabilities(
    memorySampling:
        values['memorySampling'] as bool? ?? fallback.memorySampling,
    memoryWrite: values['memoryWrite'] as bool? ?? fallback.memoryWrite,
    rtt: values['rtt'] as bool? ?? fallback.rtt,
    firmwareDownload:
        values['firmwareDownload'] as bool? ?? fallback.firmwareDownload,
    targetControl: values['targetControl'] as bool? ?? fallback.targetControl,
  );

  Map<String, bool> toJson() => {
    'memorySampling': memorySampling,
    'memoryWrite': memoryWrite,
    'rtt': rtt,
    'firmwareDownload': firmwareDownload,
    'targetControl': targetControl,
  };
}
