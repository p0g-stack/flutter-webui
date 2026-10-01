/* flutter-webui loader configuration. `flutter build web` fills the two
 * placeholders. SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception */
{{flutter_js}}
{{flutter_build_config}}

if (!window.flutterWebUiNoFlutter) {
  _flutter.loader.load({
    config: {
      // No COOP/COEP on any manager: Skwasm can only run single-threaded.
      forceSingleThreadedSkwasm: true,
      // Never reach for gstatic (WebUI X's CSP blocks it; pages may be offline).
      fontFallbackBaseUrl: 'fonts/',
    },
  }).catch(function (error) {
    window.flutterWebUiFail(String(error));
  });
}
