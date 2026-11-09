/// MaggioFlix: calendario delle uscite. Prossimi episodi delle serie che
/// l'utente guarda (su Plex) o ha richiesto, e date di uscita dei film
/// richiesti non ancora sul server. I dati vengono da Seerr (TMDB).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/input_mode_tracker.dart';
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
import '../widgets/focusable_list_tile.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/seerr_request_sheet.dart';
import 'requests.dart';

bool get _isItalian => LocaleSettings.currentLocale.languageCode == 'it';

String _tr(String it, String en) => _isItalian ? it : en;

String get _locale => LocaleSettings.currentLocale.intlLocaleName;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

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
  });

  bool get isMovie => kind == MfCalendarKind.movie;
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
  if (source == null) return;
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
  if (day == today.add(const Duration(days: 1))) return _tr('Domani · $dayLabel', 'Tomorrow · $dayLabel').toUpperCase();
  return dayLabel.toUpperCase();
}

// ---------------------------------------------------------------------------
// Telefono: scheda "Calendario"
// ---------------------------------------------------------------------------

enum _MfCalendarFilter { all, series, movies }

class MaggioflixCalendarView extends StatefulWidget {
  const MaggioflixCalendarView({super.key});

  @override
  State<MaggioflixCalendarView> createState() => _MaggioflixCalendarViewState();
}

class _MaggioflixCalendarViewState extends State<MaggioflixCalendarView> {
  List<MfCalendarEntry>? _entries;
  bool _failed = false;
  int _week = 0;
  _MfCalendarFilter _filter = _MfCalendarFilter.all;
  final Map<DateTime, GlobalKey> _dayKeys = {};

