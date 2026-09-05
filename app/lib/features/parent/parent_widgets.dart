import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

/// Cream phone surface for every parent screen (design/Phone*.dc.html).
/// The kid side stays deep teal; the parent side is a normal light app.
class ParentScaffold extends StatelessWidget {
  const ParentScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.bottom,
    this.floating,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final Widget? bottom;
  final Widget? floating;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
    final canPop = Navigator.of(context).canPop();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: HgColors.cream,
        floatingActionButton: floating,
        bottomNavigationBar: bottom,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  spacing: 12,
                  children: [
                    if (leading != null)
                      leading!
                    else if (canPop)
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                        color: HgColors.ink,
                        tooltip: 'Back',
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (subtitle != null)
                            Text(subtitle!, style: HgText.label()),
                          Text(
                            title,
                            style: HgText.display(
                              size: 32,
                              color: HgColors.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isDemo) const DemoBadge(),
                    ...actions,
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// White rounded card, matching `.card` in the mockups.
class PCard extends StatelessWidget {
  const PCard({
    super.key,
    required this.child,
    this.color = HgColors.white,
    this.padding = const EdgeInsets.all(20),
    this.onTap,
  });

  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(22),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Round avatar with the kid's initial. Mango is the single accent so every
/// kid avatar reads as "tap me" the same way.
class KidAvatar extends StatelessWidget {
  const KidAvatar({super.key, required this.kid, this.size = 56});

  final Kid kid;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = kid.nickname.isEmpty ? '?' : kid.nickname[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: HgColors.mango,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: HgText.display(size: size * 0.5, color: HgColors.teal),
      ),
    );
  }
}

/// Small Gilli in a white circle, used as the parent-side mascot.
class GilliMini extends StatelessWidget {
  const GilliMini({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: HgColors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.bottomCenter,
      child: SvgPicture.asset(
        'assets/gilli.svg',
        width: size * 0.86,
        height: size * 0.86,
      ),
    );
  }
}

/// "English, Urdu" from ["en", "ur"].
String languageNames(List<String> codes) => codes
    .map(
      (c) => switch (c) {
        'ur' => 'Urdu',
        'en' => 'English',
        _ => c,
      },
    )
    .join(', ');

/// Brief inline error used by the parent screens' FutureBuilders.
class LoadError extends StatelessWidget {
  const LoadError(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Text(
            'Could not load: $error',
            textAlign: TextAlign.center,
            style: HgText.body(color: HgColors.brown),
          ),
          if (onRetry != null)
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
