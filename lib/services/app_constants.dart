const applicationBundleId = 'com.ghost233.ghostcontainermanager';

/// 应用显示名。
const applicationDisplayName = 'Ghost Container Manager';

/// 构建时经 `--dart-define=GCM_APP_VERSION=<版本>` 注入；本地开发构建为 dev。
const gcmAppVersion = String.fromEnvironment(
  'GCM_APP_VERSION',
  defaultValue: 'dev',
);
