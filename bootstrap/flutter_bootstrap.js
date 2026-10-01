/* flutter-webui loader configuration. `flutter build web` fills the two
 * placeholders. SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception */
{{flutter_js}}
{{flutter_build_config}}

if (!window.flutterWebUiNoFlutter) {
  // Set by dev.html: the app's files come from this dev server, the page stays
  // on the manager's origin.
  var flutterWebUiBase = window.flutterWebUiDevServer || '';
  var flutterWebUiConfig = {
    // No COOP/COEP on any manager: Skwasm can only run single-threaded.
    forceSingleThreadedSkwasm: true,
    // Never reach for gstatic (WebUI X's CSP blocks it; pages may be offline):
    // the module's fonts/ (web_ui/tool/fallback_fonts.dart).
    fontFallbackBaseUrl: 'fonts/',
  };
  if (flutterWebUiBase) {
    flutterWebUiConfig.entrypointBaseUrl = flutterWebUiBase;
    flutterWebUiConfig.assetBase = flutterWebUiBase;
    flutterWebUiConfig.canvasKitBaseUrl = flutterWebUiBase + 'canvaskit/';
    // A dev module is only dev.html, so the dev server serves fonts/ too.
    flutterWebUiConfig.fontFallbackBaseUrl = flutterWebUiBase + 'fonts/';
  }
  _flutter.loader.load({
    config: flutterWebUiConfig,
  }).catch(function (error) {
    window.flutterWebUiFail(String(error));
  });
}
