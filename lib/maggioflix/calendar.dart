/// MaggioFlix: calendario delle uscite. Prossimi episodi delle serie che
/// l'utente guarda (su Plex) o ha richiesto, e date di uscita dei film
/// richiesti non ancora sul server. I dati vengono da Seerr (TMDB).
library;

import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/app_locale_utils.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/library_query.dart';
import '../media/media_library.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/catalog/seerr_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/catalog_navigation_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/seerr_request_sheet.dart';
import 'live.dart';
import 'requests.dart';

bool get _isItalian => LocaleSettings.currentLocale.languageCode == 'it';

String _tr(String it, String en) => _isItalian ? it : en;

String get _locale => LocaleSettings.currentLocale.intlLocaleName;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

String maggioflixCalendarLabel() => _tr('Calendario', 'Calendar');

/// Apre il calendario come pagina (TV e PC: dal menu laterale).
void openMaggioflixCalendar(BuildContext context) {
  unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MaggioflixCalendarScreen())));
}

enum MfCalendarKind { episode, premiere, movie }

class MfCalendarEntry {
  final DateTime day;
  final MfCalendarKind kind;
  final int tmdbId;
  final String title;
  final String detail;
  final String status;
  final Color? statusColor;
  final String? imageUrl;

  /// Stagione non ancora sul server né richiesta: si può richiedere da qui.
  final int? seasonToRequest;

  /// Viene da una richiesta dell'utente (altrimenti da ciò che guarda).
  final bool requested;

  /// Ora esatta (episodi: messa in onda), se nota.
  final DateTime? at;

  /// Già scaricato sul server.
  final bool onServer;

  final int? tvdbId;
  final String? posterUrl;

  const MfCalendarEntry({
    required this.day,
    required this.kind,
    required this.tmdbId,
    required this.title,
    required this.detail,
    required this.status,
    this.statusColor,
    this.imageUrl,
    this.seasonToRequest,
    this.requested = false,
    this.at,
    this.onServer = false,
    this.tvdbId,
    this.posterUrl,
  });

  bool get isMovie => kind == MfCalendarKind.movie;

  /// Colore del tipo: film ambra, serie azzurro.
  Color get color => isMovie ? mfAmber : mfCyan;
  MediaKind get mediaKind => isMovie ? MediaKind.movie : MediaKind.show;
}

/// Carica (e tiene in memoria per 10 minuti) le voci del calendario.
abstract final class MaggioflixCalendarLoader {
  static const _ttl = Duration(minutes: 10);
  static const _horizon = Duration(days: 42);
  static ({int userId, DateTime at, List<MfCalendarEntry> entries})? _cache;
  static Future<List<MfCalendarEntry>>? _inFlight;

