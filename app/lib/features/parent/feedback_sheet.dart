import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart' show ApiException;
import '../../core/app_state.dart';
import '../../core/theme.dart';

/// "Send feedback": a line or two to the people who make HeyGilli.
///
/// Parent side only. A child typing into a box that goes to strangers is the
/// wrong thing to offer, so nothing in kid mode opens this. What is sent is
/// kept with the household and read only by the service's admins.
Future<void> showFeedbackSheet(
  BuildContext context, {
  String where = '',
}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FeedbackSheet(where: where),
  );
  if (sent == true && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Thank you. It is on its way to us.')),
    );
  }
}

class _FeedbackSheet extends StatefulWidget {
  const _FeedbackSheet({required this.where});

  final String where;

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  final _text = TextEditingController();
  final _contact = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await context.read<AppState>().gateway.sendFeedback(
        _text.text.trim(),
        contact: _contact.text.trim(),
        where: widget.where,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.status == 429
            ? 'That is a lot for one day. Please try again tomorrow.'
            : 'Could not send it. Please try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Could not send it. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSend = !_sending && _text.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text('Send feedback', style: HgText.display(size: 24)),
          Text(
            'What worked, what did not, what you wish it did. It goes to the '
            'people who make HeyGilli.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          TextField(
            key: const Key('feedback-text'),
            controller: _text,
            autofocus: true,
            minLines: 4,
            maxLines: 8,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Tell us anything',
              border: OutlineInputBorder(),
            ),
          ),
          TextField(
            key: const Key('feedback-contact'),
            controller: _contact,
            maxLength: 200,
            decoration: const InputDecoration(
              hintText: 'Email or phone, if you would like a reply (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Text(_error!, style: HgText.body(size: 14, color: HgColors.coral)),
          FilledButton(
            key: const Key('feedback-send'),
            onPressed: canSend ? _send : null,
            child: Text(_sending ? 'Sending…' : 'Send'),
          ),
        ],
      ),
    );
  }
}
