/// MaggioFlix Live: avanzamento dei download in tempo reale dal ponte sul
/// server (server/maggioflix-live), che legge qBittorrent ogni secondo.
///
/// L'app lo interroga solo mentre una pagina che lo mostra è aperta e l'app è
/// in primo piano. Se il ponte non risponde, restano i dati di Seerr.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../i18n/strings.g.dart';
import '../maggioflix_config.dart';
import '../media/media_kind.dart';
import '../services/catalog/seerr_catalog_source.dart';
import '../utils/app_logger.dart';

bool get _isItalian => LocaleSettings.currentLocale.languageCode == 'it';

String _tr(String it, String en) => _isItalian ? it : en;

int? _int(Object? v) => v is num ? v.toInt() : null;

/// Download in corso per un titolo (somma dei suoi torrent).
class MfLiveItem {
  final MediaKind kind;
  final int? tmdbId;
  final int? tvdbId;
  final bool is4k;
  final double progress;
  final int size;
  final int left;
  final int speed;
  final int? eta;

  /// downloading, metadata, checking, queued, stalled, paused, error, importing
  final String state;
  final int seeds;
  final int peers;
  final int count;
  final List<int> seasons;
  final int episodes;
  final DateTime receivedAt;

  const MfLiveItem({
    required this.kind,
    required this.tmdbId,
    required this.tvdbId,
    required this.is4k,
    required this.progress,
    required this.size,
    required this.left,
    required this.speed,
    required this.eta,
    required this.state,
    required this.seeds,
    required this.peers,
    required this.count,
    required this.seasons,
    required this.episodes,
    required this.receivedAt,
  });

  bool get isDownloading => state == 'downloading';
  bool get isImporting => state == 'importing';

  /// Avanzamento stimato adesso, tra un aggiornamento e l'altro.
  double progressAt(DateTime now) {
    if (!isDownloading || speed <= 0 || size <= 0) return progress.clamp(0.0, 1.0).toDouble();
    final elapsed = now.difference(receivedAt).inMilliseconds / 1000.0;
    final leftNow = math.max(left - speed * elapsed, size * 0.001);
    return (1 - leftNow / size).clamp(0.0, 1.0).toDouble();
  }

  Duration? remainingAt(DateTime now) {
    final e = eta;
    if (e == null || !isDownloading) return null;
    final r = e - now.difference(receivedAt).inSeconds;
    return Duration(seconds: r < 0 ? 0 : r);
  }

  /// Stato a parole quando non sta scaricando.
  String get stateLabel => switch (state) {
    'downloading' => _tr('In download', 'Downloading'),
    'metadata' => _tr('Recupero informazioni', 'Fetching metadata'),
    'checking' => _tr('In verifica', 'Checking'),
    'queued' => _tr('In coda', 'Queued'),
    'stalled' => _tr('In cerca di fonti', 'Looking for peers'),
    'paused' => _tr('In pausa', 'Paused'),
    'error' => _tr('Errore del download', 'Download error'),
    'importing' => _tr('Scaricato, in importazione', 'Downloaded, importing'),
    _ => '',
  };

  static MfLiveItem? fromJson(Object? json, DateTime receivedAt) {
    if (json is! Map) return null;
    final type = json['type'];
    if (type != 'movie' && type != 'tv') return null;
    final seasons = json['seasons'];
    return MfLiveItem(
      kind: type == 'movie' ? MediaKind.movie : MediaKind.show,
      tmdbId: _int(json['tmdbId']),
      tvdbId: _int(json['tvdbId']),
      is4k: json['is4k'] == true,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      size: _int(json['size']) ?? 0,
      left: _int(json['left']) ?? 0,
      speed: _int(json['speed']) ?? 0,
      eta: _int(json['eta']),
      state: json['state'] is String ? json['state'] as String : 'downloading',
      seeds: _int(json['seeds']) ?? 0,
      peers: _int(json['peers']) ?? 0,
      count: _int(json['count']) ?? 1,
      seasons: seasons is List ? seasons.whereType<num>().map((e) => e.toInt()).toList() : const [],
      episodes: _int(json['episodes']) ?? 0,
      receivedAt: receivedAt,
    );
  }
}