  @override
  void initState() {
    super.initState();
    maggioflixRequestsChanged.addListener(_onRequestsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    maggioflixRequestsChanged.removeListener(_onRequestsChanged);
    super.dispose();
  }

  void _onRequestsChanged() => unawaited(_load(force: true));

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    try {
      final entries = await MaggioflixCalendarLoader.load(context, force: force);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _failed = false;
      });
    } catch (e) {
      appLogger.w('MaggioFlix: calendario non disponibile', error: e);
      if (!mounted) return;
      setState(() => _failed = _entries == null);
    }
  }

  DateTime get _weekStart {
    final today = _day(DateTime.now());
    return today.subtract(Duration(days: today.weekday - 1)).add(Duration(days: 7 * _week));
  }

  bool _matches(MfCalendarEntry e) => switch (_filter) {
    _MfCalendarFilter.all => true,
    _MfCalendarFilter.series => !e.isMovie,
    _MfCalendarFilter.movies => e.isMovie,
  };

  String _weekLabel(DateTime start) {
    if (_week == 0) return _tr('Questa settimana', 'This week');
    if (_week == 1) return _tr('Prossima settimana', 'Next week');
    final end = start.add(const Duration(days: 6));
    final fmt = DateFormat.MMMd(_locale);
    return '${fmt.format(start)} – ${fmt.format(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final start = _weekStart;
    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    final today = _day(DateTime.now());
    final entries = (_entries ?? const <MfCalendarEntry>[]).where(_matches).toList();
    final byDay = <DateTime, List<MfCalendarEntry>>{};
    for (final e in entries) {
      if (e.day.isBefore(start) || !e.day.isBefore(start.add(const Duration(days: 7)))) continue;
      byDay.putIfAbsent(e.day, () => []).add(e);
    }

    Widget dayButton(DateTime d) {
      final isToday = d == today;
      final hasItems = byDay.containsKey(d);
      final fg = isToday ? Colors.white : theme.colorScheme.onSurface;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: isToday ? const Color(0xFFC9262B) : theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: hasItems
                  ? () {
                      final ctx = _dayKeys[d]?.currentContext;
                      if (ctx != null) unawaited(Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300)));
                    }
                  : null,
              child: SizedBox(
                height: 62,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      DateFormat.E(_locale).format(d),
                      style: theme.textTheme.labelSmall?.copyWith(color: isToday ? fg : muted),
                    ),
                    Text(
                      '${d.day}',
                      style: theme.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hasItems ? (isToday ? Colors.white : muted) : Colors.transparent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget chip(String label, _MfCalendarFilter value) => ChoiceChip(
      label: Text(label),
      selected: _filter == value,
      showCheckmark: false,
      onSelected: (_) => setState(() => _filter = value),
    );

    final children = <Widget>[
      Row(
        children: [
          IconButton(
            tooltip: _tr('Settimana precedente', 'Previous week'),
            onPressed: _week > 0 ? () => setState(() => _week--) : null,
            icon: const AppIcon(Symbols.chevron_left_rounded),
          ),
          Expanded(
            child: Text(
              _weekLabel(start),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            tooltip: _tr('Settimana successiva', 'Next week'),
            onPressed: _week < 5 ? () => setState(() => _week++) : null,
            icon: const AppIcon(Symbols.chevron_right_rounded),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Row(children: days.map(dayButton).toList()),
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          chip(_tr('Tutto', 'All'), _MfCalendarFilter.all),
          chip(_tr('Serie', 'Series'), _MfCalendarFilter.series),
          chip(_tr('Film richiesti', 'Requested movies'), _MfCalendarFilter.movies),
        ],
      ),
      const SizedBox(height: 14),
    ];

    if (_entries == null && !_failed) {
      children.add(const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())));
    } else if (_failed) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(_tr('Impossibile caricare il calendario.', 'Could not load the calendar.')),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => unawaited(_load(force: true)), child: Text(t.common.retry)),
            ],
          ),
        ),
      );
    } else if (byDay.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            _tr('Nessuna uscita in questa settimana.', 'Nothing comes out this week.'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    } else {
      final sortedDays = byDay.keys.toList()..sort();
      for (final d in sortedDays) {
        final key = _dayKeys.putIfAbsent(d, GlobalKey.new);
        children.add(
          Padding(
            key: key,
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(
              _dayHeading(d),
              style: theme.textTheme.labelMedium?.copyWith(
                color: muted,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        );
        for (final e in byDay[d]!) {
          children.add(Padding(padding: const EdgeInsets.only(bottom: 10), child: _MfCalendarCard(entry: e)));
        }
      }
    }

    children.add(
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          _tr(
            'Qui trovi i prossimi episodi delle serie che guardi o hai richiesto e le uscite dei film che hai richiesto.',
            'Upcoming episodes of the series you watch or requested, and release dates of the movies you requested.',
          ),
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ),
    );

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: children,
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
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => unawaited(_openEntry(context, entry)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 84,
                  height: 48,
                  child: entry.imageUrl == null
                      ? ColoredBox(color: theme.colorScheme.surfaceContainerHighest)
                      : Image.network(
                          entry.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) =>
                              ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(entry.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 2),
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
              if (entry.seasonToRequest != null) ...[
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _requestEntry(context, entry),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC9262B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(_tr('Richiedi', 'Request')),
                ),
              ],
            ],
          ),
        ),
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
  List<MfCalendarEntry>? _entries;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    try {
      final entries = await MaggioflixCalendarLoader.load(context, force: force);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _failed = false;
      });
    } catch (e) {
      appLogger.w('MaggioFlix: calendario non disponibile', error: e);
      if (!mounted) return;
      setState(() => _failed = _entries == null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final autofocusFirst = InputModeTracker.isKeyboardMode(context);
    final today = _day(DateTime.now());
    final entries = (_entries ?? const <MfCalendarEntry>[])
        .where((e) => e.day.isBefore(today.add(const Duration(days: 21))))
        .toList();
    final slivers = <Widget>[];
    if (_entries == null && !_failed) {
      slivers.add(const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator())));
    } else if (_failed) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_tr('Impossibile caricare il calendario.', 'Could not load the calendar.')),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: () => unawaited(_load(force: true)), child: Text(t.common.retry)),
              ],
            ),
          ),
        ),
      );
    } else if (entries.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              _tr('Nessuna uscita nelle prossime tre settimane.', 'Nothing comes out in the next three weeks.'),
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ),
      );
    } else {
      DateTime? lastDay;
      var index = 0;
      final tiles = <Widget>[];
      for (final e in entries) {
        if (e.day != lastDay) {
          lastDay = e.day;
          tiles.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
              child: Text(
                _dayHeading(e.day),
                style: theme.textTheme.labelLarge?.copyWith(color: muted, fontWeight: FontWeight.w700),
              ),
            ),
          );
        }
        final first = index == 0;
        index++;
        tiles.add(
          FocusableListTile(
            autofocus: autofocusFirst && first,
            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 112,
                height: 63,
                child: e.imageUrl == null
                    ? ColoredBox(color: theme.colorScheme.surfaceContainerHighest)
                    : Image.network(
                        e.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) =>
                            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                      ),
              ),
            ),
            title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(e.detail),
                Text(
                  e.seasonToRequest == null ? e.status : '${e.status} · ${_tr('apri per richiederla', 'open to request it')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: e.statusColor ?? muted,
                    fontWeight: e.statusColor == null ? null : FontWeight.w600,
                  ),
                ),
              ],
            ),
            onTap: () => unawaited(_openEntry(context, e)),
          ),
        );
      }
      slivers.add(SliverList(delegate: SliverChildListDelegate(tiles)));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    }

    return FocusedScrollScaffold(
      title: Text(maggioflixCalendarLabel()),
      actions: [
        IconButton(
          tooltip: t.common.refresh,
          icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
          onPressed: () => unawaited(_load(force: true)),
        ),
      ],
      slivers: slivers,
    );
  }
}
