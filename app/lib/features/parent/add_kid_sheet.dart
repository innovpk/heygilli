import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';

/// Bottom sheet: nickname, age (sets the band live), languages.
///
/// Returns the kid that was created, or null if the sheet was dismissed. The
/// Takeout import needs the kid back, because a Takeout profile carries no age
/// and the channels have to land on the kid this sheet just made.
Future<Kid?> showAddKidSheet(
  BuildContext context, {
  String initialNickname = '',
}) {
  return showHgModal<Kid>(
    context,
    builder: (_) => _AddKidSheet(initialNickname: initialNickname),
  );
}

/// The same sheet, correcting a child who already exists.
///
/// There was no way to do this: an age typed wrong stayed wrong, and there is
/// no delete either, so the child could not even be made again. Age is not
/// cosmetic — it sets the band, which decides what the Curator screens for and
/// whether the child is read to or shown text.
Future<Kid?> showEditKidSheet(BuildContext context, Kid kid) {
  return showHgModal<Kid>(context, builder: (_) => _AddKidSheet(editing: kid));
}

class _AddKidSheet extends StatefulWidget {
  const _AddKidSheet({this.initialNickname = '', this.editing});

  /// Prefilled from the Takeout profile name, which is the only thing the
  /// export knows about the child.
  final String initialNickname;

  /// The child being corrected, or null when this is a new one.
  final Kid? editing;

  @override
  State<_AddKidSheet> createState() => _AddKidSheetState();
}

class _AddKidSheetState extends State<_AddKidSheet> {
  late final _nickname = TextEditingController(
    text: widget.editing?.nickname ?? widget.initialNickname,
  );
  late int _age = widget.editing?.age ?? 5;
  late bool _en = widget.editing?.languages.contains('en') ?? true;
  late bool _ur = widget.editing?.languages.contains('ur') ?? false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nickname.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the kid a nickname.');
      return;
    }
    if (!_en && !_ur) {
      setState(() => _error = 'Pick at least one language.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = widget.editing;
      final languages = [if (_en) 'en', if (_ur) 'ur'];
      final state = context.read<AppState>();
      final kid = existing == null
          ? await state.addKid(
              nickname: name,
              age: _age,
              languages: languages,
            )
          : await state.editKid(
              existing.id,
              nickname: name,
              age: _age,
              languages: languages,
            );
      if (mounted) Navigator.of(context).pop(kid);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not save: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final band = AgeBand.forAge(_age);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 14,
        children: [
          Text(
            widget.editing == null ? 'Add a kid' : 'Edit ${widget.editing!.nickname}',
            style: HgText.display(size: 28, color: HgColors.ink),
          ),
          Text('NICKNAME (NO REAL NAMES NEEDED)', style: HgText.label()),
          TextField(
            controller: _nickname,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            style: HgText.body(size: 18, color: HgColors.ink),
            decoration: const InputDecoration(
              hintText: 'What you call them at home',
            ),
          ),
          Text('AGE', style: HgText.label()),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: Slider(
                  value: _age.toDouble(),
                  min: 4,
                  max: 11,
                  divisions: 7,
                  activeColor: HgColors.mango,
                  inactiveColor: HgColors.line,
                  label: '$_age',
                  onChanged: (v) => setState(() => _age = v.round()),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '$_age',
                  textAlign: TextAlign.center,
                  style: HgText.display(size: 28, color: HgColors.ink),
                ),
              ),
            ],
          ),
          // The band is the thing that matters downstream, so show it live.
          Text(
            'Band ${band.label}: ${_bandBlurb(band)}',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          Text('LANGUAGES', style: HgText.label()),
          Row(
            spacing: 10,
            children: [
              FilterChip(
                label: const Text('English'),
                selected: _en,
                onSelected: (v) => setState(() => _en = v),
                selectedColor: HgColors.mango,
                checkmarkColor: HgColors.ink,
              ),
              FilterChip(
                label: const Text('Urdu'),
                selected: _ur,
                onSelected: (v) => setState(() => _ur = v),
                selectedColor: HgColors.mango,
                checkmarkColor: HgColors.ink,
              ),
            ],
          ),
          if (_error != null)
            Text(_error!, style: HgText.body(color: HgColors.coral)),
          SizedBox(
            height: 56,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(widget.editing == null ? 'Save kid' : 'Save changes'),
            ),
          ),
        ],
      ),
    );
  }

  static String _bandBlurb(AgeBand b) => switch (b) {
    AgeBand.b4to6 => 'pictures and voice only, no text on screen.',
    AgeBand.b7to8 => 'voice plus large question text.',
    AgeBand.b9to11 => 'voice plus question text, talked to like an older kid.',
  };
}
