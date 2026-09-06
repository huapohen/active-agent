import 'package:active_office/office_state.dart';
import 'package:active_office/ui/agent_friend_directory.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:active_office/ui/people.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const friendRecords = <Json>[
  {
    'id': 'front',
    'kind': 'agent',
    'name': '前端同事',
    'organization_id': 'alpha',
    'organization_name': '甲方公司',
    'department_id': 'eng',
    'department_name': '研发部',
    'profession': '软件研发',
    'job_title': '前端工程师',
    'category_id': 'engineering',
    'category_name': '软件工程',
    'skills': ['界面开发'],
  },
  {
    'id': 'back',
    'kind': 'agent',
    'name': '后端同事',
    'organization_id': 'alpha',
    'organization_name': '甲方公司',
    'department_id': 'eng',
    'department_name': '研发部',
    'profession': '软件研发',
    'job_title': '后端工程师',
    'category_id': 'engineering',
    'category_name': '软件工程',
    'skills': ['接口开发'],
  },
  {
    'id': 'product',
    'kind': 'agent',
    'name': '产品同事',
    'organization_id': 'alpha',
    'organization_name': '甲方公司',
    'department_id': 'product',
    'department_name': '产品部',
    'profession': '产品设计',
    'job_title': '产品经理',
    'category_id': 'product',
    'category_name': '产品研究',
  },
  {
    'id': 'remote',
    'kind': 'agent',
    'name': '乙方同事',
    'organization_id': 'beta',
    'organization_name': '乙方公司',
    'department_id': 'eng',
    'department_name': '研发部',
    'profession': '软件研发',
    'job_title': '后端工程师',
    'category_id': 'engineering',
    'category_name': '软件工程',
  },
  {
    'id': 'unassigned',
    'kind': 'agent',
    'name': '待任职同事',
    'source_organization_name': '来源示例工作室',
    'source_department_name': '来源实验室',
  },
];

class AgentFriendsFixture extends OfficeState {
  AgentFriendsFixture({String kind = 'human'}) {
    endpoint = 'https://friends-fixture.example';
    connected = true;
    me = {'id': 'owner-$kind', 'name': '合成用户', 'kind': kind};
    agents = friendRecords.map(Json.from).toList();
    principals = [me!, ...agents];
    contacts = [
      {'id': 'human-peer', 'kind': 'human', 'name': '人类同事'},
    ];
  }
  int generation = 0;
  final directs = <String>[];
  @override
  int get identityGeneration => generation;
  @override
  Future<void> openDirect(String id) async {
    directs.add(id);
  }

  void changed() => notifyListeners();
}

