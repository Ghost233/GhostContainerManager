import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/main.dart';

void main() {
  testWidgets('app pumps and shows the workspace placeholder', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const GhostContainerManagerApp());

    expect(find.text('容器'), findsOneWidget);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('未选择项目'), findsOneWidget);
  });
}