  static Future<List<MfCalendarEntry>> load(BuildContext context, {bool force = false}) {
    final source = context.read<CatalogSourcesProvider>().seerrSource;
    if (source == null) return Future.error(StateError('Seerr non collegato'));
    final userId = source.client.session.userId;
    final cache = _cache;
    if (!force && cache != null && cache.userId == userId && DateTime.now().difference(cache.at) < _ttl) {
      return Future.value(cache.entries);
    }
    final pending = _inFlight;
    if (pending != null && !force) return pending;
    final libraries = context.read<LibrariesProvider>().libraries;
    final multiServer = context.read<MultiServerProvider>();
    final future = _load(source, libraries.where((l) => l.kind == MediaKind.show).toList(), multiServer).then((entries) {
      _cache = (userId: userId, at: DateTime.now(), entries: entries);
      return entries;
    });
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  static final Map<String, ({DateTime at, List<MfCalendarEntry> entries})> _rangeCache = {};

  /// Tutto ciò che esce tra [start] e [end]: dal server (Radarr/Sonarr tramite
  /// il ponte) più, da Seerr, le serie che guardi ma che il server non segue.
  static Future<List<MfCalendarEntry>> loadRange(
    BuildContext context,
    DateTime start,
    DateTime end, {
    bool force = false,
  }) async {
    final source = context.read<CatalogSourcesProvider>().seerrSource;
    if (source == null) throw StateError('Seerr non collegato');
    final key = '${source.client.session.userId}:${_ymd(start)}:${_ymd(end)}';
    final hit = _rangeCache[key];
    if (!force && hit != null && DateTime.now().difference(hit.at) < const Duration(minutes: 5)) return hit.entries;

    final seerrFuture = load(context, force: force).then<List<MfCalendarEntry>?>((e) => e).catchError((Object e) {
      appLogger.w('MaggioFlix: calendario Seerr non disponibile', error: e);
      return null;
    });
    List<MfCalendarEntry>? bridge;
    try {
      final json = await maggioflixBridgeGet(source, '/api/calendar?start=${_ymd(start)}&end=${_ymd(end)}');
      if (json != null) bridge = _fromBridge(json);
    } catch (e) {
      appLogger.w('MaggioFlix: calendario del server non disponibile', error: e);
    }
    final seerr = await seerrFuture;
    if (bridge == null && seerr == null) throw StateError('Calendario non disponibile');

    final merged = <MfCalendarEntry>[...?bridge];
    final known = <String>{
      for (final e in merged) ...[
        if (e.tmdbId > 0) '${e.isMovie}:${e.tmdbId}',
        '${e.isMovie}:${e.title.toLowerCase()}',
      ],
    };
    for (final e in seerr ?? const <MfCalendarEntry>[]) {
      if (e.day.isBefore(start) || e.day.isAfter(end)) continue;
      if (known.contains('${e.isMovie}:${e.tmdbId}') || known.contains('${e.isMovie}:${e.title.toLowerCase()}')) continue;
      merged.add(e);
    }
    merged.sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      if (byDay != 0) return byDay;
      final byTime = (a.at ?? a.day).compareTo(b.at ?? b.day);
      return byTime != 0 ? byTime : a.title.compareTo(b.title);
    });
    _rangeCache[key] = (at: DateTime.now(), entries: merged);
    return merged;
  }

  static List<MfCalendarEntry> _fromBridge(Object? json) {
    final items = json is Map ? json['items'] : null;
    if (items is! List) return const [];
    final now = DateTime.now();
    final today = _day(now);
    final timeFmt = DateFormat.Hm(_locale);
    final out = <MfCalendarEntry>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final title = (raw['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) continue;
      final onServer = raw['hasFile'] == true;
      final poster = raw['poster'] as String?;
      final fanart = raw['fanart'] as String?;
      if (raw['type'] == 'movie') {
        final date = DateTime.tryParse('${raw['date'] ?? ''}');
        if (date == null) continue;
        final day = _day(date);
        final release = raw['release'] as String? ?? 'digital';
        final String status;
        if (onServer) {
          status = _tr('Sul server', 'On the server');
        } else if (release == 'cinema') {
          status = _tr("Arriva dopo l'uscita in digitale", 'Arrives after the digital release');
        } else if (day.isAfter(today)) {
          status = _tr('Si scarica appena esce', 'Downloads as soon as it is out');
        } else {
          status = _tr('Uscito · in attesa del download', 'Out · waiting for download');
        }
        out.add(
          MfCalendarEntry(
            day: day,
            kind: MfCalendarKind.movie,
            tmdbId: _int(raw['tmdbId']) ?? 0,
            title: title,
            detail: switch (release) {
              'cinema' => _tr('Al cinema', 'In theaters'),
              'physical' => _tr('Uscita in Blu-ray', 'Physical release'),
              _ => _tr('Uscita digitale', 'Digital release'),
            },
            status: status,
            statusColor: onServer ? mfGreen : null,
            imageUrl: fanart,
            posterUrl: poster,
            onServer: onServer,
            requested: true,
          ),
        );
      } else {
        final at = DateTime.tryParse('${raw['airUtc'] ?? ''}')?.toLocal();
        final date = DateTime.tryParse('${raw['date'] ?? ''}');
        final day = at != null ? _day(at) : (date == null ? null : _day(date));
        if (day == null) continue;
        final season = _int(raw['season']) ?? 0;
        final episode = _int(raw['episode']) ?? 0;
        final name = (raw['episodeTitle'] as String?)?.trim() ?? '';
        final finale = raw['finale'] as String?;
        final premiere = episode == 1;
        final note = switch (finale) {
          'series' => _tr(' · finale di serie', ' · series finale'),
          'season' => _tr(' · finale di stagione', ' · season finale'),
          _ => premiere ? _tr(' · inizio stagione', ' · season premiere') : '',
        };
        final hideName = name.isEmpty || name == 'TBA' || name.toLowerCase().startsWith('episod');
        final aired = at != null && at.isBefore(now);
        final String status;
        if (onServer) {
          status = _tr('Sul server', 'On the server');
        } else if (aired) {
          status = _tr('Andato in onda · in arrivo sul server', 'Aired · coming to the server');
        } else if (at != null) {
          status = _tr('In onda alle ${timeFmt.format(at)}', 'Airs at ${timeFmt.format(at)}');
        } else {
          status = _tr('Arriva sul server dopo la messa in onda', 'Reaches the server after it airs');
        }
        out.add(
          MfCalendarEntry(
            day: day,
            kind: premiere ? MfCalendarKind.premiere : MfCalendarKind.episode,
            tmdbId: _int(raw['tmdbId']) ?? 0,
            tvdbId: _int(raw['tvdbId']),
            title: title,
            detail: 'S$season · E$episode$note${hideName ? '' : ' «$name»'}',
            status: status,
            statusColor: onServer ? mfGreen : null,
            imageUrl: fanart,
            posterUrl: poster,
            onServer: onServer,
            at: at,
            requested: true,
          ),
        );
      }
    }
    return out;
  }

  static Future<List<MfCalendarEntry>> _load(
    SeerrCatalogSource source,
    List<MediaLibrary> showLibraries,
    MultiServerProvider multiServer,
  ) async {
    final client = source.client;
    final today = _day(DateTime.now());
    final horizon = today.add(_horizon);

    // 1. Le richieste dell'utente.
    final movieIds = <int>{};
    final series = <int, bool>{}; // tmdb -> richiesta dall'utente
    final json = await client.getUserRequests(client.session.userId, take: 100);
    final results = json?['results'];
    if (results is List) {
      for (final raw in results) {
        if (raw is! Map<String, dynamic>) continue;
        final r = MfRequest.fromJson(raw);
        final id = r.tmdbId;
        if (id == null || r.status == 3 || r.status == 4) continue;
        if (r.kind == MediaKind.movie) {
          if (!r.isAvailable) movieIds.add(id);
        } else {
          series[id] = true;
        }
      }
    }

    // 2. Le serie guardate di recente su Plex.
    try {
      final watched = await _recentlyWatchedShows(showLibraries, multiServer);
      for (final id in watched) {
        series.putIfAbsent(id, () => false);
      }
    } catch (e) {
      appLogger.w('MaggioFlix: serie guardate non disponibili per il calendario', error: e);
    }

    // 3. Dettagli da Seerr, pochi alla volta.
    final entries = <MfCalendarEntry>[];
    final jobs = <Future<void> Function()>[
      for (final id in movieIds)
        () async {
          final raw = await client.getMovieRaw(id);
          final entry = raw == null ? null : _movieEntry(id, raw, today, horizon);
          if (entry != null) entries.add(entry);
        },
      for (final e in series.entries.take(30))
        () async {
          final raw = await client.getTvRaw(e.key);
          final entry = raw == null ? null : _tvEntry(e.key, raw, today, horizon, requested: e.value);
          if (entry != null) entries.add(entry);
        },
    ];
    for (var i = 0; i < jobs.length; i += 6) {
      await Future.wait(
        jobs.skip(i).take(6).map((job) => job().catchError((Object e) {
          appLogger.w('MaggioFlix: voce del calendario non disponibile', error: e);
        })),
      );
    }
    entries.sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      return byDay != 0 ? byDay : a.title.compareTo(b.title);
    });
    return entries;
  }

  /// TMDB delle serie con visione negli ultimi 4 mesi, le più recenti prima.
  static Future<List<int>> _recentlyWatchedShows(List<MediaLibrary> libraries, MultiServerProvider multiServer) async {
    final cutoff = DateTime.now().subtract(const Duration(days: 120)).millisecondsSinceEpoch ~/ 1000;
    final found = <({MediaServerClient client, MediaItem item})>[];
    for (final lib in libraries.take(6)) {
      final serverId = lib.serverId;
      if (serverId == null) continue;
      final mediaClient = multiServer.getClientForServer(ServerId(serverId));
      if (mediaClient == null) continue;
      try {
        final page = await mediaClient
            .fetchLibraryPagedContent(
              lib.id,
              query: const LibraryQuery(kind: MediaKind.show, limit: 15, sort: LibrarySort(field: 'lastViewedAt')),
              libraryKind: MediaKind.show,
            )
            .timeout(const Duration(seconds: 15));
        for (final item in page.items) {
          if ((item.lastViewedAt ?? 0) >= cutoff) found.add((client: mediaClient, item: item));
        }
      } catch (e) {
        appLogger.w('MaggioFlix: libreria serie non leggibile per il calendario', error: e);
      }
    }
    found.sort((a, b) => (b.item.lastViewedAt ?? 0).compareTo(a.item.lastViewedAt ?? 0));
    final ids = await Future.wait(
      found.take(20).map(
        (f) => f.client
            .fetchExternalIds(f.item.id)
            .then<int?>((ids) => ids.tmdb)
            .timeout(const Duration(seconds: 10))
            .catchError((Object _) => null),
      ),
    );
    return [...{...ids.whereType<int>()}];
  }

  static String? _image(Object? path, String size) =>
      path is String && path.startsWith('/') ? 'https://image.tmdb.org/t/p/$size$path' : null;

  static MfCalendarEntry? _movieEntry(int id, Map<String, dynamic> raw, DateTime today, DateTime horizon) {
    final title = raw['title'] as String? ?? '';
    if (title.isEmpty) return null;
    DateTime? digital;
    DateTime? theatrical;
    final countries = (raw['releases'] is Map ? (raw['releases'] as Map)['results'] : null);
    if (countries is List) {
      DateTime? pick(String? country, int type) {
        DateTime? best;
        for (final c in countries) {
          if (c is! Map) continue;
          if (country != null && c['iso_3166_1'] != country) continue;
          final dates = c['release_dates'];
          if (dates is! List) continue;
          for (final d in dates) {
            if (d is! Map || _int(d['type']) != type) continue;
            final at = DateTime.tryParse('${d['release_date'] ?? ''}');
            if (at != null && (best == null || at.isBefore(best))) best = at;
          }
        }
        return best;
      }

      digital = pick('IT', 4) ?? pick('US', 4) ?? pick(null, 4);
      theatrical = pick('IT', 3) ?? pick('US', 3);
    }
    theatrical ??= DateTime.tryParse('${raw['releaseDate'] ?? ''}');

    DateTime? day;
    String detail;
    String status;
    if (digital != null && !_day(digital.toLocal()).isBefore(today)) {
      day = _day(digital.toLocal());
      detail = _tr('Film · uscita in digitale', 'Movie · digital release');
      status = _tr('Richiesto da te · lo scarichiamo appena esce', 'You requested it · downloads as soon as it is out');
    } else if (theatrical != null && !_day(theatrical.toLocal()).isBefore(today)) {
      day = _day(theatrical.toLocal());
      detail = _tr('Film · al cinema', 'Movie · in theaters');
      status = _tr("Richiesto da te · arriva dopo l'uscita in digitale", 'You requested it · arrives after the digital release');
    } else {
      return null;
    }
    if (day.isAfter(horizon)) return null;
    return MfCalendarEntry(
      day: day,
      kind: MfCalendarKind.movie,
      tmdbId: id,
      title: title,
      detail: detail,
      status: status,
      statusColor: mfAmber,
      imageUrl: _image(raw['backdropPath'], 'w300') ?? _image(raw['posterPath'], 'w185'),
      requested: true,
    );
  }

  static MfCalendarEntry? _tvEntry(
    int id,
    Map<String, dynamic> raw,
    DateTime today,
    DateTime horizon, {
    required bool requested,
  }) {
    final next = raw['nextEpisodeToAir'];
    if (next is! Map) return null;
    final airDate = DateTime.tryParse('${next['airDate'] ?? ''}');
    if (airDate == null) return null;
    final day = _day(airDate);
    if (day.isBefore(today) || day.isAfter(horizon)) return null;
    final title = (raw['name'] as String?) ?? '';
    if (title.isEmpty) return null;
    final season = _int(next['seasonNumber']) ?? 0;
    final episode = _int(next['episodeNumber']) ?? 0;
    final name = (next['name'] as String?)?.trim() ?? '';

    var seasonStatus = 1;
    final mediaInfo = raw['mediaInfo'];
    if (mediaInfo is Map && mediaInfo['seasons'] is List) {
      for (final s in mediaInfo['seasons'] as List) {
        if (s is Map && _int(s['seasonNumber']) == season) seasonStatus = _int(s['status']) ?? 1;
      }
    }
    // 2 richiesta, 3 seguita da Sonarr, 4-5 già (in parte) sul server.
    final covered = seasonStatus >= 2;
    final premiere = episode == 1;
    final detail = premiere
        ? _tr('Inizia la stagione $season', 'Season $season premiere')
        : 'S$season · E$episode${name.isEmpty || name.startsWith('Episod') ? '' : ' «$name»'}';
    return MfCalendarEntry(
      day: day,
      kind: premiere ? MfCalendarKind.premiere : MfCalendarKind.episode,
      tmdbId: id,
      title: title,
      detail: detail,
      status: covered
          ? _tr('Arriva sul server dopo la messa in onda', 'Reaches the server after it airs')
          : _tr('Stagione $season non ancora richiesta', 'Season $season not requested yet'),
      statusColor: covered ? mfCyan : null,
      imageUrl: _image(next['stillPath'], 'w300') ?? _image(raw['backdropPath'], 'w300'),
      seasonToRequest: covered ? null : season,
      requested: requested,
    );
  }
}

