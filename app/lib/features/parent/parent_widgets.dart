import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/google_auth.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../main.dart';

/// Cream phone surface for every parent screen (design/Phone*.dc.html).
/// The kid side stays deep teal; the parent side is a normal light app.
///
/// Above [wideBreakpoint] this stops being a phone screen stretched into a
/// browser window and becomes an actual desktop layout: a wider column and,
/// when the caller supplies one, [sidebar] in place of [bottom] — a phone's
/// tab bar sits at the bottom because a thumb rests there; a desktop nav sits
/// on the left because a mouse does not.
class ParentScaffold extends StatelessWidget {
  const ParentScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.bottom,
    this.sidebar,
    this.floating,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;

  /// Phone-width navigation (e.g. a bottom [NavigationBar]). Ignored once
  /// [sidebar] is supplied and the viewport is wide — the two are
  /// alternatives, not a stack.
  final Widget? bottom;

  /// Desktop-width navigation, shown at [wideBreakpoint] and above instead of
  /// [bottom]. A screen pushed on top of the tab root (kid detail, digest,
  /// policy, ...) passes neither and gets the same wide column with no rail.
  final Widget? sidebar;
  final Widget? floating;
  final Widget? leading;

  static const wideBreakpoint = HgLayout.wideBreakpoint;

