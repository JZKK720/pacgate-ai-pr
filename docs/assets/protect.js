(function () {
  function isProtectedTarget(target) {
    return Boolean(
      target &&
      (target.closest('img, svg, canvas, video, .mxgraph, .viewer-wrap') ||
        target instanceof HTMLImageElement ||
        target instanceof HTMLCanvasElement ||
        target instanceof SVGElement)
    );
  }

  function blockEvent(event) {
    event.preventDefault();
    event.stopPropagation();
  }

  document.documentElement.classList.add('pg-view-only');

  document.addEventListener(
    'contextmenu',
    function (event) {
      blockEvent(event);
    },
    true
  );

  document.addEventListener(
    'dragstart',
    function (event) {
      if (isProtectedTarget(event.target)) {
        blockEvent(event);
      }
    },
    true
  );

  document.addEventListener(
    'keydown',
    function (event) {
      if (!(event.ctrlKey || event.metaKey)) {
        return;
      }

      var key = event.key.toLowerCase();
      if (key === 's' || key === 'p' || key === 'u') {
        blockEvent(event);
      }
    },
    true
  );

  var style = document.createElement('style');
  style.textContent = [
    '.pg-view-only img,',
    '.pg-view-only svg,',
    '.pg-view-only canvas {',
    '  -webkit-user-drag: none;',
    '  user-select: none;',
    '}',
    '.pg-view-only .mxgraph,',
    '.pg-view-only .viewer-wrap {',
    '  -webkit-user-select: none;',
    '  user-select: none;',
    '}'
  ].join('\n');
  document.head.appendChild(style);
})();