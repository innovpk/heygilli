import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../main.dart';
import '../gate/pin_gate.dart';
import 'add_kid_sheet.dart';
import 'inbox_screen.dart';
import 'kid_detail_screen.dart';
import 'policy_screen.dart';
import 'setup_review_screen.dart';
import 'preferences_screen.dart';
import 'parent_widgets.dart';
import 'takeout_import_screen.dart';

/// Parent phone home: Kids tab and Inbox tab (design/Phone*.dc.html tab bar).
class ParentHome extends StatefulWidget {
  const ParentHome({super.key});

  @override
  State<ParentHome> createState() => _ParentHomeState();
}

class _ParentHomeState extends State<ParentHome> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // The rail's badge and the kid cards both read this. Asked for once on the
    // way in rather than per card, and quietly: a household with nothing
    // waiting should not see a failed request about it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshWaiting();
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = context.select<AppState, String?>(
      (s) => s.settings.parentName,
    );
    return ParentScaffold(
      subtitle: name == null ? null : 'Hi $name',
      title: _tab == 0 ? 'Kids' : 'Inbox',
      // Two things that belong to the household rather than to one child, and
      // were previously nowhere: whose device this is, and a way out of the
      // account. Both at the top of the first screen, because a setting a
      // parent cannot find is a setting that does not exist.
      actions: const [_AccountMenu()],
      body: _tab == 0 ? const _KidsTab() : const InboxScreen(),
      floating: _tab == 0
          ? FloatingActionButton.extended(
              onPressed: () => addKidFlow(context),
              backgroundColor: HgColors.mango,
              foregroundColor: HgColors.white,
              icon: const Icon(Icons.add_rounded),
              label: Text('Add kid', style: HgText.body(color: HgColors.white)),
            )
          : null,
      bottom: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: HgColors.white,
        // Indicator and icon colours come from the theme, so this bar and the
        // segmented control on a child's page cannot drift apart.
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.face_outlined, color: HgColors.ink),
            label: 'Kids',
          ),
          NavigationDestination(
            icon: Icon(Icons.inbox_outlined, color: HgColors.ink),
            label: 'Inbox',
          ),
        ],
      ),
      sidebar: HouseholdSidebar(
        selectedKidId: null,
        inboxSelected: _tab == 1,
        onKids: () => setState(() => _tab = 0),
        onInbox: () => setState(() => _tab = 1),
        onKid: (kid) => openKid(context, kid),
        onAddKid: () => addKidFlow(context),
      ),
    );
  }
}

/// Add a kid, then set them up: what they may watch, then who from, then what.
///
/// The order is the whole point. The parent's answers are what every upload is
/// read against, so they have to come first — a household that picked channels
/// first had them screened against nothing it had said, and got a science
/// channel's motivational-quote compilations because nothing knew what it had
/// asked for. Channels next, because nothing outside an approved one can ever
/// reach the child. The videos those channels actually hold last, with Gilli's
/// reading of each, because approving a channel is not approving its uploads.
///
/// Every step can be left. A parent who stops after the first has a child with
/// rules and no channels, which is a coherent thing to be halfway through, and
/// each step is reachable again from the child's page.
Future<void> addKidFlow(BuildContext context) async {
  final kid = await showAddKidSheet(context);
  if (kid == null || !context.mounted) return;
  final navigator = Navigator.of(context);

  await navigator.push(
    MaterialPageRoute(builder: (_) => PolicyScreen(kid: kid, setup: true)),
  );
  if (!context.mounted) return;
  // What they like, not which channels to trust. Picking channels asked the
  // parent to vouch for a channel's entire future output from a one-line
  // blurb, before seeing anything it makes — and two of the twenty-six blurbs
  // were wrong about their own channel. The server picks where to look; the
  // parent judges what comes back.
  final looking = await navigator.push<bool>(
    MaterialPageRoute(builder: (_) => PreferencesScreen(kid: kid)),
  );
  if (!context.mounted) return;
  if (looking == true) {
    await navigator.push(
      MaterialPageRoute(builder: (_) => SetupReviewScreen(kid: kid)),
    );
    if (!context.mounted) return;
  }
  await navigator.push(
    MaterialPageRoute(builder: (_) => KidDetailScreen(kid: kid)),
  );
}

/// Opens one child's page.
///
/// `replace` when the move came from the rail: a parent flicking between two
/// children would otherwise leave a route behind for each one, and Back would
/// walk them through every child they had looked at instead of returning to
/// the list.
void openKid(BuildContext context, Kid kid, {bool replace = false}) {
  final route = MaterialPageRoute<void>(
    builder: (_) => KidDetailScreen(kid: kid),
  );
  final navigator = Navigator.of(context);
  if (replace && navigator.canPop()) {
    navigator.pushReplacement(route);
  } else {
    navigator.push(route);
  }
}

class _KidsTab extends StatelessWidget {
  const _KidsTab();