  @override
  Widget build(BuildContext context) {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
    final canPop = Navigator.of(context).canPop();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: ColoredBox(
        color: HgColors.cream,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Two separate questions that had been one. `wide` is "does this
            // screen show a navigation rail", which needs a sidebar to show.
            // `roomy` is "is there width to use", which does not — and folding
            // them together capped every screen pushed on top of the tab root
            // at 560px however large the window was, which is the phone
            // layout the doc comment above says it is not.
            final roomy = constraints.maxWidth >= wideBreakpoint;
            final wide = roomy && sidebar != null;
            final trailing = <Widget>[
              if (isDemo) const DemoBadge(),
              ...actions,
            ];
            final back = leading != null
                ? leading!
                : canPop
                ? IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: HgColors.ink,
                    tooltip: 'Back',
                  )
                : null;
            // On a phone, a long title and a text action do not share a line.
            // "What Abu may watch" beside "Skip for now" left the title about
            // ninety points wide and set it one word per line down four rows,
            // which is not a heading.
            //
            // Measured rather than guessed from the window width, because the
            // answer depends on the title: "Kids" fits beside anything, and
            // stacking the controls under it wastes a line for nothing. The
            // reserve is an estimate of the trailing row — icon buttons are 48
            // and the demo chip about 70 — and it only has to be close, since
            // being wrong costs a line break either way and never a clipped
            // control.
            double widthOf(String text, TextStyle style) => (TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: TextDirection.ltr,
            )..layout()).width;
            // The subtitle is measured too, and it is often the wider of the
            // two: "Abu" fits beside anything, and "Age 5 | band 4 to 6"
            // underneath it did not, so the child's own page set their age
            // down three lines while the name sat comfortably above it.
            final needs = [
              widthOf(title, HgText.display(size: 32)),
              if (subtitle != null) widthOf(subtitle!, HgText.label()),
            ].reduce((a, b) => a > b ? a : b);
            final reserved =
                (back == null ? 0 : 48) +
                (isDemo ? 70 : 0) +
                actions.length * 48 +
                24;
            final tight =
                trailing.isNotEmpty &&
                needs > constraints.maxWidth - reserved - 40;
            final titleBlock = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle != null) Text(subtitle!, style: HgText.label()),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.display(size: 32, color: HgColors.ink),
                ),
              ],
            );
            final header = Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: tight
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          spacing: 12,
                          children: [
                            ?back,
                            Expanded(child: titleBlock),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Wrap, not Row: on a 320pt phone the controls that
                        // were moved down here for room still did not fit
                        // one line on the policy screen.
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: trailing,
                        ),
                      ],
                    )
                  : Row(
                      spacing: 12,
                      children: [
                        ?back,
                        Expanded(child: titleBlock),
                        ...trailing,
                      ],
                    ),
            );
            final page = Scaffold(
              backgroundColor: HgColors.cream,
              floatingActionButton: floating,
              bottomNavigationBar: wide ? null : bottom,
              body: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    Expanded(child: body),
                  ],
                ),
              ),
            );
            // This is a phone layout that is now also opened in a browser
            // window. Unconstrained, one kid's row stretches across 1400 px
            // of cream and the page reads as broken rather than as an app.
            // The constraint wraps the whole Scaffold rather than its body,
            // so the bottom bar and the add button stay with the content
            // instead of hugging the window's edges; the cream behind it is
            // the same ground, so no seam shows.
            // With a rail, the rail owns the left edge of the window: full
            // height, corner to corner, the way every desktop app with a
            // navigation column is built. It used to sit inside a rounded
            // card floating in the middle of the cream, which made the
            // navigation look like part of the page rather than the frame
            // around it, and wasted a band of empty ground down both sides.
            //
            // The content keeps a maximum width of its own and centres in
            // whatever space is left, so a wide monitor gives margins rather
            // than a line of text a foot long.
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  sidebar!,
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1180),
                        child: page,
                      ),
                    ),
                  ),
                ],
              );
            }
            return Center(
              child: ConstrainedBox(
                // 560 is a readable single column and stays the answer on a
                // phone. A pushed screen on a desktop gets 1120: wide enough
                // for two columns of cards side by side, narrow enough that a
                // paragraph in one of them is still a paragraph.
                constraints: BoxConstraints(maxWidth: roomy ? 1120 : 560),
                child: page,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The household rail: who is in it, and what is waiting.
///
/// The parent side used to be a page per child reached through a list, with
/// two tabs at the bottom. Which child you were looking at was a thing you had
/// to remember, and moving between them meant going back to the list first.
/// The rail makes both standing facts: every child is on screen at once, the
/// one being read is highlighted, and switching is one tap from anywhere.
///
/// It is passed to [ParentScaffold] by every parent screen rather than owned by
/// one of them, so the frame does not disappear the moment a parent opens a
/// child. Shown only at [HgLayout.wideBreakpoint] and up — a rail on a phone is
/// a page of navigation.
class HouseholdSidebar extends StatelessWidget {
  const HouseholdSidebar({
    super.key,
    required this.selectedKidId,
    required this.onKid,
    required this.onInbox,
    required this.onKids,
    required this.onAddKid,
    this.inboxSelected = false,
  });

  /// The child whose page is open, or null on the kids list and the inbox.
  final String? selectedKidId;
  final ValueChanged<Kid> onKid;
  final VoidCallback onInbox;
  final VoidCallback onKids;
  final VoidCallback onAddKid;
  final bool inboxSelected;

  @override
  Widget build(BuildContext context) {
    final kids = context.select<AppState, List<Kid>>((s) => s.kids);
    final waiting = context.select<AppState, int>((s) => s.waiting);
    final parent = context.select<AppState, String?>(
      (s) => s.settings.parentName,
    );
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);

    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: HgColors.white,
        border: Border(right: BorderSide(color: HgColors.line, width: 2)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 16),
      // Every row in here is an InkWell, and an InkWell needs a Material to
      // splash onto. The rail is drawn by a Container rather than a Card, so it
      // has to supply one itself — without it the rail throws on first build
      // and takes the page's layout down with it.
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: onKids,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  spacing: 10,
                  children: [
                    SvgPicture.asset('assets/gilli.svg', width: 36, height: 36),
                    Flexible(
                      child: Text(
                        'HeyGilli',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HgText.display(size: 24, color: HgColors.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (isDemo)
              const Padding(
                padding: EdgeInsets.only(left: 4, top: 8),
                child: DemoBadge(),
              ),
            const SizedBox(height: 22),
            const _RailEyebrow('Kids'),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final kid in kids)
                    _KidRow(
                      kid: kid,
                      selected: kid.id == selectedKidId,
                      onTap: () => onKid(kid),
                    ),
                  _AddKidRow(onTap: onAddKid),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const _RailEyebrow('Household'),
            _RailRow(
              icon: Icons.inbox_outlined,
              label: 'Inbox',
              selected: inboxSelected,
              onTap: onInbox,
              // Hidden at zero: a badge reading "0" invites a parent to go and
              // check something that is not there.
              trailing: waiting == 0 ? null : _CountPill(waiting),
            ),
            const Divider(color: HgColors.line, height: 24),
            if (parent != null)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text(
                  parent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(size: 14, color: HgColors.ink),
                ),
              ),
            const _SignOutLink(),
          ],
        ),
      ),
    );
  }
}

class _RailEyebrow extends StatelessWidget {
  const _RailEyebrow(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    child: Text(text.toUpperCase(), style: HgText.label(color: HgColors.mango)),
  );
}

class _KidRow extends StatelessWidget {
  const _KidRow({
    required this.kid,
    required this.selected,
    required this.onTap,
  });

