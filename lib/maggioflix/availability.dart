import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../maggioflix_config.dart';
import '../models/seerr/seerr_session.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/seerr_account_provider.dart';
import '../services/deep_links/deep_link_service.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/notification_permission.dart';
import '../utils/platform_detector.dart';
import '../widgets/dialog_action_button.dart';
import 'live.dart';
import 'requests.dart';

bool get _isItalian => LocaleSettings.currentLocale.languageCode == 'it';

String _tr(String it, String en) => _isItalian ? it : en;

/// One title that became available, as the Android side queued it.
class MfAvailableItem {
  final int tmdbId;
  final String kind; // 'movie' | 'show'
  final String title;
  final String heading;
  final String text;
  final String? posterUrl;

  const MfAvailableItem({
    required this.tmdbId,
    required this.kind,
    required this.title,
    required this.heading,
    required this.text,
    this.posterUrl,
  });

  String get playLink => 'maggioflix://play?type=$kind&tmdb=$tmdbId';

  static MfAvailableItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final tmdb = json['tmdbId'];
    final kind = json['kind'];
    final title = json['title'];
    if (tmdb is! num || kind is! String || title is! String) return null;
    return MfAvailableItem(
      tmdbId: tmdb.toInt(),
      kind: kind,
      title: title,
      heading: json['heading'] is String ? json['heading'] as String : title,
      text: json['text'] is String ? json['text'] as String : '',
      posterUrl: json['posterUrl'] is String ? json['posterUrl'] as String : null,
    );
  }
}

/// Bridge to the Android "È disponibile" checker (MaggioflixAvailability.kt).
abstract final class MaggioflixAvailability {
  static const _channel = MethodChannel('com.maggioflix/availability');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Hands the Seerr session to Android, which then checks every ~15 minutes.
  /// A null session stops the background checks.
  static Future<void> configure(SeerrSession? session) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('configure', {
        'baseUrl': session?.baseUrl,
        'cookie': session?.cookie,
        'userId': session?.userId,
        'liveUrl': maggioflixLiveUrl,
      });
    } catch (e) {
      appLogger.w('MaggioFlix: availability configure failed', error: e);
    }
  }

  /// Checks now; titles found are notified by Android and queued for [takePending].
  static Future<void> check() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<int>('check');
    } catch (e) {
      appLogger.w('MaggioFlix: availability check failed', error: e);
    }
  }

  /// Titles found since the last call, oldest first.
  static Future<List<MfAvailableItem>> takePending() async {
    if (!supported) return const [];
    try {
      final raw = await _channel.invokeMethod<String>('takePending');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map(MfAvailableItem.fromJson).whereType<MfAvailableItem>().toList();
    } catch (e) {
      appLogger.w('MaggioFlix: availability queue read failed', error: e);
      return const [];
    }
  }

  /// After a request: check every 2 minutes for a while, so the notification
  /// arrives as soon as the title is on the server.
  static Future<void> requestMade() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('requestMade');
    } catch (e) {
      appLogger.w('MaggioFlix: availability fast mode failed', error: e);
    }
  }

  /// Asks for the notification permission (Android 13+) the first time it matters:
  /// right after the user sends a request.
  static Future<void> ensurePermission() async {
    if (!supported) return;
    await NotificationPermission.ensure();
  }
}

/// Keeps the Android checker in sync with the Seerr session of the active profile, checks when the
/// app starts or comes back to the foreground and, on TV (where system notifications are easy to
/// miss), shows what arrived in a dialog with "Guarda ora".
class MaggioflixAvailabilityController {
  MaggioflixAvailabilityController(this._state);

  final State _state;
  SeerrAccountProvider? _seerr;
  CatalogSourcesProvider? _sources;
  VoidCallback? _releaseLive;
  String? _configuredKey;
  bool _checking = false;
  bool _disposed = false;