class MaggioflixLive extends ChangeNotifier with WidgetsBindingObserver {
  MaggioflixLive._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final MaggioflixLive instance = MaggioflixLive._();

  final http.Client _http = http.Client();
  final Map<String, MfLiveItem> _byTmdb = {};
  final Map<String, MfLiveItem> _byTvdb = {};
  SeerrCatalogSource? _source;
  Timer? _timer;
  int _watchers = 0;
  int _failures = 0;
  bool _inFlight = false;
  bool _foreground = true;

  /// Il ponte ha risposto all'ultima lettura.
  bool reachable = false;

  bool get enabled => maggioflixLiveUrl.isNotEmpty;

  /// Accende gli aggiornamenti; vanno avanti finché non si chiama la funzione
  /// restituita (una per ogni pagina che li mostra).
  /// Sessione Seerr da usare (cambia col profilo o dopo un nuovo accesso).
  void updateSource(SeerrCatalogSource? source) {
    if (source != null) _source = source;
  }

  VoidCallback watch(SeerrCatalogSource? source) {
    updateSource(source);
    _watchers++;
    if (_watchers == 1) _schedule(Duration.zero);
    var released = false;
    return () {
      if (released) return;
      released = true;
      _watchers = math.max(0, _watchers - 1);
      if (_watchers == 0) {
        _timer?.cancel();
        _timer = null;
      }
    };
  }

  MfLiveItem? itemFor(MediaKind kind, {int? tmdbId, int? tvdbId, bool is4k = false}) {
    final type = kind == MediaKind.movie ? 'movie' : 'tv';
    if (tmdbId != null) {
      final item = _byTmdb['$type:$tmdbId:$is4k'];
      if (item != null) return item;
    }
    if (tvdbId != null) return _byTvdb['$type:$tvdbId:$is4k'];
    return null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _schedule(Duration.zero);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = null;
    if (_watchers == 0 || !_foreground || !enabled) return;
    _timer = Timer(delay, () => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (_inFlight) return;
    final cookie = _source?.client.session.cookie;
    if (cookie == null || cookie.isEmpty) {
      _schedule(const Duration(seconds: 5));
      return;
    }
    _inFlight = true;
    var next = const Duration(seconds: 2);
    try {
      final resp = await _http
          .get(
            Uri.parse('$maggioflixLiveUrl/api/live'),
            headers: {'X-Seerr-Session': cookie, 'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) throw StateError('HTTP ${resp.statusCode}');
      final decoded = jsonDecode(resp.body);
      final items = decoded is Map ? decoded['items'] : null;
      final now = DateTime.now();
      _byTmdb.clear();
      _byTvdb.clear();
      if (items is List) {
        for (final raw in items) {
          final item = MfLiveItem.fromJson(raw, now);
          if (item == null) continue;
          final type = item.kind == MediaKind.movie ? 'movie' : 'tv';
          if (item.tmdbId != null) _byTmdb['$type:${item.tmdbId}:${item.is4k}'] = item;
          if (item.tvdbId != null) _byTvdb['$type:${item.tvdbId}:${item.is4k}'] = item;
        }
      }
      if (!reachable) appLogger.i('MaggioFlix Live collegato');
      reachable = true;
      _failures = 0;
      next = _byTmdb.isEmpty && _byTvdb.isEmpty ? const Duration(seconds: 4) : const Duration(milliseconds: 1500);
      notifyListeners();
    } catch (e) {
      _failures++;
      if (reachable || _failures == 1) appLogger.w('MaggioFlix Live non raggiungibile', error: e);
      if (reachable || _byTmdb.isNotEmpty || _byTvdb.isNotEmpty) {
        reachable = false;
        _byTmdb.clear();
        _byTvdb.clear();
        notifyListeners();
      }
      next = Duration(seconds: math.min(60, 5 * _failures));
    } finally {
      _inFlight = false;
      _schedule(next);
    }
  }
}
