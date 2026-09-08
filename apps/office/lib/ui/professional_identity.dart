import 'package:flutter/material.dart';

import 'office_theme.dart';

String professionalSearchText(Json person) => [
  for (final key in [
    'name',
    'description',
    'category_name',
    'profession',
    'job_title',
    'organization_name',
    'source_organization_name',
    'department_name',
  ])
    str(person[key]),
  ...(person['skills'] as List? ?? []).map(str),
  ...(person['tags'] as List? ?? []).map(str),
].join(' ').toLowerCase();

/// Source organization describes the identity's origin. It does not assign
/// membership or authority in the current enterprise.
class ProfessionalIdentity extends StatelessWidget {
  const ProfessionalIdentity({
    super.key,
    required this.person,
    this.enterpriseName,
    this.catalog = false,
  });
  final Json person;
  final String? enterpriseName;
  final bool catalog;

  @override
  Widget build(BuildContext context) {
    final fields = <String, String>{
      if (str(person['profession']).isNotEmpty) '职业': str(person['profession']),
      if (str(person['job_title']).isNotEmpty) '职位': str(person['job_title']),
      if (!catalog &&
          str(person['organization_name'], str(enterpriseName)).isNotEmpty)
        '任职组织': str(person['organization_name'], str(enterpriseName)),
      if (str(person['department_name']).isNotEmpty)
        catalog ? '来源部门' : '部门': str(person['department_name']),
      if (str(
        person[catalog ? 'organization_name' : 'source_organization_name'],
      ).isNotEmpty)
        '来源组织': str(
          person[catalog ? 'organization_name' : 'source_organization_name'],
        ),
    };
    if (fields.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Wrap(
        spacing: 12,
        runSpacing: 5,
        children: fields.entries
            .map(
              (entry) => Text(
                '${entry.key}：${entry.value}',
                style: TextStyle(
                  fontSize: officeFontSize(context, desktop: 11, mobile: 14),
                  height: 1.6,
                  color: mutedColor,
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}
