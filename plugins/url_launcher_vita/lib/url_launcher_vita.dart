import 'package:flutter/services.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// The Vita implementation of [UrlLauncherPlatform].
///
/// **Non-endorsed**, per [ADR-0009]: `url_launcher` does not know Vita exists,
/// so an app depends on this package alongside it and calls
/// `UrlLauncherVita.registerWith()`.
///
/// ## Every URL leaves the app
///
/// The console has one browser and it is a separate application.
/// `sceAppUtilLaunchWebBrowser` hands it a URL and switches to it; this app
/// stays resident and is returned to when the browser closes. There is no
/// in-app browser to offer instead — a webview needs a browser engine
/// rendering into our frame, and this port has neither one nor room for one.
///
/// So [launchUrl]'s `LaunchMode` is not honoured, and cannot be:
/// `inAppWebView` and `externalApplication` do the same thing here. That is
/// reported rather than hidden — see [supportsMode].
class UrlLauncherVita extends UrlLauncherPlatform {
  static void registerWith() {
    UrlLauncherPlatform.instance = UrlLauncherVita();
  }

  /// JSON rather than the standard codec on purpose: the embedder parses this
  /// by hand in C, and `StandardMethodCodec` is a binary format nobody should
  /// hand-encode twice. `flutter/textinput` made the same choice for the same
  /// reason.
  static const _channel = MethodChannel('vita/browser', JSONMethodCodec());

  @override
  final LinkDelegate? linkDelegate = null;

  @override
  Future<bool> canLaunch(String url) async {
    // Only schemes the system browser understands. Answering true for `tel:`
    // or `mailto:` would send them to a browser that cannot act on them, and
    // the caller would see a success for something that visibly did nothing.
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    final ok = await _channel.invokeMethod<bool>('canLaunch');
    return ok ?? false;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    if (!await canLaunch(url)) return false;
    final ok = await _channel.invokeMethod<bool>('launch', {'url': url});
    return ok ?? false;
  }

  /// Only the mode we can actually provide.
  ///
  /// Claiming `inAppWebView` would make callers that check first believe an
  /// embedded browser is coming, and then get a full application switch. A
  /// caller that asks and is told no can offer a link instead; a caller that is
  /// misled cannot.
  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async =>
      mode == PreferredLaunchMode.externalApplication ||
      mode == PreferredLaunchMode.platformDefault;

  @override
  Future<bool> supportsCloseForMode(PreferredLaunchMode mode) async => false;
}