  void start() {
    if (!MaggioflixAvailability.supported || !_state.mounted) return;
    _seerr = _state.context.read<SeerrAccountProvider?>();
    _seerr?.addListener(_onSeerrChanged);
    _sources = _state.context.read<CatalogSourcesProvider?>();
    _sources?.addListener(_onSourcesChanged);
    MaggioflixLive.instance.addListener(_onLive);
    // Con l'app aperta il ponte si legge sempre: la notifica parte nel
    // momento in cui il titolo compare su Plex, come nell'app di Plex.
    _releaseLive = MaggioflixLive.instance.watch(_sources?.seerrSource);
    _onSeerrChanged();
  }

  void dispose() {
    _disposed = true;
    _seerr?.removeListener(_onSeerrChanged);
    _sources?.removeListener(_onSourcesChanged);
    MaggioflixLive.instance.removeListener(_onLive);
    _releaseLive?.call();
  }

  void _onSourcesChanged() => MaggioflixLive.instance.updateSource(_sources?.seerrSource);

  /// Con l'app aperta: appena il ponte vede un titolo arrivato su Plex,
  /// si controlla subito (la notifica parte senza aspettare Seerr).
  Set<String> _lastArrivals = const {};

  void _onLive() {
    final arrivals = MaggioflixLive.instance.arrivals;
    final grew = arrivals.any((a) => !_lastArrivals.contains(a));
    _lastArrivals = arrivals;
    if (grew) unawaited(_check());
  }

  void onResume() => unawaited(_check());

  void _onSeerrChanged() {
    if (_disposed) return;
    final session = _seerr?.session;
    final key = session == null ? null : '${session.baseUrl}|${session.userId}|${session.cookie}';
    if (key == _configuredKey) return;
    _configuredKey = key;
    unawaited(() async {
      await MaggioflixAvailability.configure(session);
      if (session != null) await _check();
    }());
  }

  Future<void> _check() async {
    if (_disposed || _checking || _seerr?.session == null) return;
    _checking = true;
    try {
      await MaggioflixAvailability.check();
      final items = await MaggioflixAvailability.takePending();
      if (items.isEmpty) return;
      // The pages that show request status refresh themselves.
      maggioflixRequestsChanged.value++;
      if (!PlatformDetector.isTV() || _disposed || !_state.mounted) return;
      await _showTvNotice(_state.context, items);
    } finally {
      _checking = false;
    }
  }
}

Future<void> _showTvNotice(BuildContext context, List<MfAvailableItem> items) async {
  final latest = items.reversed.take(3).toList();
  final single = latest.length == 1 ? latest.first : null;
  final action = await showScopedDialog<String>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        title: Text(
          single != null
              ? single.heading
              : _tr('Sono arrivati ${items.length} titoli che hai richiesto', '${items.length} of your requests arrived'),
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in latest)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 56,
                          height: 84,
                          child: item.posterUrl == null
                              ? ColoredBox(color: theme.colorScheme.surfaceContainerHighest)
                              : Image.network(
                                  item.posterUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                                ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.title, style: theme.textTheme.titleMedium),
                            const SizedBox(height: 4),
                            Text(item.text, style: theme.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          DialogActionButton(
            onPressed: () => Navigator.pop(dialogContext, 'close'),
            label: _tr('Chiudi', 'Close'),
          ),
          DialogActionButton(
            autofocus: single == null,
            isPrimary: single == null,
            onPressed: () => Navigator.pop(dialogContext, 'requests'),
            label: maggioflixMyRequestsLabel(),
          ),
          if (single != null)
            DialogActionButton(
              autofocus: true,
              isPrimary: true,
              onPressed: () => Navigator.pop(dialogContext, 'play'),
              label: _tr('Guarda ora', 'Watch now'),
            ),
        ],
      );
    },
  );
  if (!context.mounted) return;
  switch (action) {
    case 'play':
      DeepLinkService.instance.receive(single!.playLink);
    case 'requests':
      openMaggioflixRequests(context);
  }
}
