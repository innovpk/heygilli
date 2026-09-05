import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
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
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
      itemCount: kids.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _KidCard(kid: kids[i]),
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
