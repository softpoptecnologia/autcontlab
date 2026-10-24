import 'package:flutter_test/flutter_test.dart';
import 'package:contagem_esteira/main.dart';

void main() {
  testWidgets('App sobe', (WidgetTester tester) async {
    await tester.pumpWidget(const ContagemApp());
    await tester.pump();
    expect(find.byType(ContagemApp), findsOneWidget);
  });
}
