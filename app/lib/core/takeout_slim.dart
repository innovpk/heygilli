import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The export a parent picked, named in a way that works on every platform.
///
/// On a phone this is a [path] and the zip is streamed off disk, because a
/// real Takeout export is routinely hundreds of megabytes and reading one into
/// memory would kill the app. In a browser there is no path to stream from, so
/// the picker hands over [bytes] instead. Exactly one of the two is set.
class TakeoutZip {
  /// A file on disk. Streamed, never loaded whole.
  const TakeoutZip.path(this.name, String this.path) : bytes = null;

  /// A file the browser already has in memory.
  const TakeoutZip.bytes(this.name, Uint8List this.bytes) : path = null;

  /// What the parent saw the file called, shown back to them on screen.
  final String name;
  final String? path;
  final Uint8List? bytes;

  /// How the decoder reads it, without either side knowing which it got.
  InputStream open() =>
      path != null ? InputFileStream(path!) : InputMemoryStream(bytes!);
}

/// What came out of slimming an export.
class SlimTakeout {
  const SlimTakeout({
    required this.bytes,
    required this.kept,
    required this.skipped,
    this.history = 0,
  });

  /// A small zip holding only the subscription lists. This is what is
  /// uploaded, and it is held in memory rather than written anywhere: it is a
  /// few kilobytes, and a temp file would be one more copy of a family's data
  /// left lying on the device.
  final Uint8List bytes;

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
/// device, before anything is uploaded.
///
/// A YouTube export also contains each child's `watch-history.html` and
/// `search-history.html`. Those are the most sensitive files in it and nothing
/// in HeyGilli needs them, so they are never sent anywhere: only members whose
/// path ends in `subscriptions.csv` are copied into a new, small zip, and that
/// zip is what leaves the device. It is also the difference between uploading
/// a few kilobytes and a few hundred megabytes over a phone connection.
///
/// [includeHistory] is the one exception, and it is off unless a parent ticked
/// the box for this one import (PROTOCOL "Watch history: opt-in, aggregate,
/// discarded"). It adds `watch-history.html` and nothing else: search history
/// has no exception anywhere in the product and never leaves the device.
Future<SlimTakeout> slimTakeout(
  TakeoutZip source, {
  bool includeHistory = false,
}) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(source.open());
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

  return SlimTakeout(
    bytes: Uint8List.fromList(ZipEncoder().encode(slim)),
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
