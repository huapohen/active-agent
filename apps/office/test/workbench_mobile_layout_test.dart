import 'package:active_office/office_state.dart';
import 'package:active_office/ui/app_workbench.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'embedded mobile workbench omits duplicate title and keeps favorite controls and app opens usable',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final state = OfficeState();
      state.apps = [
        {'id': 'docs', 'name': '云文档', 'available': true, 'route': 'docs'},
        {'id': 'agents', 'name': 'Agent', 'available': true, 'route': 'agents'},
      ];
      state.appFavorites = ['docs', 'agents'];
      final opened = <String>[];
      Widget page({required bool embedded}) => MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: OfficeAppWorkbench(
            state: state,
            onOpen: opened.add,
            embeddedMobileHeader: embedded,
          ),
        ),
      );

      await tester.pumpWidget(page(embedded: true));
      expect(find.text('工作台'), findsNothing);
      expect(find.text('搜索应用'), findsNothing);
      expect(find.text('工作空间头条'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workbench-add-favorites')));
      await tester.pumpAndSettle();
      expect(find.text('添加常用应用'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workbench-sort-favorites')));
      await tester.pumpAndSettle();
      expect(find.text('排列常用应用'), findsOneWidget);
      expect(find.byType(ReorderableListView), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.appFavorites, ['docs', 'agents']);
      await tester.tap(
        find.byKey(const ValueKey('workbench-app-icon-agents')).first,
      );
      expect(opened, ['agents']);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(page(embedded: false));
      await tester.pump();
      expect(find.text('工作台'), findsOneWidget);
      expect(find.text('搜索应用'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  for (final width in [320.0, 402.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'workbench $width width at $scale scale keeps long app labels and controls visible',
        (tester) async {
          tester.view.physicalSize = Size(width, 874);
          tester.view.devicePixelRatio = 1;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });
          final state = OfficeState();
          state.apps = [
            for (var i = 0; i < 12; i++)
              {
                'id': 'app-$i',
                'name': '人事管理超级长应用名称$i',
                'available': true,
                'route': 'app-$i',
              },
          ];
          state.appFavorites = ['app-0', 'app-1', 'app-2', 'app-3'];
          await tester.pumpWidget(
            MaterialApp(
              theme: officeTheme(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 874),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: OfficeAppWorkbench(state: state, onOpen: (_) {}),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.drag(find.byType(ListView).first, const Offset(0, -450));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        },
      );
    }
  }
}
