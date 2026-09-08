import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'professional_identity.dart';
import 'companion_identity.dart';

class AgentCatalog extends StatefulWidget {
  const AgentCatalog({
    super.key,
    required this.state,
    required this.onInstalled,
  });
  final OfficeState state;
  final VoidCallback onInstalled;
  @override
  State<AgentCatalog> createState() => _AgentCatalogState();
}

class _AgentCatalogState extends State<AgentCatalog> {
  String _query = '', _category = '', _profession = '', _organization = '';
  final Set<String> _busy = {};
  String categoryId(Json item) =>
      str(item['category_id'], str(item['category_name']));
  Future<void> _install(Json agent) async {
    final id = str(agent['id']);
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await widget.state.installAgent(id);
      if (mounted) {
        notifyOffice(context, '已添加为 Agent 好友');
        widget.onInstalled();
      }
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) {
      final catalog = widget.state.catalog;
      final categories = <String, String>{};
      for (final entry in catalog) {
        final id = categoryId(entry);
        if (id.isNotEmpty) categories[id] = str(entry['category_name'], id);
      }
      List<String> options(String key) =>
          catalog
              .map((entry) => str(entry[key]))
              .where((v) => v.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      final professions = options('profession'),
          organizations = options('organization_name');
      final category = categories.containsKey(_category) ? _category : '';
      final profession = professions.contains(_profession) ? _profession : '';
      final organization = organizations.contains(_organization)
          ? _organization
          : '';
      final query = _query.trim().toLowerCase();
      final matches = catalog
          .where(
            (entry) =>
                (category.isEmpty || categoryId(entry) == category) &&
                (profession.isEmpty || entry['profession'] == profession) &&
                (organization.isEmpty ||
                    entry['organization_name'] == organization) &&
                (query.isEmpty ||
                    professionalSearchText(entry).contains(query)),
          )
          .toList();
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xffedf2ff), Color(0xfff4f0fe)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '为工作，找到合适的 Agent',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 10),
                Text(
                  '按职业、职位与技能选择工作伙伴。添加好友后，可私聊或邀请加入项目工作群。',
                  style: TextStyle(
                    fontSize: officeFontSize(context, desktop: 12, mobile: 14),
                    color: Color(0xff737f99),
                    height: 1.9,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          OfficeSearch(
            hint: '搜索名称、职业、职位、组织或技能',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, box) => Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (categories.isNotEmpty)
                  _filter(
                    '工作分类',
                    _category,
                    categories,
                    box.maxWidth,
                    (value) => _category = value,
                  ),
                if (professions.isNotEmpty)
                  _filter(
                    '职业',
                    _profession,
                    {for (final v in professions) v: v},
                    box.maxWidth,
                    (value) => _profession = value,
                  ),
                if (organizations.isNotEmpty)
                  _filter(
                    '来源组织',
                    _organization,
                    {for (final v in organizations) v: v},
                    box.maxWidth,
                    (value) => _organization = value,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '找到 ${matches.length} 位 Agent · 目录共 ${catalog.length} 位',
            style: TextStyle(
              fontSize: officeFontSize(context, desktop: 12, mobile: 14),
              color: mutedColor,
            ),
          ),
          const SizedBox(height: 16),
          if (matches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                catalog.isEmpty
                    ? '商店暂时没有可添加的 Agent。'
                    : '没有匹配的 Agent，试试其他关键词或筛选条件。',
                style: TextStyle(
                  fontSize: officeFontSize(context, desktop: 12, mobile: 14),
                  color: mutedColor,
                ),
              ),
            ),
          ...matches.map(_card),
        ],
      );
    },
  );

  Widget _filter(
    String label,
    String selected,
    Map<String, String> choices,
    double width,
    void Function(String) apply,
  ) => SizedBox(
    width: width < 560 ? width : (width - 24) / 3,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label:$selected:${choices.keys.join(',')}'),
      initialValue: choices.containsKey(selected) ? selected : '',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: '', child: Text('全部')),
        ...choices.entries.map(
          (entry) => DropdownMenuItem(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: (value) => setState(() => apply(value ?? '')),
    ),
  );

  Widget _card(Json agent) {
    final id = str(agent['id']);
    final category = str(agent['category_name']);
    final skills = [
      ...(agent['skills'] as List? ?? []),
      ...(agent['tags'] as List? ?? []),
    ].map(str).where((v) => v.isNotEmpty).toSet();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: borderColor),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isOfficeCompanion(agent))
                    CompanionAvatar(person: agent)
                  else
                    PersonAvatar(
                      name: str(agent['name']),
                      agent: true,
                      size: 42,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          str(agent['name']),
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 15,
                              mobile: 17,
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (category.isNotEmpty)
                          Text(
                            category,
                            style: TextStyle(
                              fontSize: officeFontSize(
                                context,
                                desktop: 10,
                                mobile: 12,
                              ),
                              color: mutedColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy.contains(id)
                        ? null
                        : () => _install(agent),
                    child: Text(
                      _busy.contains(id) ? '正在添加' : '添加好友',
                      style: TextStyle(
                        fontSize: officeFontSize(
                          context,
                          desktop: 11,
                          mobile: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              ProfessionalIdentity(person: agent, catalog: true),
              const SizedBox(height: 12),
              Text(
                str(agent['description']),
                style: TextStyle(
                  fontSize: officeFontSize(context, desktop: 12, mobile: 14),
                  color: mutedColor,
                  height: 1.8,
                ),
              ),
              CompanionCapabilities(person: agent),
              if (skills.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 5,
                    children: skills
                        .map(
                          (skill) => DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xfff3f5fa),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Text(
                                skill,
                                style: TextStyle(
                                  fontSize: officeFontSize(
                                    context,
                                    desktop: 10,
                                    mobile: 12,
                                  ),
                                  color: Color(0xff667494),
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              if (str(agent['instructions']).isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    '查看工作约定',
                    style: TextStyle(
                      fontSize: officeFontSize(
                        context,
                        desktop: 11,
                        mobile: 14,
                      ),
                      color: accentColor,
                    ),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        str(agent['instructions']),
                        style: TextStyle(
                          fontSize: officeFontSize(
                            context,
                            desktop: 11,
                            mobile: 14,
                          ),
                          color: mutedColor,
                          height: 1.8,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
