import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';

/// The faces a child may wear.
///
/// Kept here rather than fetched, so a child in kid mode never waits on the
/// network to change their own picture. The server checks the same names
/// before storing one — this list is what a child is *offered*, not what is
/// trusted.
const kidAvatars = <String>[
  'cat', 'dog', 'duck', 'frog', 'lion', 'monkey',
  'elephant', 'giraffe', 'bird', 'butterfly', 'fish', 'cow',
  'squirrel', 'rocket', 'star', 'sun', 'moon', 'flower',
  'boat', 'train', 'tree', 'mango',
];

/// Let the child choose their own picture.
///
/// Theirs to change, not the parent's to assign: it is the one thing in the
/// app that belongs to the child, and a four-year-old picking a frog is the
/// whole of it. Nothing here is written, because a pre-reader sees no text —
/// the pictures are the choice.
///
/// Returns the chosen icon id, or null if they backed out.
Future<String?> showAvatarPicker(BuildContext context, Kid kid) =>
    showHgModal<String>(
      context,
      maxWidth: 640,
      background: HgColors.tealDeep,
      builder: (_) => _AvatarPicker(kid: kid),
    );

class _AvatarPicker extends StatefulWidget {
  const _AvatarPicker({required this.kid});

  final Kid kid;

  @override
  State<_AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<_AvatarPicker> {
  bool _saving = false;

  Future<void> _choose(String avatar) async {
    if (_saving) return;
    setState(() => _saving = true);
    final state = context.read<AppState>();
    final navigator = Navigator.of(context);
    try {
      await state.editKid(widget.kid.id, avatar: avatar);
      navigator.pop(avatar);
    } catch (_) {
      // A child cannot act on an error message and should not be shown one.
      // The sheet stays open on the picture they had; they can tap again.
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 5,
          decoration: BoxDecoration(
            color: HgColors.white.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(height: 18),
        // Sized so a whole row is reachable on a tablet held in landscape,
        // which is how a child holds it, and so every target is far bigger
        // than a small finger needs.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 340, maxWidth: 720),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 6,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final name in kidAvatars)
                _Face(
                  name: name,
                  chosen: name == widget.kid.avatar,
                  onTap: () => _choose(name),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Face extends StatelessWidget {
  const _Face({
    required this.name,
    required this.chosen,
    required this.onTap,
  });

  final String name;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    // The only label anywhere in this sheet, and it is never drawn: a
    // pre-reader sees pictures, a screen reader needs a name.
    label: name,
    button: true,
    selected: chosen,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        decoration: BoxDecoration(
          color: HgColors.white,
          shape: BoxShape.circle,
          border: chosen
              ? Border.all(color: HgColors.mango, width: 4)
              : null,
        ),
        padding: const EdgeInsets.all(10),
        child: SvgPicture.asset('assets/icons/$name.svg'),
      ),
    ),
  );
}
