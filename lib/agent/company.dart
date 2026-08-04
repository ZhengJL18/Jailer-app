/// 公司模式：自定义部门 + 主 agent（CEO）调度多层代理。
///
/// 每个部门有一组角色（子代理）+ 工具集 + 人设。CEO 按任务性质选择部门，
/// 部门内子代理分工执行或讨论，结果汇总给 CEO。
library;

/// 部门定义。
class AgentDepartment {
  final String id;
  final String name;
  final String description;
  final List<String> roles; // 部门内角色名（每个角色 = 一个子代理视角）。
  final List<String> toolsets; // 部门子代理可用工具。

  const AgentDepartment({
    required this.id,
    required this.name,
    required this.description,
    required this.roles,
    required this.toolsets,
  });
}

/// 预设部门（可按项目自定义，主 agent 根据任务性质选择）。
const List<AgentDepartment> presetDepartments = [
  AgentDepartment(
    id: 'code',
    name: '代码部',
    description: '写代码、重构、调试、代码审查',
    roles: ['架构师', '实现者', '审查者'],
    toolsets: ['file', 'git', 'web', 'delegate', 'moa'],
  ),
  AgentDepartment(
    id: 'research',
    name: '研究部',
    description: '调研、资料收集、分析、总结',
    roles: ['检索员', '分析师', '批评者'],
    toolsets: ['web', 'memory', 'delegate', 'moa'],
  ),
  AgentDepartment(
    id: 'office',
    name: '办公部',
    description: '写文档、整理资料、排版、校对',
    roles: ['文档员', '校对员', '排版员'],
    toolsets: ['file', 'web', 'delegate'],
  ),
];

/// 按 id 找部门。
AgentDepartment? findDepartment(String id) {
  for (final d in presetDepartments) {
    if (d.id == id) {
      return d;
    }
  }
  return null;
}

/// 部门列表描述（给 CEO 系统提示，让它知道有哪些部门可用）。
String departmentsSummary() {
  return presetDepartments
      .map((d) => '  - ${d.id}（${d.name}）：${d.description}，'
          '角色：${d.roles.join('/')}')
      .join('\n');
}
