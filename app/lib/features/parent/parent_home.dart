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
              onPressed: () => showAddKidSheet(context),
              backgroundColor: HgColors.mango,
              foregroundColor: HgColors.ink,
              icon: const Icon(Icons.add_rounded),
              label: Text('Add kid', style: HgText.body(color: HgColors.ink)),
            )
          : null,
      bottom: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: HgColors.white,
        indicatorColor: HgColors.mango.withValues(alpha: 0.35),
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
      sidebar: ParentSidebar(
        selectedIndex: _tab,
        onSelect: (i) => setState(() => _tab = i),
        destinations: const [
          (icon: Icons.face_outlined, label: 'Kids'),
          (icon: Icons.inbox_outlined, label: 'Inbox'),
        ],
      ),
    );
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
              // The fastest way in for a household that already uses YouTube
              // Kids: the export names the profiles and brings their channels,
              // so the parent does not start from an empty list.
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const TakeoutImportScreen(),
                  ),
                ),
                icon: const Icon(Icons.folder_zip_outlined, size: 20),
                label: const Text('Already use YouTube Kids? Import a profile'),
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
            mainAxisExtent: 132,
          ),
          itemCount: kids.length,
          itemBuilder: (context, i) => _KidCard(kid: kids[i]),
        );
      },
    );
  }
}

class _KidCard extends StatelessWidget {
  const _KidCard({required this.kid});
  final Kid kid;

  @override
  Widget build(BuildContext context) {
    return PCard(
      padding: const EdgeInsets.all(16),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => KidDetailScreen(kid: kid))),
      child: Row(
        spacing: 16,
        children: [
          KidAvatar(kid: kid, size: 60),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(
                  kid.nickname,
                  style: HgText.display(size: 26, color: HgColors.ink),
                ),
                Text(
                  'Age ${kid.age}  |  band ${kid.band.label}  |  '
                  '${languageNames(kid.languages)}',
                  style: HgText.body(size: 14, color: HgColors.brown),
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

  Future<void> _signOut(BuildContext context) async {
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
        PopupMenuItem<VoidCallback>(
          value: () => _signOut(context),
          child: Text(
            'Sign out',
            style: HgText.body(size: 15, color: HgColors.coral),
          ),
        ),
      ],
    );
  }
}
