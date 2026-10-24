import 'package:flutter/material.dart';

/// Shared motion tokens for implicit UI transitions.
abstract final class GcmMotion {
  static const pageSwitchDuration = Duration(milliseconds: 180);
  static const pageSwitchCurve = Curves.easeInOut;
  static const scrollFollowDuration = Duration(milliseconds: 200);
  static const scrollFollowCurve = Curves.easeOut;
}

/// Operation-local progress indicator; never used as a page loading state.
class GcmInlineSpinner extends StatelessWidget {
  const GcmInlineSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
