import '../protocol/commands.dart';

class TargetChip {
  const TargetChip({
    required this.id,
    required this.name,
    required this.partNumber,
    this.vendor = '',
    this.families = const [],
    this.cores = const [],
    this.memories = const [],
    this.packId = '',
    this.packLabel = '内置',
    this.available = true,
  });

  factory TargetChip.fromJson(Map data) => TargetChip(
    id: data['id'] as String,
    name: data['name'] as String,
    partNumber: data['partNumber'] as String,
    vendor: data['vendor'] as String? ?? '',
    families: (data['families'] as List? ?? const []).cast<String>(),
    cores: (data['cores'] as List? ?? const []).cast<String>(),
    memories: (data['memories'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(),
    packId: data['packId'] as String? ?? '',
    packLabel: data['packLabel'] as String? ?? '内置',
    available: data['available'] != false,
  );

  final String id;
  final String name;
  final String partNumber;
  final String vendor;
  final List<String> families;
  final List<String> cores;
  final List<Map<String, dynamic>> memories;
  final String packId;
  final String packLabel;
  final bool available;

  bool get isBuiltin => packId.isEmpty;
  String get searchText =>
      '$partNumber $name $vendor ${families.join(' ')}'.toLowerCase();
  JsonObject get selection => {'name': name, 'packId': packId};
}

class TargetPack {
  TargetPack.fromJson(Map data)
    : id = data['id'] as String,
      name = data['name'] as String,
      vendor = data['vendor'] as String,
      version = data['version'] as String,
      targetCount = data['targetCount'] as int,
      size = data['size'] as int? ?? 0,
      importedAt = data['importedAt'] as String? ?? '',
      bundled = data['bundled'] == true,
      available = data['available'] != false;

  final String id;
  final String name;
  final String vendor;
  final String version;
  final int targetCount;
  final int size;
  final String importedAt;
  final bool bundled;
  final bool available;
  String get label => '$vendor.$name';
}

class TargetCatalogData {
  TargetCatalogData.fromJson(Map data)
    : targets = (data['targets'] as List? ?? const [])
          .map((item) => TargetChip.fromJson(item as Map))
          .toList(),
      packs = (data['packs'] as List? ?? const [])
          .map((item) => TargetPack.fromJson(item as Map))
          .toList(),
      recent = (data['recent'] as List? ?? const []).cast<String>(),
      warning = data['warning'] as String? ?? '';

  final List<TargetChip> targets;
  final List<TargetPack> packs;
  final List<String> recent;
  final String warning;

  List<TargetChip> search({
    String query = '',
    String source = 'all',
    String vendor = '',
    String family = '',
    String packId = '',
  }) {
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
    final found = targets.where((chip) {
      if (source == 'builtin' && !chip.isBuiltin) return false;
      if (source == 'pack' && chip.isBuiltin) return false;
      if (source == 'recent' && !recent.contains(chip.id)) return false;
      if (vendor.isNotEmpty && chip.vendor != vendor) return false;
      if (family.isNotEmpty && !chip.families.contains(family)) return false;
      if (packId.isNotEmpty && chip.packId != packId) return false;
      return terms.every(chip.searchText.contains);
    }).toList();
    int rank(TargetChip chip) {
      final name = chip.partNumber.toLowerCase();
      final term = query.toLowerCase().trim();
      if (term.isEmpty) return chip.name == 'auto' ? -1 : 2;
      if (name == term || chip.name == term) return 0;
      return name.startsWith(term) ? 1 : 2;
    }

    found.sort((a, b) {
      if (source == 'recent') {
        return recent.indexOf(a.id).compareTo(recent.indexOf(b.id));
      }
      final comparison = rank(a).compareTo(rank(b));
      if (comparison != 0) return comparison;
      final name = a.partNumber.toLowerCase().compareTo(
        b.partNumber.toLowerCase(),
      );
      return name != 0 ? name : a.packLabel.compareTo(b.packLabel);
    });
    return found;
  }
}
