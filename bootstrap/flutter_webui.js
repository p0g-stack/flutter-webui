/* flutter-webui page glue, loaded before flutter_bootstrap.js.
 * ES5 on purpose: it must run in WebViews too old for Flutter, to say so.
 * SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception */
(function () {
  'use strict';

  function removeSplash() {
    var splash = document.getElementById('flutter-webui-splash');
    if (splash) splash.parentNode.removeChild(splash);
  }

  // Shown instead of a blank page when Flutter cannot start.
  window.flutterWebUiFail = function (reason) {
    removeSplash();
    var box = document.getElementById('flutter-webui-error');
    if (!box) {
      box = document.createElement('div');
      box.id = 'flutter-webui-error';
      document.body.appendChild(box);
    }
    box.textContent = 'This page could not start.\n\n' + reason;
  };

  // Flutter web needs WebAssembly (CanvasKit or Skwasm); the HTML renderer is gone.
  if (typeof WebAssembly !== 'object') {
    window.flutterWebUiNoFlutter = true;
    document.addEventListener('DOMContentLoaded', function () {
      window.flutterWebUiFail('This WebView has no WebAssembly. Update Android System WebView.');
    });
    return;
  }

  // Edge-to-edge before the engine starts: turning it on later (from the
  // flutter_webui plugin) resizes the WebView mid-start, which recreates the
  // canvas. KernelSU names it enableEdgeToEdge, Next and APatch enableInsets.
  var ksu = window.ksu;
  try {
    if (ksu && typeof ksu.enableEdgeToEdge === 'function') ksu.enableEdgeToEdge(true);
    else if (ksu && typeof ksu.enableInsets === 'function') ksu.enableInsets(true);
  } catch (e) { /* the plugin tries again */ }

  window.addEventListener('flutter-first-frame', function () {
    if (window.performance && performance.mark) performance.mark('flutter_webui:first-frame');
    removeSplash();
  });
})();
