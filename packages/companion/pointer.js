'use strict';

// Installed only in the isolated page. It never moves the operating-system mouse.
function installPointer() {
  const markerId = '__active_companion_pointer__';
  const create = () => {
    if (!document.documentElement || document.getElementById(markerId)) return;
    const host = document.createElement('div');
    host.id = markerId;
    host.setAttribute('aria-hidden', 'true');
    host.style.cssText = 'position:fixed;left:0;top:0;z-index:2147483647;pointer-events:none;transform:translate(-80px,-80px);transition:transform 180ms ease-out;';
    const shadow = host.attachShadow({mode: 'closed'});
    shadow.innerHTML = '<style>@keyframes pulse{0%{box-shadow:0 0 0 0 #8952ff80}100%{box-shadow:0 0 0 15px #8952ff00}}.dot{width:18px;height:18px;border:2px solid white;border-radius:50%;background:#8952ff;animation:pulse 900ms infinite}.label{position:absolute;left:22px;top:12px;white-space:nowrap;font:12px sans-serif;color:white;background:#7542d3;border-radius:6px;padding:4px 7px}</style><div class="dot"></div><div class="label">机伴</div>';
    document.documentElement.append(host);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', create, {once: true});
  else create();
}

module.exports = {installPointer};
