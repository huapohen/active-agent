import 'package:flutter/foundation.dart';

import 'office_state.dart';

/// The enterprise console uses the signed-in principal's ordinary transport.
/// Role capabilities are server responses; UI identity kind grants no authority.
class EnterpriseState extends ChangeNotifier {
  EnterpriseState(this.office)
    : _identity = '${office.endpoint}:${office.me?['id']}';
  final OfficeState office;
  final String _identity;
  bool _disposed = false, loading = false, loaded = false;
  String? error;
  Json enterprise = {}, membership = {}, capabilities = {}, counts = {};
  List<Json> members = [],
      departments = [],
      organizations = [],
      roles = [],
      audit = [],
      apps = [];
  int memberPage = 1, memberTotal = 0, auditPage = 1, auditTotal = 0;
  String memberQuery = '',
      memberStatus = 'all',
      memberRole = 'all',
      auditQuery = '';
  String? memberDepartment, memberOrganization;
  int _memberRequest = 0, _auditRequest = 0, _appsRequest = 0;
  bool get current =>
      !_disposed && _identity == '${office.endpoint}:${office.me?['id']}';
  bool can(String capability) => capabilities[capability] == true;
  bool canEditMember(Json member) =>
      can('manage_members') &&
      member['status'] != 'revoked' &&
      (membership['role'] == 'owner' ||
          member['role'] == 'member' ||
          (member['principal_id'] ?? member['id']) ==
              membership['principal_id']);
  List<Json> _list(dynamic value) => value is List
      ? value.whereType<Map>().map((v) => Json.from(v)).toList()
      : [];
  void _notify() {
    if (current) notifyListeners();
  }

  Future<Json> _request(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (!current) throw OfficeException(401, '工作身份已切换，请重新打开企业管理');
    final result = await office.officeRequest(path, method: method, data: data);
    if (!current) throw OfficeException(401, '工作身份已切换，请重新打开企业管理');
    return result;
  }

  void _applySummary(Json result) {
    enterprise = Json.from(result['enterprise'] ?? {});
    membership = Json.from(result['membership'] ?? {});
    capabilities = Json.from(result['capabilities'] ?? {});
    if (result['counts'] is Map) counts = Json.from(result['counts']);
  }

