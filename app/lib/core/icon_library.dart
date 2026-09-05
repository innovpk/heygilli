import 'dart:convert';

import 'package:flutter/services.dart';

/// One entry of shared/icons.json (bundled as assets/icons.json).
class IconEntry {
  const IconEntry({
    required this.id,
    required this.concept,
    required this.en,
    required this.ur,
    required this.file,
  });

  final String id;
  final String concept;
  final String en;
  final String ur;
  final String file;

  String get assetPath => 'assets/icons/$file.svg';

  factory IconEntry.fromJson(Map<String, dynamic> j) => IconEntry(
    id: j['id'] as String,
    concept: j['concept'] as String? ?? '',
    en: j['en'] as String? ?? '',
    ur: j['ur'] as String? ?? '',
    file: j['file'] as String,
  );
}

/// The pick-it icon library. Bundled, so a pick-it question renders with zero
/// network and never depends on generated images (SPEC 7.2).
class IconLibrary {
  IconLibrary._(this._byId);

  final Map<String, IconEntry> _byId;

  static IconLibrary? _instance;

  static Future<IconLibrary> load() async {
    if (_instance != null) return _instance!;
    final raw = await rootBundle.loadString('assets/icons.json');
    final list = (jsonDecode(raw) as List)
        .map((e) => IconEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    return _instance = IconLibrary._({for (final e in list) e.id: e});
  }

  IconEntry? byId(String id) => _byId[id];

  /// Falls back to the "star" icon so an unknown id from a newer Planner
  /// still shows something tappable instead of a blank card.
  String assetFor(String iconId) =>
      (_byId[iconId] ?? _byId['icon_star'])?.assetPath ??
      'assets/icons/star.svg';

  Iterable<IconEntry> get all => _byId.values;
}