Future<void> mountFriends(
  WidgetTester tester,
  AgentFriendsFixture state, {
  Size size = const Size(1220, 982),
  bool agent = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    state.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: state,
          builder: (context, _) =>
              OfficePeople(state: state, agent: agent, onConversation: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder friendRow(String id) => find.byKey(ValueKey('agent-friend-row-$id'));
Finder filterChoice(String dimension, String id, [String? child]) => find.byKey(
  ValueKey(
    'agent-filter-$dimension-${Uri.encodeComponent(id)}${child == null ? '' : '/${Uri.encodeComponent(child)}'}',
  ),
);
Finder friendSearch() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && widget.decoration?.hintText == '查找 Agent 好友',
);

Future<void> showTree(WidgetTester tester, Size size) async {
  if (size.width < 760) {
    await tester.tap(find.byKey(const ValueKey('agent-friends-open-filters')));
    await tester.pumpAndSettle();
  }
}

Future<void> closeTree(WidgetTester tester, Size size) async {
  if (size.width < 760) {
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  }
}

Future<void> choose(
  WidgetTester tester,
  String dimension,
  String id, [
  String? child,
]) async {
  if (child != null) {
    final parent = find.byKey(ValueKey('agent-friends-expand-$dimension-$id'));
    await tester.ensureVisible(parent);
    await tester.pumpAndSettle();
    if (filterChoice(dimension, id, child).evaluate().isEmpty) {
      final rect = tester.getRect(parent);
      await tester.tapAt(Offset(rect.right - 18, rect.top + 24));
      await tester.pumpAndSettle();
    }
  }
  final choice = filterChoice(dimension, id, child);
  await tester.ensureVisible(choice);
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

Future<void> finishFriends(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  test('actual organization membership groups departments without promoting catalog source', () {
    final groups = agentFriendGroups(
      friendRecords,
      const AgentFriendFilters(),
      dimension: 'organization',
    );
    expect(groups.map((group) => group.id).toSet(), {'alpha', 'beta', ''});
    final alpha = groups.firstWhere((group) => group.id == 'alpha');
    expect(alpha.count, 3);
    expect(alpha.children['eng']!.count, 2);
    expect(alpha.children['product']!.count, 1);
    final beta = groups.firstWhere((group) => group.id == 'beta');
    expect(beta.children['eng']!.count, 1);
    final unknown = groups.firstWhere((group) => group.id.isEmpty);
    expect(unknown.name, '未分配组织');
    expect(unknown.children['']!.name, '未分配部门');
    expect(groups.any((group) => group.name == '来源示例工作室'), isFalse);
  });

  test('organization profession and category combine with skills search; facet counts respect other selections', () {
    const filters = AgentFriendFilters(
      organization: 'alpha',
      department: 'eng',
      profession: '软件研发',
      jobTitle: '后端工程师',
      category: 'engineering',
    );
    expect(
      friendRecords
          .where((person) => filters.matches(person))
          .map((person) => person['id']),
      ['back'],
    );
    expect(
      friendRecords
          .where((person) => filters.matches(person, query: '接口'))
          .map((person) => person['id']),
      ['back'],
    );
    expect(
      friendRecords.where((person) => filters.matches(person, query: '界面')),
      isEmpty,
    );
    final orgs = agentFriendGroups(
      friendRecords,
      filters,
      dimension: 'organization',
    );
    expect(orgs.firstWhere((group) => group.id == 'alpha').count, 1);
    expect(orgs.firstWhere((group) => group.id == 'beta').count, 1);
    final professions = agentFriendGroups(
      friendRecords,
      filters,
      dimension: 'profession',
    );
    expect(professions.firstWhere((group) => group.id == '软件研发').count, 2);
  });

  for (final size in [const Size(390, 844), const Size(1220, 982)]) {
    for (final kind in ['human', 'agent']) {
      testWidgets(
        '${size.width.toInt()}px $kind combines real organization department profession title and category then opens correct colleague',
        (tester) async {
          final state = AgentFriendsFixture(kind: kind);
          await mountFriends(tester, state, size: size);
          expect(find.text('5 / 5 位好友'), findsOneWidget);
          await showTree(tester, size);
          await choose(tester, 'organization', 'alpha', 'eng');
          await choose(tester, 'profession', '软件研发', '后端工程师');
          await choose(tester, 'category', 'engineering');
          await closeTree(tester, size);
          expect(find.text('1 / 5 位好友'), findsOneWidget);
          expect(friendRow('back'), findsOneWidget);
          expect(friendRow('front'), findsNothing);
          expect(friendRow('remote'), findsNothing);
          await tester.enterText(friendSearch(), '接口');
          await tester.pumpAndSettle();
          expect(friendRow('back'), findsOneWidget);
          await tester.tap(
            find.descendant(of: friendRow('back'), matching: find.text('发消息')),
          );
          await tester.pumpAndSettle();
          expect(state.directs, ['back']);
          await tester.enterText(friendSearch(), '不匹配内容');
          await tester.pumpAndSettle();
          expect(find.text('没有匹配的 Agent 好友'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('agent-friends-reset')));
          await tester.pumpAndSettle();
          expect(find.text('5 / 5 位好友'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('agent-friends-selected-organization')),
            findsNothing,
          );
          expect(
            tester.widget<TextField>(friendSearch()).controller!.text,
            isEmpty,
          );
          await finishFriends(tester);
        },
      );
    }
  }

  testWidgets(
    'source-only friend is under unassigned and remains searchable by its disclosed source',
    (tester) async {
      final state = AgentFriendsFixture();
      await mountFriends(tester, state);
      await choose(tester, 'organization', '', '');
      expect(find.text('1 / 5 位好友'), findsOneWidget);
      expect(friendRow('unassigned'), findsOneWidget);
      await tester.enterText(friendSearch(), '来源示例工作室');
      await tester.pumpAndSettle();
      expect(friendRow('unassigned'), findsOneWidget);
      expect(find.text('来源组织：来源示例工作室'), findsOneWidget);
      await finishFriends(tester);
    },
  );

  for (final change in ['principal', 'generation', 'endpoint']) {
    testWidgets(
      '$change change closes old mobile filter scope and clears private query',
      (tester) async {
        final state = AgentFriendsFixture();
        const size = Size(390, 844);
        await mountFriends(tester, state, size: size);
        await tester.enterText(friendSearch(), '前端');
        await tester.pumpAndSettle();
        await showTree(tester, size);
        final oldChoice = tester
            .widget<ListTile>(filterChoice('organization', 'alpha'))
            .onTap!;
        if (change == 'principal') {
          state.me = {'id': 'new-agent', 'kind': 'agent'};
        }
        if (change == 'generation') {
          state.generation++;
        }
        if (change == 'endpoint') {
          state.endpoint = 'https://new-friends-fixture.example';
        }
        state.changed();
        await tester.pumpAndSettle();
        expect(find.text('完成'), findsNothing);
        expect(
          tester.widget<TextField>(friendSearch()).controller!.text,
          isEmpty,
        );
        oldChoice();
        await tester.pumpAndSettle();
        expect(find.text('5 / 5 位好友'), findsOneWidget);
        await finishFriends(tester);
      },
    );
  }

  testWidgets('temporary offline preserves local classifications and query', (
    tester,
  ) async {
    final state = AgentFriendsFixture();
    await mountFriends(tester, state);
    await choose(tester, 'organization', 'beta');
    await tester.enterText(friendSearch(), '乙方');
    await tester.pumpAndSettle();
    state.connected = false;
    state.changed();
    await tester.pumpAndSettle();
    expect(find.text('1 / 5 位好友'), findsOneWidget);
    expect(friendRow('remote'), findsOneWidget);
    state.connected = true;
    state.changed();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(friendSearch()).controller!.text, '乙方');
    await finishFriends(tester);
  });

  testWidgets(
    'human contacts retain their existing directory flow without Agent classification UI',
    (tester) async {
      final state = AgentFriendsFixture();
      await mountFriends(tester, state, agent: false);
      expect(find.text('人类同事'), findsOneWidget);
      expect(find.text('我的联系人'), findsOneWidget);
      expect(find.byType(OfficeAgentFriendDirectory), findsNothing);
      expect(find.text('公司 / 组织'), findsNothing);
      await finishFriends(tester);
    },
  );

  testWidgets(
    'a thousand friends remain searchable and the last matching colleague opens by its actual id',
    (tester) async {
      final state = AgentFriendsFixture();
      state.agents = [
        for (var i = 0; i < 1000; i++)
          {
            ...friendRecords.first,
            'id': 'many-$i',
            'name': '大量同事 $i',
            'organization_id': 'company-${i % 10}',
            'organization_name': '真实测试公司 ${i % 10}',
          },
      ];
      state.principals = [state.me!, ...state.agents];
      await mountFriends(tester, state);
      expect(find.text('1000 / 1000 位好友'), findsOneWidget);
      expect(friendRow('many-999'), findsNothing);
      await tester.enterText(friendSearch(), '大量同事 999');
      await tester.pumpAndSettle();
      expect(find.text('1 / 1000 位好友'), findsOneWidget);
      expect(friendRow('many-999'), findsOneWidget);
      await tester.tap(
        find.descendant(of: friendRow('many-999'), matching: find.text('发消息')),
      );
      await tester.pumpAndSettle();
      expect(state.directs, ['many-999']);
      await finishFriends(tester);
    },
  );
}
