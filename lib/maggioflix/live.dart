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

  /// downloading, metadata, checking, queued, stalled, paused, error,
  /// importing (scaricato, Radarr/Sonarr lo stanno spostando), imported (sul
  /// server, Plex non l'ha ancora aggiunto), available (già nell'app)
  final String state;

  /// Quando Radarr/Sonarr l'hanno importato (solo per [isImported]).
  final DateTime? importedAt;
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
    this.importedAt,
  });

  bool get isDownloading => state == 'downloading';
  bool get isImporting => state == 'importing';
  bool get isImported => state == 'imported';

  /// Già su Plex, quindi guardabile nell'app.
  bool get isOnPlex => state == 'available';

  /// Download ancora in corso (non ancora sul server).
  bool get isActive => !isImported && !isOnPlex;

  MfLiveItem withProgress(double value) => MfLiveItem(
    kind: kind,
    tmdbId: tmdbId,
    tvdbId: tvdbId,
    is4k: is4k,
    progress: value,
    size: size,
    left: left,
    speed: speed,
    eta: eta,
    state: state,
    seeds: seeds,
    peers: peers,
    count: count,
    seasons: seasons,
    episodes: episodes,
    receivedAt: receivedAt,
    importedAt: importedAt,
  );

  /// Avanzamento: il dato di qBittorrent, senza stime (arriva ogni secondo).
  double progressAt(DateTime now) => progress.clamp(0.0, 1.0).toDouble();

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
    'importing' => _tr('Importazione', 'Importing'),
    'imported' => _tr('Importazione', 'Importing'),
    'available' => _tr('Disponibile', 'Available'),
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
      importedAt: _int(json['importedAt']) == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(_int(json['importedAt'])!),
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

  /// TMDB -> TVDB delle serie: Sonarr conosce le serie per TVDB, l'app spesso
  /// solo per TMDB (ricerca, poster). Si impara da Seerr e dal ponte.
  final Map<int, int> _tvdbOf = {};
  SeerrCatalogSource? _source;
  Timer? _timer;
  int _watchers = 0;
  int _failures = 0;
  bool _inFlight = false;
  bool _foreground = true;
  DateTime? _lastSuccess;

  /// Ultima percentuale mostrata per titolo: piccoli passi indietro (un
  /// torrent rifatto, un arrotondamento) non si vedono.
  final Map<String, double> _shown = {};

  /// Il ponte ha risposto all'ultima lettura.
  bool reachable = false;

  bool get enabled => maggioflixLiveUrl.isNotEmpty;

  /// Quanti titoli risultano appena arrivati sul server o su Plex.
  int get importedCount => {..._byTmdb.values, ..._byTvdb.values}.where((i) => !i.isActive).length;

  /// Il ponte legge Plex: "disponibile" arriva da lì, non da Seerr.
  bool plexConnected = false;

  /// Titoli appena comparsi nell'app (su Plex o, senza Plex, sul server).
  Set<String> get arrivals => {
    for (final i in {..._byTmdb.values, ..._byTvdb.values})
      if (i.isOnPlex || (!plexConnected && i.isImported))
        '${i.kind.name}:${i.tmdbId ?? 'tvdb${i.tvdbId}'}:${i.is4k}:${i.state}',
  };

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

  /// Collega TMDB e TVDB di una serie, così la si ritrova anche se il ponte ne conosce solo uno.
  void rememberIds(int? tmdbId, int? tvdbId) {
    if (tmdbId != null && tmdbId > 0 && tvdbId != null && tvdbId > 0) _tvdbOf[tmdbId] = tvdbId;
  }

  MfLiveItem? itemFor(MediaKind kind, {int? tmdbId, int? tvdbId, bool is4k = false}) {
    final type = kind == MediaKind.movie ? 'movie' : 'tv';
    if (tmdbId != null) {
      final item = _byTmdb['$type:$tmdbId:$is4k'];
      if (item != null) return item;
    }
    if (kind != MediaKind.movie) tvdbId ??= tmdbId == null ? null : _tvdbOf[tmdbId];
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
      plexConnected = decoded is Map && decoded['plex'] == true;
      final now = DateTime.now();
      _byTmdb.clear();
      _byTvdb.clear();
      final shown = <String, double>{};
      if (items is List) {
        for (final raw in items) {
          var item = MfLiveItem.fromJson(raw, now);
          if (item == null) continue;
          final type = item.kind == MediaKind.movie ? 'movie' : 'tv';
          final key = '$type:${item.tmdbId ?? 'tvdb${item.tvdbId}'}:${item.is4k}';
          final before = _shown[key];
          if (item.isActive && before != null && item.progress < before && before - item.progress < 0.05) {
            item = item.withProgress(before);
          }
          if (item.isActive) shown[key] = item.progress;
          if (item.kind != MediaKind.movie) rememberIds(item.tmdbId, item.tvdbId);
          if (item.tmdbId != null) _byTmdb['$type:${item.tmdbId}:${item.is4k}'] = item;
          if (item.tvdbId != null) _byTvdb['$type:${item.tvdbId}:${item.is4k}'] = item;
        }
      }
      _shown
        ..clear()
        ..addAll(shown);
      if (!reachable) appLogger.i('MaggioFlix Live collegato');
      reachable = true;
      _failures = 0;
      _lastSuccess = now;
      next = _byTmdb.isEmpty && _byTvdb.isEmpty ? const Duration(seconds: 3) : const Duration(seconds: 1);
      notifyListeners();
    } catch (e) {
      _failures++;
      if (_failures == 3) appLogger.w('MaggioFlix Live non raggiungibile', error: e);
      // Un intoppo di rete non deve far sparire il download: si tengono gli
      // ultimi dati per 20 s, poi si torna a quelli di Seerr.
      final last = _lastSuccess;
      final stale = last == null || DateTime.now().difference(last) > const Duration(seconds: 20);
      if (stale && (reachable || _byTmdb.isNotEmpty || _byTvdb.isNotEmpty)) {
        reachable = false;
        _byTmdb.clear();
        _byTvdb.clear();
        notifyListeners();
      }
      next = stale ? Duration(seconds: math.min(60, 5 * _failures)) : const Duration(seconds: 2);
    } finally {
      _inFlight = false;
      _schedule(next);
    }
  }
}

/// Legge dal ponte altri dati del server (calendario, stagioni) con la sessione Seerr.
Future<Object?> maggioflixBridgeGet(SeerrCatalogSource source, String pathAndQuery) async {
  if (maggioflixLiveUrl.isEmpty) return null;
  final cookie = source.client.session.cookie;
  if (cookie.isEmpty) return null;
  final resp = await MaggioflixLive.instance._http
      .get(
        Uri.parse('$maggioflixLiveUrl$pathAndQuery'),
        headers: {'X-Seerr-Session': cookie, 'Accept': 'application/json'},
      )
      .timeout(const Duration(seconds: 25));
  if (resp.statusCode != 200) throw StateError('HTTP ${resp.statusCode}');
  return jsonDecode(resp.body);
}