  @override
  Widget build(BuildContext context) {
    final kids = context.select<AppState, List<Kid>>((s) => s.kids);
    if (kids.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              const GilliMini(size: 96),
              Text(
                'No kids yet',
                style: HgText.display(size: 24, color: HgColors.ink),
              ),
              Text(
                'Add a kid to set their age band and languages. '
                'Gilli pitches every question to the band.',
                textAlign: TextAlign.center,
                style: HgText.body(color: HgColors.brown),
              ),
              const SizedBox(height: 8),
              // The step everyone takes, as the button everyone can see. It
              // was the floating button and nothing else, while the one
              // prominent thing on the screen was the Takeout import — the
              // rare path, and the one that asks the parent to go to Google
              // and wait for an email before the app does anything.
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => addKidFlow(context),
                  icon: const Icon(Icons.add_rounded, size: 22),
                  // Not "Add a kid": the rail carries that label permanently,
                  // and with no children on the household both were on screen
                  // at once saying the same thing. This one only ever appears
                  // when there is nobody yet, so it can say so.
                  label: Text(
                    'Add your first kid',
                    style: HgText.body(size: 16, color: HgColors.white),
                  ),
                ),
              ),
              // Still here, quieter: the fastest way in for a household that
              // already uses YouTube Kids, since the export names the profiles
              // and brings their channels.
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const TakeoutImportScreen(),
                  ),
                ),
                child: Text(
                  'Already use YouTube Kids? Import a profile',
                  style: HgText.body(size: 14, color: HgColors.brown),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        // A stack of full-width rows is the phone layout; once there is room
        // for two of them side by side, a single column of half-empty cards
        // reads as unfinished rather than as a choice.
        final columns = box.maxWidth >= 1080
            ? 3
            : box.maxWidth >= 720
            ? 2
            : 1;
        if (columns == 1) {
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
            itemCount: kids.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _KidCard(kid: kids[i]),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            // A ratio ties height to width, so the same card got shorter as
            // more columns fit — at three columns the name and meta line no
            // longer fit and the card overflowed. The card's own content
            // needs the same height regardless of how narrow the column is.
            //
            // 152 rather than 132 to leave room for the waiting line when
            // there is one, without the card jumping height when there is not.
            mainAxisExtent: 152,
          ),
          itemCount: kids.length,
          itemBuilder: (context, i) => _KidCard(kid: kids[i]),
        );
      },
    );
  }
}

/// One child on the household list.
///
/// It shows the name, the band, and whether anything is waiting on the parent.
/// It deliberately does NOT show what the child watched today.
///
/// That summary was built and taken out again. Getting it means a digest and a
/// channel list per child, so a household with three children asks the gateway
/// six questions to draw a list whose only job is to be tapped — and then asks
/// most of them again the moment one is. On the free tier that is a slow list
/// and a cold start apiece. The child's own page loads the same facts once, in
/// parallel, on the screen that actually uses them.
///
/// The waiting count stays, because it costs nothing: the rail has already
/// asked for it, and it is the one thing on this screen that might make a
/// parent tap a different child than the one they came for.
class _KidCard extends StatelessWidget {
  const _KidCard({required this.kid});
  final Kid kid;

  @override
  Widget build(BuildContext context) {
    final waiting = context.select<AppState, int>((s) => s.waiting);
    return PCard(
      padding: const EdgeInsets.all(16),
      onTap: () => openKid(context, kid),
      child: Row(
        spacing: 16,
        children: [
          KidAvatar(kid: kid, size: 56),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  kid.nickname,
                  style: HgText.display(size: 28, color: HgColors.ink),
                ),
                Text(
                  'Age ${kid.age}  |  band ${kid.band.label}  |  '
                  '${languageNames(kid.languages)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(size: 13, color: HgColors.brown),
                ),
                if (waiting > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '$waiting waiting for you',
                      // Rust and bold only when there is something to do. A
                      // count that is always coloured stops meaning "look at
                      // me" the second time anybody sees it.
                      style: HgText.body(
                        size: 13,
                        color: HgColors.mango,
                        weight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: HgColors.brown),
        ],
      ),
    );
  }
}

/// The household menu: whose device this is, and the way out of the account.
///
/// Both were missing. "Whose device is this?" started life at the bottom of a
/// child's page, under Time limits — a device question filed under a child,
/// three screens from where anyone would look for it. Signing out did not
/// exist at all: `GoogleAuth.signOut` was written and never called, so a
/// parent who signed in on the wrong account, or on someone else's phone, had
/// no way back.
class _AccountMenu extends StatelessWidget {
  const _AccountMenu();

  Future<void> _giveTo(BuildContext context, Kid? kid) async {
    final state = context.read<AppState>();
    // Both directions, because a child who can hand the device back to
    // themselves has no boundary at all.
    if (!await showPinGate(context)) return;
    await state.setDeviceKid(kid);
  }

