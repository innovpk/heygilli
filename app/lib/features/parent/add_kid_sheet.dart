import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

/// Bottom sheet: nickname, age (sets the band live), languages.
Future<void> showAddKidSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: HgColors.cream,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => const _AddKidSheet(),
  );
}

class _AddKidSheet extends StatefulWidget {
  const _AddKidSheet();

  @override
  State<_AddKidSheet> createState() => _AddKidSheetState();
}

class _AddKidSheetState extends State<_AddKidSheet> {
  final _nickname = TextEditingController();
  int _age = 5;
  bool _en = true;
  bool _ur = false;
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
      await context.read<AppState>().addKid(
        nickname: name,
        age: _age,
        languages: [if (_en) 'en', if (_ur) 'ur'],
      );
      if (mounted) Navigator.of(context).pop();
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
            'Add a kid',
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
              child: const Text('Save kid'),
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
