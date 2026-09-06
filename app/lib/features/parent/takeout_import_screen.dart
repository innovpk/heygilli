import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/takeout_slim.dart';
import '../../core/theme.dart';
import 'add_kid_sheet.dart';
import 'parent_widgets.dart';

/// Import the children's real YouTube Kids subscriptions from a Google Takeout
/// export.
///
/// PROTOCOL "Takeout import": this is the only route to a child's YouTube Kids
/// subscriptions - no API exposes them, and Family Link exposes none either.
/// The gateway reads the subscription CSVs and nothing else.
///
/// Takeout carries no age, so a profile that has no kid yet is mapped by
/// creating one through the ordinary add-kid sheet.
///
/// Pops `true` when anything was imported, so the caller can refresh.
class TakeoutImportScreen extends StatefulWidget {
  const TakeoutImportScreen({super.key});

  @override
  State<TakeoutImportScreen> createState() => _TakeoutImportScreenState();
}

class _TakeoutImportScreenState extends State<TakeoutImportScreen> {
  TakeoutPreview? _preview;
  String _pickedName = '';
  bool _reading = false;
  String? _error;
  bool _importedAnything = false;
  SlimTakeout? _slimmed;

  /// Whether this import also carries the children's watch history.
  ///
  /// **Off, and it starts off every single time** (PROTOCOL "Watch history:
  /// opt-in, aggregate, discarded"). It is per-import on purpose: nothing
  /// remembers the tick, so a parent who agreed once has not agreed to every
  /// import they will ever do.
  bool _includeHistory = false;