  /// Choose a new parent PIN.
  ///
  /// Guarded by the old one. The PIN lives only on this device and is never
  /// sent anywhere, so there is nothing to recover it with: a parent who
  /// mistyped it at setup, or forgot it, previously could not leave kid mode
  /// on that device again. Asking for the old one first keeps a child who
  /// found the parent app from setting their own way out.
  Future<void> _changePin(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await showPinGate(context)) return;
    await state.clearPin();
    if (!context.mounted) return;
    // The gate sets a new one whenever none is stored, so this is the same
    // "Set a parent PIN" flow a household meets the first time, confirm step
    // and all.
    final set = await showPinGate(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          set
              ? 'New PIN saved.'
              : 'PIN cleared. The next one you type becomes the PIN.',
        ),
      ),
    );
  }

  /// Remove the household and everything in it.
  ///
  /// The end of "you can have your data back" — a parent asking to be
  /// forgotten should not have to email anyone. Behind the PIN and behind
  /// typing DELETE, because it takes every child at once and there is no
  /// undo anywhere.
  Future<void> _deleteHousehold(BuildContext context) async {
    final state = context.read<AppState>();
    if (!await showPinGate(context)) return;
    if (!context.mounted) return;

    final typed = TextEditingController();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final kids = state.kids.length;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: HgColors.white,
        title: Text(
          'Delete everything?',
          style: HgText.display(size: 22, color: HgColors.ink),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              kids == 1
                  ? 'Your child, their channels, everything they have watched '
                        'and every answer they gave. Nothing is kept behind, '
                        'and this cannot be undone.'
                  : 'All $kids children, their channels, everything they have '
                        'watched and every answer they gave. Nothing is kept '
                        'behind, and this cannot be undone.',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: typed,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Type DELETE'),
              style: HgText.body(size: 16, color: HgColors.ink),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: typed,
            builder: (context, value, _) => FilledButton(
              onPressed: value.text.trim() == 'DELETE'
                  ? () => Navigator.of(context).pop(true)
                  : null,
              style: FilledButton.styleFrom(backgroundColor: HgColors.coral),
              child: const Text('Delete everything'),
            ),
          ),
        ],
      ),
    );
    typed.dispose();
    if (yes != true || !context.mounted) return;

    // Removing a household is a row at a time over a gateway that may be
    // asleep, so it can take seconds. A barrier rather than a quiet wait: the
    // parent can see it is happening, and cannot start it twice or navigate
    // away into an account that is halfway gone.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: HgColors.white,
          content: Row(
            spacing: 16,
            children: [
              const CircularProgressIndicator(color: HgColors.mango),
              Expanded(
                child: Text(
                  'Deleting everything...',
                  style: HgText.body(size: 16, color: HgColors.brown),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      await state.deleteHousehold();
      navigator.pop(); // the progress barrier
      navigator.pushNamedAndRemoveUntil(Routes.parent, (_) => false);
    } catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final owner = state.deviceKid;
    return PopupMenuButton<VoidCallback>(
      icon: const Icon(Icons.more_vert_rounded, color: HgColors.ink),
      tooltip: 'This device',
      color: HgColors.white,
      onSelected: (run) => run(),
      // Not named `context`: shadowing the build context here means every
      // closure below captures the *popup route's* context, and that route
      // is gone by the time onSelected runs it. Reading a provider or
      // pushing a dialog from a defunct context fails quietly, which is
      // exactly how this looked — a menu item that did nothing.
      itemBuilder: (_) => [
        PopupMenuItem<VoidCallback>(
          enabled: false,
          child: Text(
            owner == null
                ? 'This is a parent device'
                : 'This device is ${owner.nickname}\'s',
            style: HgText.label(),
          ),
        ),
        if (owner != null)
          PopupMenuItem<VoidCallback>(
            value: () => _giveTo(context, null),
            child: Text(
              'Make it a parent device',
              style: HgText.body(size: 15, color: HgColors.ink),
            ),
          ),
        for (final kid in state.kids)
          if (kid.id != owner?.id)
            PopupMenuItem<VoidCallback>(
              value: () => _giveTo(context, kid),
              child: Text(
                'Give this device to ${kid.nickname}',
                style: HgText.body(size: 15, color: HgColors.ink),
              ),
            ),
        const PopupMenuDivider(),
        if (state.hasPin)
          PopupMenuItem<VoidCallback>(
            value: () => _changePin(context),
            child: Text(
              'Change parent PIN',
              style: HgText.body(size: 15, color: HgColors.ink),
            ),
          ),
        PopupMenuItem<VoidCallback>(
          value: () => _deleteHousehold(context),
          child: Text(
            'Delete everything',
            style: HgText.body(size: 15, color: HgColors.coral),
          ),
        ),
        PopupMenuItem<VoidCallback>(
          value: () => confirmSignOut(context),
          child: Text(
            'Sign out',
            style: HgText.body(size: 15, color: HgColors.coral),
          ),
        ),
      ],
    );
  }
}