  Future<void> load() async {
    loading = true;
    error = null;
    _notify();
    try {
      _applySummary(await _request('/enterprise'));
      loaded = true;
      if (can('access_admin')) {
        _applySummary(await _request('/enterprise/admin/overview'));
        await Future.wait([
          loadMembers(),
          loadDepartments(),
          if (can('manage_organizations')) loadOrganizations(),
          loadRoles(),
          if (can('view_audit')) loadAudit(),
        ]);
      } else {
        members = [];
        departments = [];
        organizations = [];
        roles = [];
        audit = [];
        apps = [];
        counts = {};
      }
    } catch (e) {
      if (current) {
        error = e.toString();
        if (e is OfficeException && (e.status == 401 || e.status == 403)) {
          capabilities = {};
          members = [];
          departments = [];
          organizations = [];
          roles = [];
          audit = [];
          apps = [];
          counts = {};
        }
      }
    } finally {
      if (current) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> loadMembers({
    int? page,
    String? query,
    String? status,
    String? role,
    String? department,
    bool clearDepartment = false,
    String? organization,
    bool clearOrganization = false,
  }) async {
    final sequence = ++_memberRequest;
    final nextPage = page ?? memberPage;
    memberQuery = query ?? memberQuery;
    memberStatus = status ?? memberStatus;
    memberRole = role ?? memberRole;
    if (clearDepartment) {
      memberDepartment = null;
    } else {
      memberDepartment = department ?? memberDepartment;
    }
    if (clearOrganization) {
      memberOrganization = null;
    } else {
      memberOrganization = organization ?? memberOrganization;
    }
    final params = Uri(
      queryParameters: {
        'page': '$nextPage',
        'page_size': '25',
        'q': memberQuery,
        'status': memberStatus,
        'role': memberRole,
        'department_id': ?memberDepartment,
        'organization_id': ?memberOrganization,
      },
    ).query;
    final result = await _request('/enterprise/admin/members?$params');
    if (sequence != _memberRequest) return;
    members = _list(result['members']);
    memberPage = (result['page'] as num?)?.toInt() ?? nextPage;
    memberTotal = (result['total'] as num?)?.toInt() ?? members.length;
    _notify();
  }

  Future<Json> readMember(String id) async {
    final result = await _request(
      '/enterprise/admin/members/${Uri.encodeComponent(id)}',
    );
    if (result['member'] is! Map) {
      throw OfficeException(502, '成员详情响应不完整，请刷新后重试');
    }
    final member = Json.from(result['member']);
    if ((member['principal_id'] ?? member['id']) != id) {
      throw OfficeException(502, '成员详情与当前选择不一致，请刷新后重试');
    }
    return member;
  }

  Future<void> loadDepartments() async {
    departments = _list(
      (await _request('/enterprise/admin/departments'))['departments'],
    );
    _notify();
  }

  Future<void> loadOrganizations() async {
    organizations = _list(
      (await _request('/enterprise/admin/organizations'))['organizations'],
    );
    _notify();
  }

  Future<void> saveOrganization({
    Json? organization,
    required String name,
    required String description,
    required String clientId,
  }) async {
    await _request(
      '/enterprise/admin/organizations${organization == null ? '' : '/${Uri.encodeComponent(strId(organization['id']))}'}',
      method: organization == null ? 'POST' : 'PATCH',
      data: {
        'name': name,
        'description': description,
        if (organization == null)
          'client_id': clientId
        else
          'base_revision': organization['revision'],
      },
    );
    await _refreshAfterWrite();
  }

  Future<void> deleteOrganization(Json organization) async {
    await _request(
      '/enterprise/admin/organizations/${Uri.encodeComponent(strId(organization['id']))}',
      method: 'DELETE',
      data: {'base_revision': organization['revision']},
    );
    await _refreshAfterWrite();
  }

  String strId(dynamic value) => value?.toString() ?? '';

  Future<void> loadRoles() async {
    roles = _list((await _request('/enterprise/admin/roles'))['roles']);
    _notify();
  }

  Future<void> loadAudit({int? page, String? query}) async {
    final sequence = ++_auditRequest, nextPage = page ?? auditPage;
    auditQuery = query ?? auditQuery;
    final params = Uri(
      queryParameters: {
        'page': '$nextPage',
        'page_size': '25',
        'q': auditQuery,
      },
    ).query;
    final result = await _request('/enterprise/admin/audit?$params');
    if (sequence != _auditRequest) return;
    audit = _list(result['entries']);
    auditPage = (result['page'] as num?)?.toInt() ?? nextPage;
    auditTotal = (result['total'] as num?)?.toInt() ?? audit.length;
    _notify();
  }

  Future<void> loadApps({String query = ''}) async {
    final request = ++_appsRequest;
    final result = await _request(
      '/enterprise/admin/apps?q=${Uri.encodeQueryComponent(query)}',
    );
    if (request != _appsRequest) return;
    apps = _list(result['apps']);
    _notify();
  }

  Future<Json> readApp(String id) async {
    final items = _list((await _request('/enterprise/admin/apps'))['apps']);
    return items.firstWhere(
      (app) => app['id'] == id,
      orElse: () => throw OfficeException(404, '企业应用已不存在'),
    );
  }

  Future<void> configureApp(Json app, Json changes) async {
    final result = await _request(
      '/enterprise/admin/apps/${Uri.encodeComponent('${app['id']}')}',
      method: 'PATCH',
      data: {...changes, 'base_revision': (app['policy'] as Map?)?['revision']},
    );
    final saved = Json.from(result['app']);
    apps = apps
        .map((item) => item['id'] == saved['id'] ? saved : item)
        .toList();
    _notify();
  }

  Future<Json> roleMembers(String role) => _request(
    '/enterprise/admin/members?role=${Uri.encodeQueryComponent(role)}&page=1&page_size=25',
  );
  Future<void> _refreshAfterWrite() async {
    try {
      await _updated();
    } catch (_) {
      if (current) {
        error = '变更已保存，列表刷新暂未完成。请刷新企业信息。';
        _notify();
      }
    }
  }

  Future<void> _updated() async {
    _applySummary(await _request('/enterprise/admin/overview'));
    await Future.wait([
      loadMembers(),
      loadDepartments(),
      if (can('manage_organizations')) loadOrganizations(),
      if (can('view_audit')) loadAudit(),
    ]);
    _notify();
  }

  Future<Json> createMember({
    required String name,
    required String kind,
    required String clientId,
    String? departmentId,
    String? organizationId,
    String profession = '',
    String jobTitle = '',
  }) async {
    final result = await _request(
      '/enterprise/admin/members',
      method: 'POST',
      data: {
        'name': name,
        'kind': kind,
        'client_id': clientId,
        'department_id': ?departmentId,
        'organization_id': ?organizationId,
        if (profession.isNotEmpty) 'profession': profession,
        if (jobTitle.isNotEmpty) 'job_title': jobTitle,
      },
    );
    // The one-time credential is returned directly to its creation dialog,
    // never retained in controller collections or diagnostic messages.
    await _refreshAfterWrite();
    return result;
  }

  Future<void> updateMember(Json member, Json changes) async {
    await _request(
      '/enterprise/admin/members/${Uri.encodeComponent('${member['principal_id'] ?? member['id']}')}',
      method: 'PATCH',
      data: {...changes, 'base_revision': member['revision']},
    );
    await _refreshAfterWrite();
  }

  Future<void> saveDepartment({
    Json? department,
    required String name,
    required String clientId,
    String? parentId,
  }) async {
    await _request(
      '/enterprise/admin/departments${department == null ? '' : '/${Uri.encodeComponent('${department['id']}')}'}',
      method: department == null ? 'POST' : 'PATCH',
      data: {
        'name': name,
        'parent_id': parentId,
        if (department == null) 'client_id': clientId,
        if (department != null) 'base_revision': department['revision'],
      },
    );
    await _refreshAfterWrite();
  }

  Future<void> deleteDepartment(Json department) async {
    await _request(
      '/enterprise/admin/departments/${Uri.encodeComponent('${department['id']}')}',
      method: 'DELETE',
      data: {'base_revision': department['revision']},
    );
    await _refreshAfterWrite();
  }

  Future<void> saveProfile(String name) async {
    final result = await _request(
      '/enterprise/admin/profile',
      method: 'PATCH',
      data: {'base_revision': enterprise['revision'], 'name': name},
    );
    enterprise = Json.from(result['enterprise']);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _memberRequest++;
    _auditRequest++;
    _appsRequest++;
    super.dispose();
  }
}
