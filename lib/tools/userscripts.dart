/// 用户脚本层（类油猴）：按域名注入 JS，解锁登录弹窗/复制限制。
///
/// 内置常用脚本，未来可让用户添加。每个脚本是注入到页面的 JS 字符串。
library;

/// 单个用户脚本。
class UserScript {
  final String name;
  final String js;
  const UserScript({required this.name, required this.js});
}

/// 内置用户脚本（按域名分组）。
///
/// 通用：去登录遮罩 + 解除复制限制 + 允许选中。
const Map<String, List<UserScript>> builtinUserScripts = {
  'zhihu.com': [
    UserScript(
      name: '知乎去登录弹窗',
      js: '''
(function(){
  // 移除登录遮罩和弹窗。
  var clean = function(){
    document.querySelectorAll('.Modal-wrapper, .Modal-backdrop, .LoginModal, .signFlowModal').forEach(function(el){ el.remove(); });
    document.body.style.overflow = 'auto';
  };
  clean();
  var observer = new MutationObserver(clean);
  observer.observe(document.body, {childList: true, subtree: true});
  setTimeout(clean, 1500);
})();
''',
    ),
  ],
  'xiaohongshu.com': [
    UserScript(
      name: '小红书去登录遮罩',
      js: '''
(function(){
  var clean = function(){
    document.querySelectorAll('.login-container, .login-modal, .xhs-close, [class*="login"]').forEach(function(el){ if(el.offsetParent !== null) el.style.display='none'; });
    document.body.style.overflow = 'auto';
  };
  clean();
  setTimeout(clean, 1500);
})();
''',
    ),
  ],
  'tieba.baidu.com': [
    UserScript(
      name: '贴吧展开正文',
      js: '''
(function(){
  // 展开折叠的内容。
  document.querySelectorAll('.d_post_content, .p_content').forEach(function(el){ el.style.maxHeight='none'; el.style.overflow='visible'; });
})();
''',
    ),
  ],
};

/// 通用脚本：解除复制限制 + 允许选中。
const String _genericUnlockCopy = '''
(function(){
  document.addEventListener('copy', function(e){ e.stopPropagation(); }, true);
  document.addEventListener('selectstart', function(e){ e.stopPropagation(); }, true);
  var styles = document.createElement('style');
  styles.textContent = 'body, * { -webkit-user-select: text !important; user-select: text !important; }';
  document.head.appendChild(styles);
})();
''';

/// 获取某域名的用户脚本列表（内置 + 通用复制解锁）。
List<UserScript> userScriptsForHost(String host) {
  final result = <UserScript>[
    const UserScript(name: '通用复制解锁', js: _genericUnlockCopy),
  ];
  // 匹配域名（含子域名）。
  for (final entry in builtinUserScripts.entries) {
    if (host == entry.key || host.endsWith('.${entry.key}')) {
      result.addAll(entry.value);
    }
  }
  return result;
}

/// 域名的白名单（私域 + 开放站）。不在名单的 URL 抓取被拒绝。
/// 防刷核心：抖音/快手/B站等视频平台默认不在名单。
const Set<String> allowlistHosts = {
  // 私域（用户指定的三大平台）。
  'zhihu.com',
  'xiaohongshu.com',
  'tieba.baidu.com',
  'baidu.com',
  // 开放站。
  'github.com',
  'gitee.com',
  'wikipedia.org',
  'zh.wikipedia.org',
  'developer.mozilla.org',
  'stackoverflow.com',
  'medium.com',
  'csdn.net',
  'juejin.cn',
  'cnblogs.com',
  'segmentfault.com',
  'infoq.cn',
  'dart.dev',
  'flutter.dev',
  'api.flutter.dev',
  'pub.dev',
};

/// 是否允许抓取某 URL（白名单域名 + http/https）。
bool isAllowedUrl(String url) {
  try {
    final uri = Uri.parse(url);
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return false;
    }
    final host = uri.host.toLowerCase();
    for (final allowed in allowlistHosts) {
      if (host == allowed || host.endsWith('.$allowed')) {
        return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}
