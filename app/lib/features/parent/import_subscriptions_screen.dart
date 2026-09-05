import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/google_auth.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// Tick through the channels the parent already follows and approve some of
/// them for one kid.
///
/// PROTOCOL is explicit that a parent's subscriptions are the *parent's*: a
/// starting list, never an auto-approved catalogue. So nothing is pre-ticked,
/// and importing approves channels only. The Curator still screens every
/// upload before it reaches the kid.
///
/// Pops `true` when anything was added, so the kid screen can refresh.
class ImportSubscriptionsScreen extends StatefulWidget {
  const ImportSubscriptionsScreen({super.key, required this.kid});

  final Kid kid;

  @override
  State<ImportSubscriptionsScreen> createState() =>
      _ImportSubscriptionsScreenState();
}

class _ImportSubscriptionsScreenState extends State<ImportSubscriptionsScreen> {
  final _selected = <String>{};
  SubscriptionList? _data;
  Object? _loadError;
  bool _importing = false;
  bool _googleBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loaded into fields rather than a FutureBuilder because the bottom action
  /// bar sits outside the list and has to disappear when there is no list.
  Future<void> _load() async {
    final gateway = context.read<AppState>().gateway;
    setState(() {
      _data = null;
      _loadError = null;
      _selected.clear();
    });
    try {
      final subs = await gateway.youtubeSubscriptions();
      if (mounted) setState(() => _data = subs);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  /// Channels already approved for this kid can never be selected, so a double
  /// import is not possible from here.
  List<Subscription> _selectable(List<Subscription> all) =>
      all.where((s) => !s.isApprovedFor(widget.kid.id)).toList();

  void _toggle(Subscription s, bool on) => setState(() {
    if (on) {
      _selected.add(s.channelId);
    } else {
      _selected.remove(s.channelId);
    }
  });

  void _selectAll(List<Subscription> selectable, bool on) => setState(() {
    _selected.clear();
    if (on) _selected.addAll(selectable.map((s) => s.channelId));
  });

  Future<void> _connectGoogle() async {
    setState(() {
      _googleBusy = true;
      _error = null;
    });
    final message = await runGoogleSignIn(context);
    if (!mounted) return;
    setState(() {
      _googleBusy = false;
      _error = message;
    });
    if (message == null) await _load();
  }

  Future<void> _import() async {
    if (_selected.isEmpty) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final result = await context.read<AppState>().gateway.importChannels(
        widget.kid.id,
        _selected.toList(),
      );
      if (!mounted) return;
      final n = result.added.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            n == 0
                ? 'Already added to ${widget.kid.nickname}.'
                : '$n ${n == 1 ? 'channel' : 'channels'} added to '
                      '${widget.kid.nickname}.',
          ),
        ),
      );
      Navigator.of(context).pop(n > 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _error = 'Could not import: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final hasList =
        data != null && data.linked && data.subscriptions.isNotEmpty;
    return ParentScaffold(
      subtitle: 'For ${widget.kid.nickname}',
      title: 'Import from YouTube',
      body: switch (data) {
        _ when _loadError != null => LoadError(_loadError!, onRetry: _load),
        null => const Center(
          child: CircularProgressIndicator(color: HgColors.mango),
        ),
        SubscriptionList(linked: false) => _notLinked(),
        SubscriptionList(subscriptions: []) => _noSubscriptions(),
        SubscriptionList(:final subscriptions) => _list(subscriptions),
      },
      // Only shown when there is something to tick.
      bottom: hasList ? _actionBar() : null,
    );
  }

  // ------------------------------------------------------------------ states