Future<void> _openEntry(BuildContext context, MfCalendarEntry entry) async {
  final source = context.read<CatalogSourcesProvider>().seerrSource;
  if (source == null || entry.tmdbId <= 0) return;
  final found = await source.maggioflixRequestedItem(entry.mediaKind, entry.tmdbId).catchError((Object e) {
    appLogger.w('MaggioFlix: scheda del calendario non disponibile', error: e);
    return null;
  });
  if (found == null || !context.mounted) return;
  await navigateToCatalogItem(context, found.item);
}

void _requestEntry(BuildContext context, MfCalendarEntry entry) {
  final source = context.read<CatalogSourcesProvider>().seerrSource;
  if (source == null) return;
  unawaited(
    showSeerrRequestSheet(context, source: source, kind: entry.mediaKind, tmdbId: entry.tmdbId, title: entry.title),
  );
}

String _dayHeading(DateTime day) {
  final today = _day(DateTime.now());
  final weekday = DateFormat.EEEE(_locale).format(day);
  final dayLabel = '$weekday ${day.day}';
  if (day == today) return _tr('Oggi · $dayLabel', 'Today · $dayLabel').toUpperCase();
  if (day == DateTime(today.year, today.month, today.day + 1)) return _tr('Domani · $dayLabel', 'Tomorrow · $dayLabel').toUpperCase();
  return dayLabel.toUpperCase();
}


