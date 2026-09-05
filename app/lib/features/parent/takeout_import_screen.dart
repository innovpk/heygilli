import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
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
    final path = file.path;
    if (path == null) {
      setState(
        () => _error =
            'That file could not be opened from here. Copy it into the '
            'phone\'s Downloads folder and try again.',
      );
      return;
    }
    if (!file.name.toLowerCase().endsWith('.zip')) {
      setState(
        () => _error =
            '${file.name} is not a zip. Pick the takeout-....zip that '
            'Google emailed you, not an unpacked folder.',
      );
      return;
    }
    await _read(File(path), file.name);
  }

  Future<void> _read(File zip, String name) async {
    setState(() {
      _reading = true;
      _error = null;
      _preview = null;
      _pickedName = name;
    });
    // Captured before the first await: the gateway is needed after slimming,
    // and reaching through context at that point is a use across an async gap.
    final gateway = context.read<AppState>().gateway;
    try {
      // Strip the export to just the subscription lists BEFORE anything is
      // uploaded, so the children's watch and search history never leave the
      // phone. Also turns a hundreds-of-MB upload into a few KB.
      var toUpload = zip;
      if (await zip.exists()) {
        final slim = await slimTakeout(
          zip,
          workDir: await getTemporaryDirectory(),
        );
        toUpload = slim.file;
        if (mounted) setState(() => _slimmed = slim);
      }
      final preview = await gateway.importTakeout(toUpload);
      // The slim copy has served its purpose; do not leave it in the cache.
      if (toUpload.path != zip.path) {
        unawaited(toUpload.delete().catchError((_) => toUpload));
      }
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

  /// Demo mode has no gateway to unzip anything, so it stands in for the file
  /// itself. Labelled as a sample on the button so it cannot be mistaken for
  /// a real import.
  Future<void> _useSample() =>
      _read(File('sample-takeout.zip'), 'sample-takeout.zip (demo)');

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
              slimmed == null
                  ? 'Only the subscription lists were read. Watch and search '
                        'history stayed on your phone.'
                  : 'Sent ${slimmed.kept} subscription '
                        '${slimmed.kept == 1 ? 'list' : 'lists'}. The other '
                        '${slimmed.skipped} files, including watch and search '
                        'history, stayed on your phone.',
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
    // A profile called "Zara" almost certainly belongs to the kid called
    // "Zara"; preselect that, and let the parent change it.
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
