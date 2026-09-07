import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme.dart';

/// What HeyGilli is, before a parent is asked to sign in to it.
///
/// Shown once. The sign-in screen carries a one-line tagline, which answers
/// "what is this called" but not "why would I hand this my child's YouTube" —
/// and that is the question being asked at the moment a stranger opens the app.
///
/// Three panels, because the product is three claims: a buddy watches along,
/// the parent decides what is allowed, and the watching turns into talking.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key, required this.onDone});

  /// Called when the parent has read it, or skipped. The caller persists that
  /// so this never appears twice.
  final VoidCallback onDone;

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  final _pages = const [
    _Panel(
      art: 'assets/gilli.svg',
      title: 'A buddy who watches along',
      body: 'Gilli sits beside your child while they watch, on the videos '
          'you already allow. Not another place to watch — the same YouTube, '
          'with someone paying attention.',
    ),
    _Panel(
      art: 'assets/icons/star.svg',
      title: 'You decide what is allowed',
      body: 'You pick the channels. Every new upload is screened before it '
          'can appear, and nothing reaches your child that you have not '
          'approved. Your child never signs in to anything.',
    ),
    _Panel(
      art: 'assets/icons/happy.svg',
      title: 'Watching becomes talking',
      body: 'Gilli asks a question or two about what just happened, in your '
          "child's language and at their level, and tells you afterwards what "
          'they got and what they found hard.',
    ),
  ];

  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _page == _pages.length - 1;

  void _next() => _isLast
      ? widget.onDone()
      : _controller.nextPage(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: HgColors.cream,
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= HgLayout.wideBreakpoint;
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 1120 : 460),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: widget.onDone,
                      child: Text(
                        'Skip',
                        style: HgText.body(size: 15, color: HgColors.brown),
                      ),
                    ),
                  ),
                  // On a phone there is room for one claim at a time, paged
                  // by hand. A window this wide can just say all three at
                  // once — there is no reason to make someone click through
                  // a carousel a scan of the eye would cover in one look.
                  if (wide)
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (final p in _pages) Expanded(child: p),
                        ],
                      ),
                    )
                  else ...[
                    Expanded(
                      child: PageView(
                        controller: _controller,
                        onPageChanged: (i) => setState(() => _page = i),
                        children: _pages,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _pages.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: i == _page ? 22 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == _page
                                  ? HgColors.mango
                                  : HgColors.line,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
                    child: SizedBox(
                      height: 52,
                      width: wide ? 280 : double.infinity,
                      child: FilledButton(
                        // Every panel is already visible when wide, so
                        // there is nothing left to page to — the button
                        // only ever means "done."
                        onPressed: wide ? widget.onDone : _next,
                        child: Text(
                          wide || _isLast ? 'Get started' : 'Next',
                          style: HgText.body(size: 17, color: HgColors.ink),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.art, required this.title, required this.body});

  final String art;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 168,
          height: 168,
          decoration: const BoxDecoration(
            color: HgColors.white,
            shape: BoxShape.circle,
          ),
          padding: const EdgeInsets.all(26),
          child: SvgPicture.asset(art),
        ),
        const SizedBox(height: 28),
        Text(
          title,
          textAlign: TextAlign.center,
          style: HgText.display(size: 26, color: HgColors.ink),
        ),
        const SizedBox(height: 12),
        Text(
          body,
          textAlign: TextAlign.center,
          style: HgText.body(size: 16, color: HgColors.brown),
        ),
      ],
    ),
  );
}
