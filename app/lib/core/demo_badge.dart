import 'package:flutter/material.dart';

import 'theme.dart';

/// Small coral "demo" pill shown whenever the app runs on the in-app
/// FakeGateway, so nobody mistakes canned replies for the live agents.
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key, this.dark = true});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: HgColors.coral,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('demo', style: HgText.body(size: 12, color: HgColors.cream)),
    );
  }
}
