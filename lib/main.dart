import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';

void main() {
  // 就绪检测 debug 绕行（docs/spec/onboarding.md）：仅 debug 构建生效。
  final debugBypass =
      kDebugMode &&
      Platform.environment['GCM_DEBUG_ALLOW_UNSUPPORTED_RUNTIME'] == '1';
  runApp(GhostContainerManagerApp(debugBypass: debugBypass));
}
