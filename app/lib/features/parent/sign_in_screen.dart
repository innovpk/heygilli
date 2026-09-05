import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/theme.dart';

/// Hackathon sign-in: a name is enough for `POST /auth/dev`. Google sign-in
/// replaces this screen later without touching anything behind it.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final _name = TextEditingController(
    text: context.read<AppState>().settings.parentName ?? '',
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Type your name to continue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().signIn(name);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Sign-in failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: HgColors.cream,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 18,
                  children: [
                    Center(
                      child: Container(
                        width: 160,
                        height: 160,
                        decoration: const BoxDecoration(
                          color: HgColors.white,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.bottomCenter,
                        child: SvgPicture.asset(
                          'assets/gilli.svg',
                          width: 140,
                          height: 140,
                        ),
                      ),
                    ),
                    Column(
                      spacing: 6,
                      children: [
                        Text(
                          'HeyGilli',
                          style: HgText.display(size: 40, color: HgColors.ink),
                        ),
                        Text(
                          'A buddy who watches YouTube with your kid',
                          textAlign: TextAlign.center,
                          style: HgText.body(size: 16, color: HgColors.brown),
                        ),
                        if (isDemo) const DemoBadge(),
                      ],
                    ),
                    Text('YOUR NAME', style: HgText.label()),
                    TextField(
                      controller: _name,
                      autofocus: false,
                      textCapitalization: TextCapitalization.words,
                      style: HgText.body(size: 18, color: HgColors.ink),
                      decoration: const InputDecoration(
                        hintText: 'e.g. Mujahid',
                      ),
                      onSubmitted: (_) => _continue(),
                    ),
                    if (_error != null)
                      Text(_error!, style: HgText.body(color: HgColors.coral)),
                    SizedBox(
                      height: 56,
                      child: FilledButton(
                        onPressed: _busy ? null : _continue,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              )
                            : const Text('Continue'),
                      ),
                    ),
                    Text(
                      'Dev sign-in for the hackathon. Google sign-in comes next.',
                      textAlign: TextAlign.center,
                      style: HgText.body(
                        size: 13,
                        color: HgColors.muted,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
