import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart' show ApiException;
import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'ask_about_video_sheet.dart';
import 'parent_widgets.dart';

/// What Gilli makes of a video or channel the parent found themselves.
///
/// The only way to learn that used to be allowing the whole channel and
/// waiting for the screening. This reads a pasted link against the family's
/// own answers first — one video, or a channel's newest uploads — and nothing
/// reaches the child until the parent allows it here.
///
/// Each read is a transcript and a model call on an allowance every household
/// shares, so there are a few a day, and the screen says how many are left.
class CheckLinkScreen extends StatefulWidget {
  const CheckLinkScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<CheckLinkScreen> createState() => _CheckLinkScreenState();
}

class _CheckLinkScreenState extends State<CheckLinkScreen> {
  final _url = TextEditingController();
  LinkCheck? _result;
  String _checkedUrl = '';
  bool _checking = false;
  String? _error;

  /// Allowed from here, so the card says so without another round trip.
  final _allowed = <String>{};
  final _allowing = <String>{};
  bool _addingChannel = false;
  bool _channelAdded = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final url = _url.text.trim();
    if (url.isEmpty || _checking) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().gateway.checkLink(
        widget.kid.id,
        url,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _checkedUrl = url;
        _allowed.clear();
        _channelAdded = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _detail(e));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not check that: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// The gateway's own sentence ("That is all 3 checks for today…") rather
  /// than a status code.
  static String _detail(ApiException e) {
    try {
      final d = (jsonDecode(e.body) as Map)['detail'];
      if (d is String && d.isNotEmpty) return d;
    } catch (_) {}
    return 'Could not check that (${e.status}).';
  }