// ---------------------------------------------------------------------------
// Calendario mensile: griglia del mese e, sotto (o a destra), le uscite del giorno
// ---------------------------------------------------------------------------

const _mfBrandRed = Color(0xFFC9262B);

class MfMonthCalendar extends StatefulWidget {
  /// Griglia e lista affiancate (TV e PC); altrimenti una sotto l'altra.
  final bool wide;

  const MfMonthCalendar({super.key, this.wide = false});

  @override
  State<MfMonthCalendar> createState() => MfMonthCalendarState();
}

class MfMonthCalendarState extends State<MfMonthCalendar> {
  late DateTime _month;
  late DateTime _selected;
  final Map<String, List<MfCalendarEntry>> _byRange = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};

  @override
  void initState() {
    super.initState();
    final today = _day(DateTime.now());
    _month = DateTime(today.year, today.month);
    _selected = today;
    maggioflixRequestsChanged.addListener(_onRequestsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(reload()));
  }

  @override
  void dispose() {
    maggioflixRequestsChanged.removeListener(_onRequestsChanged);
    super.dispose();
  }

  void _onRequestsChanged() => unawaited(reload(force: true));

  DateTime get _gridStart => DateTime(_month.year, _month.month, 1 - (_month.weekday - 1));
  DateTime _gridDay(int index) => DateTime(_gridStart.year, _gridStart.month, _gridStart.day + index);
  DateTime get _gridEnd => _gridDay(41);
  String get _rangeKey => _ymd(_gridStart);

  Future<void> reload({bool force = false}) async {
    final key = _rangeKey;
    final start = _gridStart;
    final end = _gridEnd;
    if (_loading.contains(key) || !mounted) return;
    setState(() {
      _loading.add(key);
      _failed.remove(key);
    });
    try {
      final entries = await MaggioflixCalendarLoader.loadRange(context, start, end, force: force);
      if (!mounted) return;
      setState(() => _byRange[key] = entries);
    } catch (e) {
      appLogger.w('MaggioFlix: calendario non disponibile', error: e);
      if (mounted) setState(() => _failed.add(key));
    } finally {
      if (mounted) setState(() => _loading.remove(key));
    }
  }

  void _changeMonth(int delta) {
    final today = _day(DateTime.now());
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = today.year == _month.year && today.month == _month.month ? today : _month;
    });
    unawaited(reload());
  }

  void _goToday() {
    final today = _day(DateTime.now());
    final sameMonth = today.year == _month.year && today.month == _month.month;
    setState(() {
      _month = DateTime(today.year, today.month);
      _selected = today;
    });
    if (!sameMonth) unawaited(reload());
  }

  void _select(DateTime day) {
    if (day.month != _month.month || day.year != _month.year) {
      setState(() {
        _month = DateTime(day.year, day.month);
        _selected = day;
      });
      unawaited(reload());
      return;
    }
    if (day != _selected) setState(() => _selected = day);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _byRange[_rangeKey];
    final byDay = <DateTime, List<MfCalendarEntry>>{};
    for (final e in entries ?? const <MfCalendarEntry>[]) {
      byDay.putIfAbsent(e.day, () => []).add(e);
    }
    final grid = _buildGrid(theme, byDay, loading: entries == null && _loading.contains(_rangeKey));
    final list = _buildDayList(theme, byDay[_selected] ?? const [], entries == null);
    if (widget.wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: grid),
          const SizedBox(width: 24),
          Expanded(flex: 2, child: list),
        ],
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [grid, const SizedBox(height: 18), list]);
  }

  Widget _buildGrid(ThemeData theme, Map<DateTime, List<MfCalendarEntry>> byDay, {required bool loading}) {
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    final today = _day(DateTime.now());
    final monthTitle = _capitalized(DateFormat.yMMMM(_locale).format(_month));
    final monday = DateTime(2024, 1, 1);
    final weekdays = [
      for (var i = 0; i < 7; i++) _capitalized(DateFormat.E(_locale).format(DateTime(2024, 1, monday.day + i))),
    ];

    Widget legendDot(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
      ],
    );

    return GestureDetector(
      onHorizontalDragEnd: widget.wide
          ? null
          : (details) {
              final v = details.primaryVelocity ?? 0;
              if (v < -250) _changeMonth(1);
              if (v > 250) _changeMonth(-1);
            },
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 4),
                const AppIcon(Symbols.calendar_month_rounded, fill: 1, size: 30, color: _mfBrandRed),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tr('Calendario MaggioFlix', 'MaggioFlix calendar'),
                        style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFFF6B6B)),
                      ),
                      Text(
                        monthTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                IconButton(
                  tooltip: _tr('Mese precedente', 'Previous month'),
                  onPressed: () => _changeMonth(-1),
                  icon: const AppIcon(Symbols.chevron_left_rounded),
                ),
                IconButton(
                  tooltip: _tr('Mese successivo', 'Next month'),
                  onPressed: () => _changeMonth(1),
                  icon: const AppIcon(Symbols.chevron_right_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final w in weekdays)
                  Expanded(
                    child: Text(
                      w,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            for (var week = 0; week < 6; week++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    for (var i = 0; i < 7; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Builder(
                            builder: (context) {
                              final day = _gridDay(week * 7 + i);
                              return _MfDayCell(
                                day: day,
                                inMonth: day.month == _month.month,
                                isToday: day == today,
                                selected: day == _selected,
                                entries: byDay[day] ?? const [],
                                aspectRatio: widget.wide ? 1.35 : 0.92,
                                autofocus: widget.wide && day == today,
                                onTap: () => _select(day),
                                onFocused: widget.wide && day.month == _month.month ? () => _select(day) : null,
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 6),
                legendDot(mfAmber, _tr('Film', 'Movies')),
                const SizedBox(width: 16),
                legendDot(mfCyan, _tr('Serie', 'Series')),
                const Spacer(),
                TextButton(onPressed: _goToday, child: Text(_tr('Oggi', 'Today'))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDayList(ThemeData theme, List<MfCalendarEntry> entries, bool notLoaded) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          _dayHeading(_selected),
          style: theme.textTheme.labelLarge?.copyWith(color: muted, fontWeight: FontWeight.w700, letterSpacing: 0.5),
        ),
      ),
    ];
    if (notLoaded && _failed.contains(_rangeKey)) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Text(_tr('Impossibile caricare il calendario.', 'Could not load the calendar.')),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => unawaited(reload(force: true)), child: Text(t.common.retry)),
            ],
          ),
        ),
      );
    } else if (notLoaded) {
      children.add(const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())));
    } else if (entries.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Text(
            _tr('Niente in uscita in questo giorno.', 'Nothing comes out on this day.'),
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    } else {
      for (final e in entries) {
        children.add(Padding(padding: const EdgeInsets.only(bottom: 10), child: _MfCalendarCard(entry: e)));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _MfDayCell extends StatelessWidget {
  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool selected;
  final List<MfCalendarEntry> entries;
  final double aspectRatio;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback? onFocused;

  const _MfDayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.selected,
    required this.entries,
    required this.aspectRatio,
    required this.autofocus,
    required this.onTap,
    this.onFocused,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = scheme.surfaceContainerHighest;
    final background = selected
        ? _mfBrandRed.withValues(alpha: 0.9)
        : (inMonth ? base.withValues(alpha: 0.75) : base.withValues(alpha: 0.3));
    final numberColor = selected
        ? Colors.white
        : scheme.onSurface.withValues(alpha: inMonth ? 0.9 : 0.35);
    final dots = entries.take(3).toList();
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected
              ? const BorderSide(color: Colors.white, width: 2)
              : (isToday ? const BorderSide(color: _mfBrandRed, width: 2) : BorderSide.none),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          autofocus: autofocus,
          onTap: onTap,
          onFocusChange: onFocused == null
              ? null
              : (focused) {
                  if (focused) onFocused!();
                },
          focusColor: Colors.white.withValues(alpha: 0.22),
          child: Stack(
            children: [
              Positioned(
                top: 5,
                right: 8,
                child: Text(
                  '${day.day}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: numberColor,
                    fontWeight: selected || isToday ? FontWeight.w800 : FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (dots.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final e in dots)
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: inMonth ? e.color : e.color.withValues(alpha: 0.45),
                            border: selected ? Border.all(color: Colors.white, width: 1) : null,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MfCalendarCard extends StatelessWidget {
  final MfCalendarEntry entry;

  const _MfCalendarCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final image = entry.posterUrl ?? entry.imageUrl;
    final placeholder = ColoredBox(color: theme.colorScheme.surfaceContainerHighest);
    final Widget trailing;
    if (entry.seasonToRequest != null) {
      trailing = FilledButton(
        onPressed: () => _requestEntry(context, entry),
        style: FilledButton.styleFrom(
          backgroundColor: _mfBrandRed,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(_tr('Richiedi', 'Request')),
      );
    } else {
      final color = entry.onServer ? mfGreen : entry.color;
      trailing = Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.18)),
        child: Center(
          child: AppIcon(
            entry.onServer ? Symbols.download_done_rounded : Symbols.schedule_rounded,
            size: 22,
            color: color,
          ),
        ),
      );
    }
    return Material(
      color: Color.alphaBlend(entry.color.withValues(alpha: 0.07), theme.colorScheme.surfaceContainerLow),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.tmdbId > 0 ? () => unawaited(_openEntry(context, entry)) : null,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: entry.color),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 54,
                    height: 80,
                    child: image == null
                        ? placeholder
                        : Image.network(image, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: entry.statusColor ?? muted,
                          fontWeight: entry.statusColor == null ? null : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Center(child: trailing)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Telefono: scheda "Calendario" nelle Richieste
// ---------------------------------------------------------------------------

class MaggioflixCalendarView extends StatefulWidget {
  const MaggioflixCalendarView({super.key});

  @override
  State<MaggioflixCalendarView> createState() => _MaggioflixCalendarViewState();
}

class _MaggioflixCalendarViewState extends State<MaggioflixCalendarView> {
  final _calendar = GlobalKey<MfMonthCalendarState>();

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _calendar.currentState?.reload(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [MfMonthCalendar(key: _calendar)],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TV e PC: pagina "Calendario"
// ---------------------------------------------------------------------------

class MaggioflixCalendarScreen extends StatefulWidget {
  const MaggioflixCalendarScreen({super.key});

  @override
  State<MaggioflixCalendarScreen> createState() => _MaggioflixCalendarScreenState();
}

class _MaggioflixCalendarScreenState extends State<MaggioflixCalendarScreen> {
  final _calendar = GlobalKey<MfMonthCalendarState>();

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(maggioflixCalendarLabel()),
      actions: [
        IconButton(
          tooltip: t.common.refresh,
          icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
          onPressed: () => unawaited(_calendar.currentState?.reload(force: true)),
        ),
      ],
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          sliver: SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  MfMonthCalendar(key: _calendar, wide: constraints.maxWidth >= 820),
            ),
          ),
        ),
      ],
    );
  }
}
