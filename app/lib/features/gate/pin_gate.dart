import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';

/// Shows the 4-digit parent PIN gate. Resolves true when the parent got
/// through (or set a PIN for the first time), false when dismissed.
///
/// A PIN, not biometrics, because the phone that set it up is often not the
/// tablet the kid is holding.
Future<bool> showPinGate(BuildContext context) async {
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const PinGateScreen(),
    ),
  );
  return ok ?? false;
}

class PinGateScreen extends StatefulWidget {
  const PinGateScreen({super.key});

  @override
  State<PinGateScreen> createState() => _PinGateScreenState();
}

class _PinGateScreenState extends State<PinGateScreen> {
  String _entry = '';
  String? _firstEntry; // first pass when setting a new PIN
  String? _hint;
  bool _shake = false;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final settingUp = !state.hasPin;
    final title = settingUp
        ? (_firstEntry == null ? 'Set a parent PIN' : 'Type it once more')
        : 'Parent PIN';
    final hint =
        _hint ??
        (settingUp
            ? 'Kids need this to leave kid mode.'
            : 'Four digits to leave kid mode.');

    return Scaffold(
      backgroundColor: HgColors.tealDeep,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            // This gate opens from kid mode, which is landscape, so it is
            // usually short and wide: put the keypad beside the prompt rather
            // than under it, and size the keys to the height we actually have.
            final side = box.maxWidth > box.maxHeight && box.maxHeight < 560;
            final keyH = ((box.maxHeight - 140) / 4.6).clamp(46.0, 72.0);

            final prompt = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: HgText.display(size: side ? 26 : 30),
                ),
                const SizedBox(height: 8),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: HgText.body(
                    color: _hint == null ? HgColors.sky : HgColors.coral,
                  ),
                ),
                const SizedBox(height: 24),
                _Dots(count: _entry.length, shake: _shake),
              ],
            );
            final keypad = _Keypad(
              onDigit: _digit,
              onBackspace: _backspace,
              keyHeight: keyH,
            );

            return Stack(
              children: [
                Center(
                  // Scrolls rather than overflowing on any small screen.
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 56, 24, 16),
                    child: side
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            spacing: 40,
                            children: [
                              Flexible(child: prompt),
                              keypad,
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 28,
                            children: [prompt, keypad],
                          ),
                  ),
                ),
                Positioned(
                  top: 4,
                  left: 4,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close_rounded, size: 30),
                    color: HgColors.cream,
                    tooltip: 'Back to kid mode',
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _digit(String d) {
    if (_entry.length >= 4) return;
    setState(() {
      _entry += d;
      _hint = null;
    });
    if (_entry.length == 4) _submit();
  }

  void _backspace() {
    if (_entry.isEmpty) return;
    setState(() => _entry = _entry.substring(0, _entry.length - 1));
  }

  Future<void> _submit() async {
    final state = context.read<AppState>();
    if (!state.hasPin) {
      if (_firstEntry == null) {
        setState(() {
          _firstEntry = _entry;
          _entry = '';
        });
        return;
      }
      if (_firstEntry != _entry) {
        _reject('Those did not match. Start again.');
        _firstEntry = null;
        return;
      }
      await state.setPin(_entry);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    if (state.checkPin(_entry)) {
      Navigator.of(context).pop(true);
    } else {
      _reject('Not quite. Try again.');
    }
  }

  Future<void> _reject(String hint) async {
    setState(() {
      _shake = true;
      _hint = hint;
    });
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (mounted) {
      setState(() {
        _shake = false;
        _entry = '';
      });
    }
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.shake});
  final int count;
  final bool shake;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: shake ? const Offset(0.03, 0) : Offset.zero,
      duration: const Duration(milliseconds: 120),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 18,
        children: List.generate(
          4,
          (i) => Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < count ? HgColors.mango : Colors.transparent,
              border: Border.all(color: HgColors.mango, width: 3),
            ),
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.onDigit,
    required this.onBackspace,
    required this.keyHeight,
  });
  final void Function(String) onDigit;
  final VoidCallback onBackspace;

  /// Sized by the caller from the space available, so the keypad shrinks on a
  /// short landscape screen instead of overflowing it.
  final double keyHeight;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', '<'],
    ];
    final gap = (keyHeight * 0.2).clamp(8.0, 14.0);
    final keyW = keyHeight * 1.12;
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: [
        for (final row in rows)
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: gap,
            children: [
              for (final k in row)
                SizedBox(
                  width: keyW,
                  height: keyHeight,
                  child: k.isEmpty
                      ? null
                      : Material(
                          color: k == '<' ? Colors.transparent : HgColors.teal,
                          borderRadius: BorderRadius.circular(20),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: k == '<' ? onBackspace : () => onDigit(k),
                            child: Center(
                              child: k == '<'
                                  ? Icon(
                                      Icons.backspace_outlined,
                                      color: HgColors.cream,
                                      size: keyHeight * 0.4,
                                    )
                                  : Text(
                                      k,
                                      style: HgText.display(
                                        size: keyHeight * 0.42,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}
