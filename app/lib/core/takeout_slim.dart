import 'dart:io';

import 'package:archive/archive.dart';

/// What came out of slimming an export.
class SlimTakeout {
  const SlimTakeout({
    required this.file,
    required this.kept,
    required this.skipped,
    this.history = 0,
  });

  /// A small zip holding only the subscription lists. This is what is uploaded.
  final File file;

  /// Subscription CSVs copied across.
  final int kept;

  /// Everything left behind, which is mostly watch and search history.
  final int skipped;

  /// Watch-history files copied across, which is zero unless the parent ticked
  /// the box for this one import. Counted separately from [kept] so the screen
  /// can say exactly what went, rather than one number covering both.
  final int history;
}

/// Thrown when the picked file is not a Takeout export we can use.
class NotATakeoutExport implements Exception {
  const NotATakeoutExport(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Strips a Google Takeout export down to just the subscription lists, on the
/// phone, before anything is uploaded.
///
/// A YouTube export also contains each child's `watch-history.html` and
/// `search-history.html`. Those are the most sensitive files in it and nothing
/// in HeyGilli needs them, so they are never sent anywhere: only members whose
/// path ends in `subscriptions.csv` are copied into a new, small zip, and that
/// zip is what leaves the device. It is also the difference between uploading
/// a few kilobytes and a few hundred megabytes over a phone connection.
///
/// [source] is the file the parent picked; [workDir] is where the slim copy is
/// written (a temp directory the caller owns and should clean up).
///
/// [includeHistory] is the one exception, and it is off unless a parent ticked
/// the box for this one import (PROTOCOL "Watch history: opt-in, aggregate,
/// discarded"). It adds `watch-history.html` and nothing else: search history
/// has no exception anywhere in the product and never leaves the phone.
Future<SlimTakeout> slimTakeout(
  File source, {
  required Directory workDir,
  bool includeHistory = false,
}) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(InputFileStream(source.path));
  } catch (_) {
    throw const NotATakeoutExport(
      'That file could not be opened as a zip. Pick the .zip Google emailed '
      'you, not an unzipped folder.',
    );
  }

  final slim = Archive();
  var skipped = 0;
  var subscriptions = 0;
  var history = 0;
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    if (isSubscriptionCsv(entry.name)) {
      subscriptions++;
    } else if (includeHistory && isWatchHistory(entry.name)) {
      history++;
    } else {
      skipped++;
      continue;
    }
    slim.addFile(ArchiveFile.bytes(entry.name, entry.content));
  }

  // A zip of history with no subscription lists is not an import: the channel
  // lists are what the product is for, and history alone would be nothing but
  // the sensitive half.
  if (subscriptions == 0) {
    throw const NotATakeoutExport(
      'No subscription lists in that export. Re-run Takeout and tick the '
      '"children" and "subscriptions" categories under YouTube.',
    );
  }

  final out = File(
    '${workDir.path}/heygilli-subscriptions-${DateTime.now().millisecondsSinceEpoch}.zip',
  );
  await out.writeAsBytes(ZipEncoder().encode(slim), flush: true);
  return SlimTakeout(
    file: out,
    kept: subscriptions,
    skipped: skipped,
    history: history,
  );
}

/// True for a Takeout member we are willing to read.
///
/// Deliberately narrow: the name must end in `subscriptions.csv`. Anything
/// with a parent-directory hop is refused outright rather than normalised, so
/// a hostile zip cannot walk out of its own tree.
bool isSubscriptionCsv(String name) {
  if (name.contains('..')) return false;
  return name.toLowerCase().endsWith('subscriptions.csv');
}

/// True for a child's watch history, which goes only when the parent asked for
/// it on this one import.
///
/// As narrow as [isSubscriptionCsv], and narrower in one way that matters:
/// `search-history.html` is not matched by anything here or anywhere else. A
/// child's searches are their own and no part of HeyGilli reads them.
bool isWatchHistory(String name) {
  if (name.contains('..')) return false;
  return name.toLowerCase().endsWith('watch-history.html');
}