  Future<void> _allow(ReviewItem item) async {
    setState(() => _allowing.add(item.video.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().gateway.reviewDecide(
        widget.kid.id,
        approve: [item.video.id],
      );
      if (!mounted) return;
      setState(() => _allowed.add(item.video.id));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${item.video.title} is on ${widget.kid.nickname}\'s shelf.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not allow it: $e')));
    } finally {
      if (mounted) setState(() => _allowing.remove(item.video.id));
    }
  }

  Future<void> _addChannel() async {
    setState(() => _addingChannel = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().gateway.addChannel(
        widget.kid.id,
        _checkedUrl,
      );
      if (!mounted) return;
      setState(() => _channelAdded = true);
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Added. Gilli reads its new videos as they arrive, the same way.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not add it: $e')));
    } finally {
      if (mounted) setState(() => _addingChannel = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.kid.nickname;
    final r = _result;
    return ParentScaffold(
      title: 'Check before you allow',
      subtitle: 'FOR ${name.toUpperCase()}',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'Paste a YouTube video or channel link. Gilli reads it against '
            'your answers for $name. Nothing reaches $name unless you allow it.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 12),
          Row(
            spacing: 10,
            children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  style: HgText.body(size: 15, color: HgColors.ink),
                  decoration: const InputDecoration(
                    hintText: 'Video or channel link',
                  ),
                  onSubmitted: (_) => _check(),
                ),
              ),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _checking ? null : _check,
                  child: _checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: HgColors.white,
                          ),
                        )
                      : const Text('Check'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            r == null
                ? '3 checks a day. Looking again at one is free.'
                : '${r.checksLeft} of ${r.perDay} checks left today',
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
          if (_checking) ...[
            const SizedBox(height: 12),
            Text(
              'Reading it. This can take a minute.',
              style: HgText.body(size: 14, color: HgColors.brown),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: HgText.body(size: 14, color: HgColors.coral)),
          ],
          if (r != null) ...[
            const SizedBox(height: 16),
            if (r.isChannel)
              _ChannelHeader(
                title: r.channelTitle,
                thumb: r.channelThumb,
                read: r.items.length,
                added: _channelAdded,
                busy: _addingChannel,
                onAdd: _addChannel,
              ),
            for (final item in r.items)
              _CheckCard(
                item: item,
                kidName: name,
                onShelf:
                    r.onShelf.contains(item.video.id) ||
                    _allowed.contains(item.video.id),
                busy: _allowing.contains(item.video.id),
                onAllow: () => _allow(item),
                onAsk: () => AskAboutVideoSheet.open(
                  context,
                  kidId: widget.kid.id,
                  video: item.video,
                  channelTitle: item.channelTitle,
                ),
              ),
            if (r.notRead > 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '${r.notRead} more not read: that is all of today\'s checks.',
                  style: HgText.body(size: 13, color: HgColors.muted),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.title,
    required this.thumb,
    required this.read,
    required this.added,
    required this.busy,
    required this.onAdd,
  });

  final String title;
  final String thumb;
  final int read;
  final bool added;
  final bool busy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => PCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Row(
          spacing: 12,
          children: [
            ClipOval(
              child: SizedBox.square(
                dimension: 44,
                child: thumb.isEmpty
                    ? const ColoredBox(
                        color: HgColors.line,
                        child: Icon(Icons.tv_rounded, color: HgColors.brown),
                      )
                    : Image.network(
                        thumb,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: HgColors.line),
                      ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: HgText.display(size: 20, color: HgColors.ink),
                  ),
                  Text(
                    read == 1
                        ? 'Its newest video, read below'
                        : 'Its newest $read videos, read below',
                    style: HgText.body(size: 13, color: HgColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: added
              ? Text(
                  'Added. New videos are read as they arrive.',
                  style: HgText.body(size: 14, color: HgColors.green),
                )
              : FilledButton.icon(
                  onPressed: busy ? null : onAdd,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Add this channel'),
                ),
        ),
      ],
    ),
  );
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({
    required this.item,
    required this.kidName,
    required this.onShelf,
    required this.busy,
    required this.onAllow,
    required this.onAsk,
  });

  final ReviewItem item;
  final String kidName;
  final bool onShelf;
  final bool busy;
  final VoidCallback onAllow;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final (verdict, fill) = switch (item.status) {
      'approve' => ('Fits your answers', HgColors.green),
      'hide' => ('Gilli would keep it back', HgColors.mango),
      _ => ('Gilli would ask you', HgColors.mango),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: PCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    item.video.thumb,
                    width: 92,
                    height: 62,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(width: 92),
                  ),
                ),
                Expanded(
                  child: Text(
                    item.video.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: HgText.body(size: 15, color: HgColors.ink),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Chip(verdict, fill: fill, ink: HgColors.white),
                for (final c in item.concerns)
                  _Chip(c, fill: HgColors.white, ink: HgColors.mango),
                for (final t in item.topics)
                  _Chip(t, fill: HgColors.cream, ink: HgColors.ink),
              ],
            ),
            // The reason is the point of a check, so it is shown, not folded.
            Text(
              item.reason,
              style: HgText.body(size: 14, color: HgColors.brown),
            ),
            if (item.read == 'title only')
              Text(
                'Read on the title and description only',
                style: HgText.body(size: 12, color: HgColors.muted),
              ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (onShelf)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      "On $kidName's shelf",
                      style: HgText.body(size: 14, color: HgColors.green),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: busy ? null : onAllow,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(
                      item.status == 'approve'
                          ? 'Allow for $kidName'
                          : 'Allow anyway',
                    ),
                    style: TextButton.styleFrom(foregroundColor: HgColors.ink),
                  ),
                TextButton.icon(
                  onPressed: onAsk,
                  icon: const Icon(Icons.help_outline_rounded, size: 18),
                  label: const Text('Ask about this'),
                  style: TextButton.styleFrom(foregroundColor: HgColors.ink),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {required this.fill, required this.ink});
  final String text;
  final Color fill;
  final Color ink;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: fill,
      border: Border.all(
        color: fill == HgColors.white ? ink : fill,
        width: 1.5,
      ),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: HgText.body(size: 12.5, color: ink, weight: FontWeight.w700),
    ),
  );
}