  final Kid kid;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: selected ? HgColors.cream : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            spacing: 10,
            children: [
              KidAvatar(kid: kid, size: 34),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kid.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HgText.body(
                        size: 15,
                        color: HgColors.ink,
                        weight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Age ${kid.age} \u00b7 band ${kid.band.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HgText.body(size: 12, color: HgColors.brown),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AddKidRow extends StatelessWidget {
  const _AddKidRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          spacing: 10,
          children: [
            // Dashed, and the same 34 as a child's avatar, so it reads as the
            // empty place in the row of children rather than as a button that
            // happens to be nearby.
            const DottedCircle(size: 34),
            Text(
              'Add a kid',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RailRow extends StatelessWidget {
  const _RailRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? HgColors.cream : Colors.transparent,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        child: Row(
          spacing: 12,
          children: [
            Icon(icon, color: HgColors.ink, size: 22),
            Expanded(
              child: Text(
                label,
                style: HgText.body(
                  size: 15,
                  color: HgColors.ink,
                  weight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    ),
  );
}

class _CountPill extends StatelessWidget {
  const _CountPill(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: const BoxDecoration(
      color: HgColors.mango,
      borderRadius: BorderRadius.all(Radius.circular(999)),
    ),
    child: Text(
      '$count',
      style: HgText.body(
        size: 12,
        color: HgColors.white,
        weight: FontWeight.w800,
      ),
    ),
  );
}

/// A dashed ring. Flutter has no dashed border, so it is painted: short arcs
/// with the same length skipped between them.
class DottedCircle extends StatelessWidget {
  const DottedCircle({super.key, this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: const _DottedCirclePainter(),
    child: SizedBox(
      width: size,
      height: size,
      child: const Icon(Icons.add_rounded, size: 18, color: HgColors.brown),
    ),
  );
}

class _DottedCirclePainter extends CustomPainter {
  const _DottedCirclePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = HgColors.muted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.width / 2 - 1,
    );
    const dash = 0.34; // radians drawn, then the same again skipped
    for (var a = 0.0; a < 6.28; a += dash * 2) {
      canvas.drawArc(rect, a, dash, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// "Sign out", set as a link under the parent's name at the foot of the rail.
class _SignOutLink extends StatelessWidget {
  const _SignOutLink();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      onPressed: () => confirmSignOut(context),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        'Sign out',
        style: HgText.body(
          size: 13,
          color: HgColors.brown,
        ).copyWith(decoration: TextDecoration.underline),
      ),
    ),
  );
}

/// Confirms, signs out, and returns to the parent root.
///
/// Shared by the rail and the phone's account menu, because it is the same
/// decision and a parent should not learn two different things about what
/// signing out costs depending on the width of their window. Nothing is
/// deleted, and saying so is the reason this asks rather than just doing it.
Future<void> confirmSignOut(BuildContext context) async {
  final state = context.read<AppState>();
  final navigator = Navigator.of(context);
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: HgColors.white,
      title: Text('Sign out?', style: HgText.display(size: 22)),
      content: Text(
        'Your children, their channels and everything they have watched stay '
        'on your household. Signing in again brings it all back.',
        style: HgText.body(size: 15, color: HgColors.brown),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Stay'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  if (yes != true) return;
  await state.signOut();
  navigator.pushNamedAndRemoveUntil(Routes.parent, (_) => false);
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

  /// One colour per child, so two siblings are told apart at a glance in the
  /// rail and on a card. Rust and pine-green only: a third hue would be a
  /// colour the rest of the app does not have.
  static const _palette = [HgColors.mango, HgColors.green];

  /// Stable for the life of the child, because it is derived from the id
  /// rather than from their position in a list — a child added above them
  /// must not repaint everybody below.
  static Color colourFor(Kid kid) {
    if (kid.id.isEmpty) return _palette.first;
    final sum = kid.id.codeUnits.fold(0, (a, b) => a + b);
    return _palette[sum % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final initial = kid.nickname.isEmpty ? '?' : kid.nickname[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: colourFor(kid), shape: BoxShape.circle),
      alignment: Alignment.center,
      // A face the child picked, or their initial when they have not picked
      // one. The name is checked by the server against a fixed list before it
      // is stored, so it is safe to build an asset path from.
      child: kid.hasDrawableAvatar
          ? SvgPicture.asset(
              'assets/icons/${kid.avatar}.svg',
              width: size * 0.66,
              height: size * 0.66,
            )
          // White, not ink: both avatar colours are dark fills.
          : Text(
              initial,
              style: HgText.display(size: size * 0.5, color: HgColors.white),
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

/// Word chips shared by the digest and the Progress screen so vocabulary looks
/// the same wherever a parent meets it. Filled mango = the child said it;
/// outlined = Gilli modelled it and the child has not said it back yet.
class WordChips extends StatelessWidget {
  const WordChips({
    super.key,
    required this.words,
    required this.filled,
    required this.empty,
  });

  final List<String> words;
  final bool filled;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) {
      return Text(empty, style: HgText.body(color: HgColors.muted));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final w in words)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: filled ? HgColors.mango : null,
              border: filled
                  ? null
                  : Border.all(color: const Color(0xFFC9B7A0), width: 2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              w,
              style: HgText.body(
                size: 17,
                weight: FontWeight.w800,
                color: filled ? HgColors.ink : const Color(0xFF6B5A48),
              ),
            ),
          ),
      ],
    );
  }
}

/// White pill for "Continue with Google", used on sign-in and again in the
/// import screen's empty state so the same action always looks the same.
///
/// [reason] is shown under a disabled button: a build with no Google client id
/// says so plainly instead of offering a button that cannot work.
class GoogleButton extends StatelessWidget {
  const GoogleButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.reason,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        SizedBox(
          height: 56,
          child: FilledButton(
            onPressed: busy ? null : onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: HgColors.white,
              foregroundColor: HgColors.ink,
              disabledBackgroundColor: HgColors.line,
              disabledForegroundColor: HgColors.muted,
              shape: const StadiumBorder(),
              side: const BorderSide(color: HgColors.line, width: 2),
            ),
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: HgColors.brown,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 12,
                    children: [
                      const _GoogleG(),
                      // Flexible, not bare: on a narrow phone the label plus
                      // the G is wider than the button, and an unconstrained
                      // Text in a Row paints the overflow stripes across the
                      // first thing a parent ever sees.
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HgText.body(
                            size: 17,
                            color: onPressed == null
                                ? HgColors.muted
                                : HgColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        if (reason != null)
          Text(
            reason!,
            textAlign: TextAlign.center,
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
      ],
    );
  }
}

class _GoogleG extends StatelessWidget {
  const _GoogleG();

  @override
  Widget build(BuildContext context) {
    return Text(
      'G',
      style: HgText.display(size: 24, color: const Color(0xFF4285F4)),
    );
  }
}

/// Runs Google sign-in and hands the server auth code to the gateway.
///
/// Returns a message to show the parent, or null when there is nothing to say:
/// either it worked, or they backed out of Google's own screen.
///
/// Call this straight from a button handler. google_sign_in requires scope
/// authorization to be initiated by a user interaction.
Future<String?> runGoogleSignIn(BuildContext context) async {
  final state = context.read<AppState>();

  // Demo mode has no OAuth client and must never be blocked by one, so the
  // fake gateway stands in for the whole exchange.
  if (state.isDemo) {
    await state.signInWithGoogle('demo_server_auth_code');
    return null;
  }

  return handleGoogleResult(state, await GoogleAuth.shared.signIn());
}

/// Turns a finished [GoogleAuthResult] into a session, or into the one line
/// the screen should show. Shared by the two shapes the flow comes in: a
/// phone's awaited call, and the web's stream of sign-ins the SDK pushes.
///
/// Returns null when there is nothing to say — including a cancellation, which
/// is a decision, not an error.
Future<String?> handleGoogleResult(
  AppState state,
  GoogleAuthResult result,
) async {
  switch (result) {
    case GoogleAuthSuccess(
      :final serverAuthCode,
      :final displayName,
      :final redirectUri,
    ):
      try {
        await state.signInWithGoogle(
          serverAuthCode,
          displayName: displayName,
          redirectUri: redirectUri,
        );
        return null;
      } catch (e) {
        return 'Signed in with Google, but HeyGilli could not be reached: $e';
      }
    case GoogleAuthCancelled():
      return null;
    case GoogleAuthNotConfigured(:final reason):
      return reason;
    case GoogleAuthScopeDenied():
      // The only thing sign-in asks for now is who they are, so this means
      // Google gave back no usable identity rather than a feature being
      // withheld. Nothing is lost by not signing in at all: the second door
      // does everything.
      return 'Google did not confirm who you are, so nothing was signed in. '
          'You can set up without Google instead — nothing needs it.';
    case GoogleAuthUnavailable(:final message):
      return message;
    case GoogleAuthFailed(:final message):
      return message;
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