  Future<void> _pick() async {
    setState(() => _error = null);
    PlatformFile? picked;
    try {
      // FileType.any rather than a zip filter: Android's picker hides files
      // whose MIME type the provider reports oddly, and a hidden file looks
      // like a broken app. The extension is checked here instead.
      picked = await FilePicker.pickFile(dialogTitle: 'Pick the Takeout zip');
    } catch (e) {
      setState(() => _error = 'Could not open the file picker: $e');
      return;
    }
    if (picked == null) return; // Backed out of the picker: not an error.
    final file = picked;
    if (!file.name.toLowerCase().endsWith('.zip')) {
      setState(
        () => _error =
            '${file.name} is not a zip. Pick the takeout-....zip that '
            'Google emailed you, not an unpacked folder.',
      );
      return;
    }
    // A phone gives a path and the zip is streamed off disk; a browser has no
    // path and the bytes have to be read in. Either way the slimming below
    // happens here, on the parent's own machine, before anything is uploaded.
    final path = kIsWeb ? null : file.path;
    final TakeoutZip zip;
    try {
      zip = path != null
          ? TakeoutZip.path(file.name, path)
          : TakeoutZip.bytes(file.name, await file.readAsBytes());
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error =
            'That file could not be opened from here. Copy it into the '
            'Downloads folder and try again.',
      );
      return;
    }
    await _read(zip, file.name);
  }

  /// Reads an export and shows what is in it. [zip] is null only for the demo
  /// sample, which has no real file behind it.
  Future<void> _read(TakeoutZip? zip, String name) async {
    setState(() {
      _reading = true;
      _error = null;
      _preview = null;
      _pickedName = name;
      _slimmed = null;
    });
    // Captured before the first await: the gateway is needed after slimming,
    // and reaching through context at that point is a use across an async gap.
    final gateway = context.read<AppState>().gateway;
    try {
      // Strip the export to just the subscription lists BEFORE anything is
      // uploaded, so the children's watch and search history never leave the
      // device. Also turns a hundreds-of-MB upload into a few KB.
      var toUpload = Uint8List(0);
      if (zip != null) {
        final slim = await slimTakeout(zip, includeHistory: _includeHistory);
        toUpload = slim.bytes;
        if (mounted) setState(() => _slimmed = slim);
      }
      final preview = await gateway.importTakeout(
        toUpload,
        name,
        includeHistory: _includeHistory,
      );
      if (!mounted) return;
      setState(() {
        _reading = false;
        _preview = preview;
        if (preview.isEmpty) {
          _error =
              'No subscription lists in that export. When you create it, '
              'tick "children" and "subscriptions" under YouTube and '
              'YouTube Music.';
        }
      });
    } on NotATakeoutExport catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = 'Could not read that export: $e';
      });
    }
  }

  /// Demo mode has no gateway to unzip anything, so there is no file to slim.
  /// Labelled as a sample on the button so it cannot be mistaken for a real
  /// import.
  Future<void> _useSample() => _read(null, 'sample-takeout.zip (demo)');

  void _reset() => setState(() {
    _preview = null;
    _error = null;
    _pickedName = '';
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_importedAnything);
      },
      child: ParentScaffold(
        subtitle: 'Import subscriptions',
        title: 'Google Takeout',
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            if (preview == null) ..._intro() else ..._profiles(preview),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: HgText.body(size: 14, color: HgColors.coral),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- intro

  List<Widget> _intro() {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
    return [
      PCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              'What your children actually follow',
              style: HgText.display(size: 22, color: HgColors.ink),
            ),
            Text(
              'YouTube has no way to read a YouTube Kids profile, so the '
              'export is the only route to it. Go to takeout.google.com, '
              'pick YouTube and YouTube Music, and inside it tick '
              '"children" and "subscriptions". Google emails you a zip, '
              'usually within an hour. Choose that zip here.',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      // The privacy line is on the screen, not in a policy: the export holds
      // the most sensitive files a family has.
      PCard(
        color: const Color(0xFFF2F7EE),
        child: Row(
          spacing: 12,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lock_outline_rounded, color: HgColors.green),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Text(
                    'Only the subscription lists are read',
                    style: HgText.body(size: 16, color: HgColors.ink),
                  ),
                  Text(
                    'The export also contains watch history and search '
                    'history. Those stay on this phone: only the subscription '
                    'lists are pulled out and sent, never opened, never '
                    'stored, never sent to a model. Only the channel lists '
                    'come out of the zip.',
                    style: HgText.body(size: 14, color: HgColors.brown),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _HistoryOptIn(
        value: _includeHistory,
        onChanged: _reading ? null : (v) => setState(() => _includeHistory = v),
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 56,
        child: FilledButton.icon(
          onPressed: _reading ? null : _pick,
          icon: const Icon(Icons.folder_open_rounded),
          label: Text(
            _reading ? 'Reading the export' : 'Choose the Takeout zip',
            style: HgText.body(size: 17, color: HgColors.ink),
          ),
        ),
      ),
      if (_reading) ...[
        const SizedBox(height: 16),
        const Center(child: CircularProgressIndicator(color: HgColors.mango)),
        const SizedBox(height: 8),
        Text(
          _pickedName,
          textAlign: TextAlign.center,
          style: HgText.body(size: 13, color: HgColors.muted),
        ),
      ],
      if (isDemo) ...[
        const SizedBox(height: 8),
        SizedBox(
          height: 48,
          child: TextButton(
            onPressed: _reading ? null : _useSample,
            style: TextButton.styleFrom(foregroundColor: HgColors.brown),
            child: Text(
              'Use a sample export (demo)',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
          ),
        ),
      ],
    ];
  }

  /// What actually left the phone, in the past tense, counted rather than
  /// promised. A parent who ticked the box is told the history went, in the
  /// same breath as everything that did not.
  String _sentLine(SlimTakeout? slimmed) {
    if (slimmed == null) {
      return _includeHistory
          ? 'The subscription lists and the watch history were read. Search '
                'history stayed on your phone.'
          : 'Only the subscription lists were read. Watch and search history '
                'stayed on your phone.';
    }
    final lists =
        'Sent ${slimmed.kept} subscription '
        '${slimmed.kept == 1 ? 'list' : 'lists'}';
    final history = slimmed.history == 0
        ? ''
        : ' and ${slimmed.history} watch '
              '${slimmed.history == 1 ? 'history' : 'histories'}, which is '
              'counted and then deleted';
    final rest = slimmed.history == 0
        ? 'including watch and search history'
        : 'including search history';
    return '$lists$history. The other ${slimmed.skipped} files, $rest, '
        'stayed on your phone.';
  }

  // ----------------------------------------------------------------- preview

  List<Widget> _profiles(TakeoutPreview preview) {
    final parent = preview.parent;
    final slimmed = _slimmed;
    return [
      Text(_pickedName, style: HgText.label()),
      const SizedBox(height: 8),
      Text(
        preview.profiles.isEmpty
            ? 'No child profiles in this export.'
            : '${preview.profiles.length} '
                  '${preview.profiles.length == 1 ? 'child profile' : 'child profiles'} '
                  'in this export. Pick who each one belongs to, then import.',
        style: HgText.body(size: 15, color: HgColors.brown),
      ),
      const SizedBox(height: 6),
      // Repeated here, in the past tense, so the parent sees what was read at
      // the moment they act rather than only on the screen before.
      Row(
        spacing: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.lock_outline_rounded,
            size: 16,
            color: HgColors.green,
          ),
          Expanded(
            child: Text(
              _sentLine(slimmed),
              style: HgText.body(size: 13, color: HgColors.brown),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      for (final profile in preview.profiles) ...[
        _ProfileCard(
          profile: profile,
          onImported: () => _importedAnything = true,
        ),
        const SizedBox(height: 12),
      ],
      if (parent != null) ...[
        PCard(
          color: const Color(0xFFF6EFE2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              Text(
                'Your own subscriptions: ${parent.channelCount}',
                style: HgText.body(size: 16, color: HgColors.ink),
              ),
              Text(
                'These are the account holder\'s, not a child\'s, so they '
                'are left alone here. Import from YouTube on a kid\'s page '
                'if you want to pick through them.',
                style: HgText.body(size: 14, color: HgColors.brown),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
      SizedBox(
        height: 48,
        child: TextButton(
          onPressed: _reset,
          style: TextButton.styleFrom(foregroundColor: HgColors.brown),
          child: Text(
            'Choose a different export',
            style: HgText.body(size: 15, color: HgColors.brown),
          ),
        ),
      ),
    ];
  }
}

/// The one exception to "only the subscription lists are read", and the only
/// place in HeyGilli where a parent can widen what leaves the phone.
///
/// PROTOCOL "Watch history: opt-in, aggregate, discarded". Three things the
/// copy here must keep doing, because they are the terms of the exception:
/// it says which file goes, it says what survives the count (channel names and
/// numbers, no video titles, ever), and it says what still does not go at all
/// (search history). It is off, and it starts off on every import.
class _HistoryOptIn extends StatelessWidget {
  const _HistoryOptIn({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return PCard(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Checkbox(
            value: value,
            onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
            activeColor: HgColors.mango,
            checkColor: HgColors.ink,
            side: const BorderSide(color: HgColors.brown, width: 2),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(
                  'Also count what they actually watched',
                  style: HgText.body(size: 16, color: HgColors.ink),
                ),
                Text(
                  'Off unless you tick it, for this import only. Ticked, one '
                  'more file goes with the channel lists: watch-history.html. '
                  'HeyGilli counts it — how many videos, which channels, what '
                  'times of day — then deletes the file and every video title '
                  'in it. No video title is stored or sent to a model; only '
                  'channel names are. Search history is never sent either way.',
                  style: HgText.body(size: 14, color: HgColors.brown),
                ),
                Text(
                  // Said before they tick, not after: an undo they only find
                  // out about afterwards is not much of a reassurance.
                  'What it works out is a page of counts on the kid, and one '
                  'tap deletes it.',
                  style: HgText.body(size: 13, color: HgColors.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One child profile from the export: its name, how many channels it has, and
/// which kid those channels should land on.
class _ProfileCard extends StatefulWidget {
  const _ProfileCard({required this.profile, required this.onImported});

  final TakeoutProfile profile;
  final VoidCallback onImported;

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  String? _kidId;
  bool _busy = false;
  String? _error;
  String? _done;

  @override
  Widget build(BuildContext context) {
    final kids = context.select<AppState, List<Kid>>((s) => s.kids);
    // A profile whose name matches an existing kid almost certainly belongs
    // to that kid; preselect it, and let the parent change it.
    final match = kids
        .where(
          (k) => k.nickname.toLowerCase() == widget.profile.name.toLowerCase(),
        )
        .firstOrNull;
    final selectedId = _kidId ?? match?.id;
    final target = kids.where((k) => k.id == selectedId).firstOrNull;
    final count = widget.profile.channelCount;

    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Row(
            spacing: 12,
            children: [
              const Icon(Icons.child_care_rounded, color: HgColors.brown),
              Expanded(
                child: Text(
                  widget.profile.name.isEmpty
                      ? 'Unnamed profile'
                      : widget.profile.name,
                  style: HgText.display(size: 24, color: HgColors.ink),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: HgColors.mango.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count ${count == 1 ? 'channel' : 'channels'}',
                  style: HgText.body(size: 14, color: HgColors.brown),
                ),
              ),
            ],
          ),
          if (_done != null)
            Text(_done!, style: HgText.body(size: 15, color: HgColors.green))
          else ...[
            Text('IMPORT INTO', style: HgText.label()),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kid in kids)
                  _Choice(
                    label: kid.nickname,
                    selected: kid.id == selectedId,
                    onTap: () => setState(() => _kidId = kid.id),
                  ),
                _Choice(
                  label: 'New kid',
                  icon: Icons.add_rounded,
                  selected: false,
                  onTap: _busy ? null : _createKidThenImport,
                ),
              ],
            ),
            if (_error != null)
              Text(
                _error!,
                style: HgText.body(size: 14, color: HgColors.coral),
              ),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: target == null || _busy
                    ? null
                    : () => _import(target),
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: HgColors.line,
                  disabledForegroundColor: HgColors.muted,
                ),
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    : Text(
                        target == null
                            ? 'Pick a kid first'
                            : 'Import $count into ${target.nickname}',
                        style: HgText.body(
                          size: 16,
                          color: target == null ? HgColors.muted : HgColors.ink,
                        ),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Takeout has no age and no language, so a new kid still goes through the
  /// ordinary add-kid sheet. The profile name is only a suggested nickname.
  Future<void> _createKidThenImport() async {
    final kid = await showAddKidSheet(
      context,
      initialNickname: widget.profile.name,
    );
    if (kid == null || !mounted) return;
    setState(() => _kidId = kid.id);
    await _import(kid);
  }

  Future<void> _import(Kid kid) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await context.read<AppState>().gateway.importChannels(
        kid.id,
        widget.profile.channelIds,
        // This is the parent saying which child the profile belongs to, and
        // the only point at which a watch-history aggregate can be attached
        // to one. Takeout itself carries no identity.
        profile: widget.profile.name,
      );
      if (!mounted) return;
      final added = result.added.length;
      final already = result.already.length;
      setState(() {
        _busy = false;
        _done =
            '$added added to ${kid.nickname}'
            '${already == 0 ? '.' : ', $already ${already == 1 ? 'was' : 'were'} already there.'}';
      });
      widget.onImported();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not import: $e';
      });
    }
  }
}

/// Pill used for the "import into" choice. 48 dp tall so it is a real target.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? HgColors.mango : HgColors.cream,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          // No alignment: a Container with one would expand to the Wrap's
          // full width and every choice would read as a button of its own.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              if (icon != null) Icon(icon, size: 20, color: HgColors.brown),
              Text(
                label,
                style: HgText.body(
                  size: 16,
                  color: selected ? HgColors.ink : HgColors.brown,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