  /// `linked: false` is a normal state, not an error: offer to connect.
  Widget _notLinked() {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
    final canUseGoogle = isDemo || GoogleAuth.shared.isConfigured;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            const GilliMini(size: 96),
            Text(
              'No Google account connected',
              textAlign: TextAlign.center,
              style: HgText.display(size: 24, color: HgColors.ink),
            ),
            Text(
              'Connect the Google account you watch YouTube with and Gilli '
              'lists the channels you already follow. You pick which ones '
              '${widget.kid.nickname} may watch. Nothing is added on its own.',
              textAlign: TextAlign.center,
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
            if (_error != null)
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: HgText.body(size: 14, color: HgColors.coral),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: GoogleButton(
                label: 'Connect Google',
                busy: _googleBusy,
                onPressed: canUseGoogle ? _connectGoogle : null,
                reason: canUseGoogle
                    ? null
                    : 'Google sign-in is not set up in this build. You can '
                          'still paste channel links on the kid\'s page.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noSubscriptions() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          const GilliMini(size: 96),
          Text(
            'No subscriptions on this account',
            textAlign: TextAlign.center,
            style: HgText.display(size: 24, color: HgColors.ink),
          ),
          Text(
            'Nothing to import yet. You can still paste a channel link on '
            '${widget.kid.nickname}\'s page.',
            textAlign: TextAlign.center,
            style: HgText.body(size: 15, color: HgColors.brown),
          ),
        ],
      ),
    ),
  );

  Widget _list(List<Subscription> all) {
    final selectable = _selectable(all);
    final allPicked =
        selectable.isNotEmpty && _selected.length == selectable.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        Text(
          'Channels you follow on YouTube. Tick the ones '
          '${widget.kid.nickname} may watch. Gilli still checks every new '
          'video before it shows up.',
          style: HgText.body(size: 14, color: HgColors.brown),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text('${all.length} subscriptions', style: HgText.label()),
            ),
            // 48 dp tall so it is a real hit target, not just text.
            SizedBox(
              height: 48,
              child: TextButton(
                onPressed: selectable.isEmpty
                    ? null
                    : () => _selectAll(selectable, !allPicked),
                style: TextButton.styleFrom(foregroundColor: HgColors.brown),
                child: Text(
                  allPicked ? 'Select none' : 'Select all',
                  style: HgText.body(size: 15, color: HgColors.brown),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_error != null) ...[
          Text(_error!, style: HgText.body(size: 14, color: HgColors.coral)),
          const SizedBox(height: 10),
        ],
        Column(
          spacing: 10,
          children: [
            for (final s in all)
              _SubscriptionTile(
                subscription: s,
                alreadyAdded: s.isApprovedFor(widget.kid.id),
                selected: _selected.contains(s.channelId),
                onChanged: (on) => _toggle(s, on),
              ),
          ],
        ),
      ],
    );
  }

  /// Bottom action bar, with the count in the label so the parent knows what
  /// the button is about to do.
  Widget _actionBar() {
    final n = _selected.length;
    return Container(
      decoration: const BoxDecoration(
        color: HgColors.white,
        border: Border(top: BorderSide(color: HgColors.line, width: 2)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: FilledButton(
            onPressed: n == 0 || _importing ? null : _import,
            style: FilledButton.styleFrom(
              // Disabled has to still look like a button: white on white
              // reads as nothing at all.
              disabledBackgroundColor: HgColors.line,
              disabledForegroundColor: HgColors.muted,
            ),
            child: _importing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : Text(
                    n == 0
                        ? 'Pick channels to add'
                        : 'Add $n ${n == 1 ? 'channel' : 'channels'}',
                    style: HgText.body(
                      size: 17,
                      color: n == 0 ? HgColors.muted : HgColors.ink,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.subscription,
    required this.alreadyAdded,
    required this.selected,
    required this.onChanged,
  });

  final Subscription subscription;
  final bool alreadyAdded;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return PCard(
      padding: EdgeInsets.zero,
      onTap: alreadyAdded ? null : () => onChanged(!selected),
      child: Padding(
        // 64 dp of content: comfortably over the 48 dp hit target.
        padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
        child: Row(
          spacing: 12,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: alreadyAdded
                  ? const Center(
                      child: Icon(
                        Icons.check_circle_rounded,
                        color: HgColors.green,
                        size: 28,
                      ),
                    )
                  : Checkbox(
                      value: selected,
                      onChanged: (v) => onChanged(v ?? false),
                      activeColor: HgColors.mango,
                      checkColor: HgColors.ink,
                      side: const BorderSide(color: HgColors.brown, width: 2),
                    ),
            ),
            _Thumb(subscription: subscription),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    subscription.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HgText.body(
                      size: 16,
                      color: alreadyAdded ? HgColors.muted : HgColors.ink,
                    ),
                  ),
                  if (alreadyAdded)
                    Text(
                      'Already added',
                      style: HgText.body(size: 13, color: HgColors.green),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Channel picture, with a lettered stand-in when the gateway sends no
/// thumbnail or the network is down.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.subscription});

  final Subscription subscription;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 48,
        height: 48,
        child: subscription.thumbUrl.isEmpty
            ? _letter()
            : Image.network(
                subscription.thumbUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _letter(),
              ),
      ),
    );
  }

  Widget _letter() {
    final t = subscription.title.trim();
    return ColoredBox(
      color: HgColors.line,
      child: Center(
        child: Text(
          t.isEmpty ? '?' : t[0].toUpperCase(),
          style: HgText.display(size: 22, color: HgColors.brown),
        ),
      ),
    );
  }
}
