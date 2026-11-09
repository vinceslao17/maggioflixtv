/// MaggioFlix: quote delle richieste (banner nella pagina Request) e pagina
/// "Le mie richieste" con stato e avanzamento dei download, letti da Seerr.
library;

import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/input_mode_tracker.dart';
import '../i18n/app_locale_utils.dart';
import '../i18n/strings.g.dart';
import '../media/media_kind.dart';
import '../models/catalog/catalog_item.dart';
import '../providers/catalog_sources_provider.dart';
import '../services/deep_links/deep_link_service.dart';
import 'live.dart';
import '../utils/platform_detector.dart';
import '../services/catalog/seerr_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/catalog_navigation_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/focused_scroll_scaffold.dart';

/// Incrementato dopo ogni richiesta inviata: banner e pagina si aggiornano.
final ValueNotifier<int> maggioflixRequestsChanged = ValueNotifier<int>(0);

bool get _isItalian => LocaleSettings.currentLocale.languageCode == 'it';

String _tr(String it, String en) => _isItalian ? it : en;

int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

double _double(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? 0 : 0);

// ---------------------------------------------------------------------------
// Dati
// ---------------------------------------------------------------------------

class MfQuotaStatus {
  final int? days;
  final int? limit;
  final int used;
  final int? remaining;
  final bool restricted;

  const MfQuotaStatus({this.days, this.limit, this.used = 0, this.remaining, this.restricted = false});

  bool get unlimited => limit == null || limit == 0;

  factory MfQuotaStatus.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const MfQuotaStatus();
    return MfQuotaStatus(
      days: _int(json['days']),
      limit: _int(json['limit']),
      used: _int(json['used']) ?? 0,
      remaining: _int(json['remaining']),
      restricted: json['restricted'] == true,
    );
  }
}

class MfQuota {
  final MfQuotaStatus movie;
  final MfQuotaStatus tv;

  const MfQuota({required this.movie, required this.tv});

  factory MfQuota.fromJson(Map<String, dynamic> json) =>
      MfQuota(movie: MfQuotaStatus.fromJson(json['movie']), tv: MfQuotaStatus.fromJson(json['tv']));
}

class MfDownload {
  final double size;
  final double sizeLeft;
  final String status;
  final String? timeLeft;
  final DateTime? estimatedCompletion;
  final int? season;
  final int? episode;

  const MfDownload({
    required this.size,
    required this.sizeLeft,
    required this.status,
    this.timeLeft,
    this.estimatedCompletion,
    this.season,
    this.episode,
  });

  factory MfDownload.fromJson(Map<String, dynamic> json) {
    final episode = json['episode'];
    return MfDownload(
      size: _double(json['size']),
      sizeLeft: _double(json['sizeLeft']),
      status: (json['status'] as String?) ?? '',
      timeLeft: json['timeLeft'] as String?,
      estimatedCompletion: DateTime.tryParse('${json['estimatedCompletionTime'] ?? ''}')?.toLocal(),
      season: episode is Map<String, dynamic> ? _int(episode['seasonNumber']) : null,
      episode: episode is Map<String, dynamic> ? _int(episode['episodeNumber']) : null,
    );
  }
}

class MfRequest {
  final int id;

  /// 1 in attesa, 2 approvata, 3 rifiutata, 4 non riuscita, 5 completata.
  final int status;
  final bool is4k;
  final MediaKind kind;
  final int? tmdbId;
  final int? tvdbId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<int> seasons;

  /// Stato del contenuto in Seerr: 1 sconosciuto, 2 in attesa, 3 in
  /// elaborazione, 4 parzialmente disponibile, 5 disponibile, 7 eliminato.
  final int mediaStatus;
  final List<MfDownload> downloads;

  /// Quando l'app ha letto questi dati: base per stimare l'avanzamento
  /// secondo per secondo fino al prossimo aggiornamento.
  final DateTime fetchedAt;

  MfRequest({
    required this.id,
    required this.status,
    required this.is4k,
    required this.kind,
    required this.tmdbId,
    this.tvdbId,
    required this.createdAt,
    this.updatedAt,
    required this.seasons,
    required this.mediaStatus,
    required this.downloads,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  factory MfRequest.fromJson(Map<String, dynamic> json) {
    final is4k = json['is4k'] == true;
    final Map<String, dynamic> media =
        json['media'] is Map<String, dynamic> ? json['media'] as Map<String, dynamic> : const <String, dynamic>{};
    final type = (json['type'] as String?) ?? (media['mediaType'] as String?) ?? 'movie';
    final rawDownloads = media[is4k ? 'downloadStatus4k' : 'downloadStatus'];
    return MfRequest(
      id: _int(json['id']) ?? 0,
      status: _int(json['status']) ?? 1,
      is4k: is4k,
      kind: type == 'tv' ? MediaKind.show : MediaKind.movie,
      tmdbId: _int(media['tmdbId']),
      tvdbId: _int(media['tvdbId']),
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}')?.toLocal(),
      updatedAt: DateTime.tryParse('${json['updatedAt'] ?? ''}')?.toLocal(),
      seasons: [
        if (json['seasons'] is List)
          for (final s in json['seasons'] as List)
            if (s is Map<String, dynamic> && _int(s['seasonNumber']) != null) _int(s['seasonNumber'])!,
      ]..sort(),
      mediaStatus: _int(media[is4k ? 'status4k' : 'status']) ?? 1,
      downloads: [
        if (rawDownloads is List)
          for (final d in rawDownloads)
            if (d is Map<String, dynamic>) MfDownload.fromJson(d),
      ],
    );
  }

  /// Il titolo richiesto è sul server.
  bool get isAvailable => status == 5 || mediaStatus == 5;

  /// Download in tempo reale dal ponte MaggioFlix Live, se c'è.
  MfLiveItem? get live =>
      isAvailable ? null : MaggioflixLive.instance.itemFor(kind, tmdbId: tmdbId, tvdbId: tvdbId, is4k: is4k);

  /// C'è un download in corso (dal ponte o da Seerr).
  bool get isDownloading => live != null || downloads.isNotEmpty;

  /// Richiesta ancora aperta: in attesa, approvata o in download.
  bool get isInProgress => !isAvailable && (status == 1 || status == 2 || downloads.isNotEmpty);

  /// Comando "Guarda": apre e avvia il titolo sul server.
  String? get playLink =>
      tmdbId == null ? null : 'maggioflix://play?type=${kind == MediaKind.movie ? 'movie' : 'show'}&tmdb=$tmdbId';

  /// Avanzamento complessivo dei download (0-1), null se non scarica nulla.
  double? get progress {
    if (downloads.isEmpty) return null;
    final total = downloads.fold<double>(0, (sum, d) => sum + d.size);
    if (total <= 0) return 0;
    final left = downloads.fold<double>(0, (sum, d) => sum + d.sizeLeft);
    final value = 1 - left / total;
    return value < 0 ? 0.0 : (value > 1 ? 1.0 : value);
  }
}

SeerrCatalogSource? _seerrOf(BuildContext context, {bool listen = false}) => listen
    ? context.watch<CatalogSourcesProvider>().seerrSource
    : context.read<CatalogSourcesProvider>().seerrSource;

Future<MfQuota?> _loadQuota(SeerrCatalogSource source) async {
  final json = await source.client.getUserQuota(source.client.session.userId);
  return json == null ? null : MfQuota.fromJson(json);
}

/// Etichette del sottomenu Request e dello stato nella scheda titolo.
String maggioflixBrowseLabel() => _tr('Sfoglia', 'Browse');
String maggioflixAvailableLabel() => _tr('Disponibile', 'Available');
String maggioflixRequestedLabel() => _tr('Richiesto', 'Requested');

/// Etichetta del pulsante che apre "Le mie richieste".
String maggioflixMyRequestsLabel() => _tr('Le mie richieste', 'My requests');

/// Apre la pagina "Le mie richieste".
void openMaggioflixRequests(BuildContext context) {
  final phone = !PlatformDetector.isTV() && !PlatformDetector.isDesktopOS();
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => phone ? const MaggioflixRequestsPhonePage() : const MaggioflixRequestsScreen(),
      ),
    ),
  );
}

String _period(int? days) {
  if (days == null || days <= 0) return '';
  if (days == 1) return _tr('al giorno', 'per day');
  if (days == 7) return _tr('a settimana', 'per week');
  if (days == 30 || days == 31) return _tr('al mese', 'per month');
  return _tr('ogni $days giorni', 'every $days days');
}

// ---------------------------------------------------------------------------
// Banner quote
// ---------------------------------------------------------------------------

/// Riepilogo delle quote: film e stagioni ancora richiedibili nel periodo.
/// Si nasconde quando Seerr non è collegato o le quote non si leggono.
enum MfQuotaStyle { banner, compact, card, pill }

class MaggioflixQuotaBanner extends StatefulWidget {
  /// Versione su una riga, per la barra della TV.
  final bool compact;

  /// Aspetto: banner (vecchia pagina), compact (TV), card con barre e pillola (telefono).
  final MfQuotaStyle? style;

  /// Se presente, il banner mostra "Le mie richieste" e lo apre al tocco.
  final VoidCallback? onOpenRequests;

  const MaggioflixQuotaBanner({super.key, this.compact = false, this.onOpenRequests, this.style});

  @override
  State<MaggioflixQuotaBanner> createState() => _MaggioflixQuotaBannerState();
}

class _MaggioflixQuotaBannerState extends State<MaggioflixQuotaBanner> {
  MfQuota? _quota;
  SeerrCatalogSource? _loadedFor;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    maggioflixRequestsChanged.addListener(_reload);
  }

  @override
  void dispose() {
    maggioflixRequestsChanged.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    final source = _loadedFor;
    if (source != null) unawaited(_load(source));
  }

  Future<void> _load(SeerrCatalogSource source) async {
    final generation = ++_generation;
    try {
      final quota = await _loadQuota(source);
      if (!mounted || generation != _generation) return;
      setState(() => _quota = quota);
    } catch (e) {
      appLogger.w('MaggioFlix: quote Seerr non disponibili', error: e);
      if (!mounted || generation != _generation) return;
      setState(() => _quota = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _seerrOf(context, listen: true);
    if (!identical(source, _loadedFor)) {
      _loadedFor = source;
      _quota = null;
      if (source != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_loadedFor, source)) unawaited(_load(source));
        });
      }
    }
    final quota = _quota;
    if (source == null || quota == null) return const SizedBox.shrink();
    return switch (widget.style ?? (widget.compact ? MfQuotaStyle.compact : MfQuotaStyle.banner)) {
      MfQuotaStyle.compact => _buildCompact(context, quota),
      MfQuotaStyle.banner => _buildFull(context, quota),
      MfQuotaStyle.card => _buildCard(context, quota),
      MfQuotaStyle.pill => _buildPill(context, quota),
    };
  }

  /// Pillola della testata (telefono): film e stagioni che restano.
  Widget _buildPill(BuildContext context, MfQuota quota) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    Widget part(IconData icon, MfQuotaStatus q) {
      final color = q.restricted ? theme.colorScheme.error : theme.colorScheme.onSurface;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 16, color: q.restricted ? color : muted),
          const SizedBox(width: 4),
          Text(_shortValue(q), style: theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      );
    }

    return Semantics(
      button: widget.onOpenRequests != null,
      label: _tr(
        'Questa settimana ti restano ${quota.movie.remaining ?? 0} film e ${quota.tv.remaining ?? 0} stagioni',
        '${quota.movie.remaining ?? 0} movies and ${quota.tv.remaining ?? 0} seasons left',
      ),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: StadiumBorder(side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onOpenRequests,
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  part(Symbols.movie_rounded, quota.movie),
                  Container(
                    width: 1,
                    height: 16,
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    color: theme.colorScheme.outlineVariant,
                  ),
                  part(Symbols.tv_rounded, quota.tv),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Riquadro "Questa settimana" con le barre di quanto hai usato.
  Widget _buildCard(BuildContext context, MfQuota quota) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final samePeriod = quota.movie.days == quota.tv.days;
    final period = samePeriod ? _period(quota.movie.days) : '';
    final heading = switch (period) {
      'a settimana' || 'per week' => _tr('Questa settimana', 'This week'),
      'al giorno' || 'per day' => _tr('Oggi', 'Today'),
      'al mese' || 'per month' => _tr('Questo mese', 'This month'),
      _ => _tr('Le tue richieste', 'Your requests'),
    };

    Widget meter(String label, MfQuotaStatus q) {
      final limit = q.limit ?? 0;
      final used = q.used;
      final value = q.unlimited || limit == 0 ? 0.0 : (used / limit).clamp(0.0, 1.0).toDouble();
      final text = q.unlimited
          ? _tr('illimitate', 'unlimited')
          : _tr('$used di $limit ${used == 1 ? 'usato' : 'usati'}', '$used of $limit used');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(text, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              color: const Color(0xFFE5484D),
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          meter(_tr('Film', 'Movies'), quota.movie),
          const SizedBox(height: 12),
          meter(_tr('Stagioni di serie', 'Series seasons'), quota.tv),
        ],
      ),
    );
  }

  String _shortValue(MfQuotaStatus q) => q.unlimited ? '∞' : '${q.remaining ?? 0}/${q.limit}';

  Widget _buildCompact(BuildContext context, MfQuota quota) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final samePeriod = quota.movie.days == quota.tv.days;
    Widget chip(IconData icon, String label, MfQuotaStatus q) {
      final color = q.restricted ? theme.colorScheme.error : theme.colorScheme.onSurface;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, fill: 1, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            '$label ${_shortValue(q)}${samePeriod || q.unlimited ? '' : ' ${_period(q.days)}'}',
            style: theme.textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip(Symbols.movie_rounded, _tr('Film', 'Movies'), quota.movie),
          const SizedBox(width: 16),
          chip(Symbols.tv_rounded, _tr('Stagioni', 'Seasons'), quota.tv),
          if (samePeriod &&
              !(quota.movie.unlimited && quota.tv.unlimited) &&
              _period(quota.movie.days).isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(
              _tr('rimasti ${_period(quota.movie.days)}', 'left ${_period(quota.movie.days)}'),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String label, MfQuotaStatus q) {
    final theme = Theme.of(context);
    final color = q.restricted ? theme.colorScheme.error : theme.colorScheme.onSurface;
    final String text;
    if (q.unlimited) {
      text = _tr('$label: richieste illimitate', '$label: unlimited requests');
    } else {
      final period = _period(q.days);
      text = _tr(
        '$label: ti restano ${q.remaining ?? 0} su ${q.limit}${period.isEmpty ? '' : ' $period'}',
        '$label: ${q.remaining ?? 0} of ${q.limit} left${period.isEmpty ? '' : ' $period'}',
      );
    }
    return Row(
      children: [
        AppIcon(icon, fill: 1, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        ),
      ],
    );
  }

  Widget _buildFull(BuildContext context, MfQuota quota) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _line(context, Symbols.movie_rounded, _tr('Film', 'Movies'), quota.movie),
                const SizedBox(height: 6),
                _line(context, Symbols.tv_rounded, _tr('Stagioni', 'Seasons'), quota.tv),
              ],
            ),
          ),
          if (widget.onOpenRequests != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _tr('Le mie richieste', 'My requests'),
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                  ),
                  AppIcon(Symbols.chevron_right_rounded, size: 20, color: theme.colorScheme.primary),
                ],
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: widget.onOpenRequests == null ? content : InkWell(onTap: widget.onOpenRequests, child: content),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pagina "Le mie richieste"
// ---------------------------------------------------------------------------

/// Elenco delle richieste dell'utente, condiviso da pagina TV/PC e scheda del
/// telefono. Si aggiorna da solo: ogni 5 s se qualcosa è in corso, altrimenti
/// ogni 30 s, e subito dopo ogni nuova richiesta.
class MfRequestsController extends ChangeNotifier {
  MfRequestsController() {
    maggioflixRequestsChanged.addListener(silentReload);
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!pollingEnabled) return;
      _ticks++;
      if (hasActive || _ticks % 6 == 0) silentReload();
    });
  }

  static const pageSize = 30;

  /// Aggiornamento automatico attivo (spento quando la scheda non si vede).
  bool pollingEnabled = true;

  SeerrCatalogSource? _source;
  List<MfRequest> requests = const [];
  int total = 0;
  bool loading = true;
  bool loadingMore = false;
  bool failed = false;
  int _generation = 0;
  Timer? _poll;
  int _ticks = 0;
  bool _inFlight = false;
  bool _disposed = false;
  final Map<String, Future<({CatalogItem item, String? thumbUrl})?>> _items = {};

  bool get hasActive => requests.any((r) => r.isDownloading || r.isInProgress);

  /// Richieste ancora aperte, per il numerino sulla scheda.
  int get activeCount => requests.where((r) => r.isInProgress).length;

  /// Collega la sorgente Seerr del profilo; ricarica se è cambiata.
  bool _bound = false;

  void bind(SeerrCatalogSource? source) {
    if (_bound && identical(source, _source)) return;
    _bound = true;
    _source = source;
    _items.clear();
    requests = const [];
    total = 0;
    unawaited(load());
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    maggioflixRequestsChanged.removeListener(silentReload);
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void silentReload() {
    if (!_disposed && !loading && !_inFlight) unawaited(load(silent: true));
  }

  Future<void> load({bool silent = false}) async {
    final source = _source;
    if (source == null) {
      loading = false;
      failed = true;
      _notify();
      return;
    }
    final generation = ++_generation;
    if (!silent) {
      loading = true;
      failed = false;
      _notify();
    }
    _inFlight = true;
    try {
      final loaded = requests.length;
      final take = !silent || loaded < pageSize ? pageSize : (loaded > 200 ? 200 : loaded);
      final json = await source.client.getUserRequests(source.client.session.userId, take: take);
      if (_disposed || generation != _generation) return;
      final results = json?['results'];
      final pageInfo = json?['pageInfo'];
      requests = [
        if (results is List)
          for (final r in results)
            if (r is Map<String, dynamic>) MfRequest.fromJson(r),
      ];
      total = pageInfo is Map<String, dynamic> ? (_int(pageInfo['results']) ?? requests.length) : requests.length;
      loading = false;
      failed = false;
      _notify();
    } catch (e) {
      appLogger.w('MaggioFlix: richieste Seerr non disponibili', error: e);
      if (_disposed || generation != _generation) return;
      if (!silent) {
        loading = false;
        failed = true;
        _notify();
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<void> loadMore() async {
    final source = _source;
    if (source == null || loadingMore) return;
    loadingMore = true;
    _notify();
    try {
      final json = await source.client.getUserRequests(source.client.session.userId, take: pageSize, skip: requests.length);
      if (_disposed) return;
      final results = json?['results'];
      requests = [
        ...requests,
        if (results is List)
          for (final r in results)
            if (r is Map<String, dynamic>) MfRequest.fromJson(r),
      ];
    } catch (e) {
      appLogger.w('MaggioFlix: altre richieste non disponibili', error: e);
    } finally {
      loadingMore = false;
      _notify();
    }
  }

  /// Titolo, anno, locandina del contenuto richiesto (in cache).
  Future<({CatalogItem item, String? thumbUrl})?> itemFor(MfRequest request) {
    final tmdbId = request.tmdbId;
    final source = _source;
    if (tmdbId == null || source == null) return Future.value(null);
    return _items.putIfAbsent(
      '${request.kind.name}:$tmdbId',
      () => source.maggioflixRequestedItem(request.kind, tmdbId).catchError((Object e) {
        appLogger.w('MaggioFlix: dettagli della richiesta non disponibili', error: e);
        return null;
      }),
    );
  }
}

class MaggioflixRequestsScreen extends StatefulWidget {
  const MaggioflixRequestsScreen({super.key});

  @override
  State<MaggioflixRequestsScreen> createState() => _MaggioflixRequestsScreenState();
}

class _MaggioflixRequestsScreenState extends State<MaggioflixRequestsScreen> {
  final MfRequestsController _controller = MfRequestsController();
  VoidCallback? _releaseLive;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = Provider.of<CatalogSourcesProvider>(context).seerrSource;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.bind(source);
      _releaseLive ??= MaggioflixLive.instance.watch(source);
      MaggioflixLive.instance.updateSource(source);
    });
  }

  @override
  void dispose() {
    _releaseLive?.call();
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final autofocusFirst = InputModeTracker.isKeyboardMode(context);
    final theme = Theme.of(context);
    final c = _controller;
    return FocusedScrollScaffold(
      title: Text(_tr('Le mie richieste', 'My requests')),
      actions: [
        IconButton(
          tooltip: t.common.refresh,
          icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
          onPressed: () => unawaited(c.load()),
        ),
      ],
      slivers: [
        const SliverToBoxAdapter(child: MaggioflixQuotaBanner()),
        if (c.loading)
          const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
        else if (c.failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_tr('Impossibile caricare le richieste.', 'Could not load your requests.')),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: () => unawaited(c.load()), child: Text(t.common.retry)),
                ],
              ),
            ),
          )
        else if (c.requests.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                _tr('Non hai ancora fatto richieste.', "You haven't requested anything yet."),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          )
        else ...[
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _RequestTile(
                key: ValueKey('mf-request-${c.requests[index].id}'),
                request: c.requests[index],
                item: c.itemFor(c.requests[index]),
                autofocus: autofocusFirst && index == 0,
              ),
              childCount: c.requests.length,
            ),
          ),
          if (c.requests.length < c.total)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: c.loadingMore
                      ? const CircularProgressIndicator()
                      : OutlinedButton(
                          onPressed: () => unawaited(c.loadMore()),
                          child: Text(_tr('Mostra altre', 'Show more')),
                        ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ],
    );
  }
}

class _StatusInfo {
  final String label;
  final IconData icon;
  final Color color;

  const _StatusInfo(this.label, this.icon, this.color);
}

_StatusInfo _statusOf(MfRequest r, ThemeData theme) {
  switch (r.status) {
    case 1:
      return _StatusInfo(_tr('In attesa di approvazione', 'Pending approval'), Symbols.schedule_rounded, Colors.amber);
    case 3:
      return _StatusInfo(_tr('Rifiutata', 'Declined'), Symbols.block_rounded, theme.colorScheme.error);
    case 4:
      return _StatusInfo(_tr('Non riuscita', 'Failed'), Symbols.error_rounded, theme.colorScheme.error);
  }
  final live = r.live;
  if (live != null) {
    return _StatusInfo(
      live.isDownloading ? _tr('In download', 'Downloading') : live.stateLabel,
      live.isImporting ? Symbols.move_to_inbox_rounded : Symbols.download_rounded,
      Colors.lightBlueAccent,
    );
  }
  if (r.downloads.isNotEmpty) {
    return _StatusInfo(_tr('In download', 'Downloading'), Symbols.download_rounded, Colors.lightBlueAccent);
  }
  return switch (r.mediaStatus) {
    5 => _StatusInfo(_tr('Disponibile', 'Available'), Symbols.check_circle_rounded, Colors.green),
    4 => _StatusInfo(
      _tr('Parzialmente disponibile', 'Partially available'),
      Symbols.check_circle_rounded,
      Colors.lightGreen,
    ),
    7 => _StatusInfo(_tr('Eliminata', 'Deleted'), Symbols.delete_rounded, Colors.grey),
    // Come su Seerr: approvata ma senza download in corso = "Richiesto".
    _ => _StatusInfo(_tr('Richiesto', 'Requested'), Symbols.schedule_rounded, Colors.amber),
  };
}

/// Durata da "01:05:12" o "1.02:03:04" (formato di Radarr/Sonarr).
Duration? _parseTimeLeft(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  var days = 0;
  var rest = raw;
  final dot = raw.indexOf('.');
  final colon = raw.indexOf(':');
  if (dot > 0 && colon > dot) {
    days = int.tryParse(raw.substring(0, dot)) ?? 0;
    rest = raw.substring(dot + 1);
  }
  final parts = rest.split(':');
  if (parts.length < 2) return null;
  final hours = int.tryParse(parts[0]) ?? 0;
  final minutes = int.tryParse(parts[1]) ?? 0;
  final seconds = parts.length > 2 ? (double.tryParse(parts[2]) ?? 0).floor() : 0;
  return Duration(days: days, hours: hours, minutes: minutes, seconds: seconds);
}

/// "1h 05m", "4m 12s", "12s".
String _formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  final seconds = d.inSeconds % 60;
  if (hours > 0) return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  if (minutes > 0) return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  return '${seconds}s';
}

String _formatBytes(double bytes, String locale) {
  const gb = 1024.0 * 1024 * 1024;
  const mb = 1024.0 * 1024;
  if (bytes >= gb) return '${NumberFormat('0.00', locale).format(bytes / gb)} GB';
  return '${NumberFormat('0', locale).format(bytes / mb)} MB';
}

String _formatSpeed(double bytesPerSecond, String locale) {
  const mb = 1024.0 * 1024;
  if (bytesPerSecond >= mb) return '${NumberFormat('0.0', locale).format(bytesPerSecond / mb)} MB/s';
  return '${NumberFormat('0', locale).format(bytesPerSecond / 1024)} KB/s';
}

String _queueStatusLabel(String status) => switch (status.toLowerCase()) {
  'paused' => _tr('In pausa', 'Paused'),
  'queued' => _tr('In coda', 'Queued'),
  'delay' => _tr('In attesa', 'Delayed'),
  'warning' => _tr('Attenzione: problema col download', 'Warning: download issue'),
  'failed' => _tr('Download non riuscito', 'Download failed'),
  'completed' => _tr('Scaricato, in importazione', 'Downloaded, importing'),
  _ => '',
};

/// Barra di download che avanza ogni secondo: tra un aggiornamento e l'altro
/// stima l'avanzamento dalla velocità implicita nell'orario di fine previsto
/// che Radarr/Sonarr comunicano, poi si riallinea al dato vero.
class _LiveDownloadProgress extends StatefulWidget {
  final MfRequest request;

  /// Colore della barra (telefono: azzurro); null = colore del tema.
  final Color? color;

  /// Solo percentuale, tempo che manca ed episodi (scheda del telefono).
  final bool compact;

  const _LiveDownloadProgress({required this.request, this.color, this.compact = false});

  @override
  State<_LiveDownloadProgress> createState() => _LiveDownloadProgressState();
}

class _LiveDownloadProgressState extends State<_LiveDownloadProgress> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final locale = LocaleSettings.currentLocale.intlLocaleName;
    final now = DateTime.now();

    final live = r.live;
    if (live != null) return _buildLive(context, live, now, locale, muted);

    final total = r.downloads.fold<double>(0, (sum, d) => sum + d.size);
    final leftAtFetch = r.downloads.fold<double>(0, (sum, d) => sum + d.sizeLeft);
    final downloading = r.downloads.any((d) => d.status.toLowerCase() == 'downloading');

    // Fine prevista: l'orario dichiarato, altrimenti "tempo rimanente" dal momento della lettura.
    DateTime? eta;
    for (final d in r.downloads) {
      final parsedLeft = _parseTimeLeft(d.timeLeft);
      final candidate = d.estimatedCompletion ?? (parsedLeft == null ? null : r.fetchedAt.add(parsedLeft));
      if (candidate != null && (eta == null || candidate.isAfter(eta))) eta = candidate;
    }

    var left = leftAtFetch;
    double? speed;
    Duration? remaining;
    if (eta != null) {
      remaining = eta.difference(now);
      if (remaining.isNegative) remaining = Duration.zero;
      final span = eta.difference(r.fetchedAt).inMilliseconds / 1000.0;
      if (downloading && span > 0 && leftAtFetch > 0) {
        speed = leftAtFetch / span;
        final elapsed = now.difference(r.fetchedAt).inMilliseconds / 1000.0;
        left = leftAtFetch - speed * elapsed;
        // Non arriva al 100% da sola: lo conferma il prossimo aggiornamento.
        final floor = total * 0.001;
        if (left < floor) left = floor;
      }
    }
    final progress = total > 0 ? (1 - left / total) : 0.0;
    final safeProgress = progress < 0 ? 0.0 : (progress > 1 ? 1.0 : progress);

    final episodes = r.downloads.where((d) => d.episode != null).length;
    final statusLabel = downloading
        ? ''
        : r.downloads.map((d) => _queueStatusLabel(d.status)).firstWhere((l) => l.isNotEmpty, orElse: () => '');

    final details = widget.compact
        ? <String>[
            '${NumberFormat('0', locale).format(safeProgress * 100)}%',
            if (downloading && remaining != null)
              _tr('mancano ${_formatDuration(remaining)}', '${_formatDuration(remaining)} left'),
            if (episodes > 1) _tr('$episodes episodi', '$episodes episodes'),
            if (statusLabel.isNotEmpty) statusLabel,
          ]
        : <String>[
      '${NumberFormat('0.0', locale).format(safeProgress * 100)}%',
      if (total > 0) '${_formatBytes(total - left, locale)} ${_tr('di', 'of')} ${_formatBytes(total, locale)}',
      if (speed != null && speed > 0) _formatSpeed(speed, locale),
      if (downloading && remaining != null) _tr('mancano ${_formatDuration(remaining)}', '${_formatDuration(remaining)} left'),
      if (episodes > 1) _tr('$episodes episodi', '$episodes episodes'),
      if (statusLabel.isNotEmpty) statusLabel,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: safeProgress,
            minHeight: widget.compact ? 5 : 6,
            color: widget.color,
            backgroundColor: widget.color == null ? null : theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 4),
        Text(details.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
      ],
    );
  }
}

extension on _LiveDownloadProgressState {
  /// Dati in tempo reale dal ponte (qBittorrent), aggiornati ogni secondo.
  Widget _buildLive(BuildContext context, MfLiveItem live, DateTime now, String locale, Color muted) {
    final theme = Theme.of(context);
    final progress = live.progressAt(now);
    final remaining = live.remainingAt(now);
    final doneBytes = (live.size * progress).round();
    final pct = widget.compact
        ? '${NumberFormat('0', locale).format(progress * 100)}%'
        : '${NumberFormat('0.0', locale).format(progress * 100)}%';
    final episodes = live.episodes > 1 ? _tr('${live.episodes} episodi', '${live.episodes} episodes') : null;
    final details = <String>[
      pct,
      if (!widget.compact && live.size > 0)
        '${_formatBytes(doneBytes.toDouble(), locale)} ${_tr('di', 'of')} ${_formatBytes(live.size.toDouble(), locale)}',
      if (live.isDownloading && live.speed > 0) _formatSpeed(live.speed.toDouble(), locale),
      if (live.isDownloading && remaining != null)
        _tr('mancano ${_formatDuration(remaining)}', '${_formatDuration(remaining)} left'),
      if (!live.isDownloading) live.stateLabel,
      if (!widget.compact && live.isDownloading && live.seeds > 0) _tr('${live.seeds} fonti', '${live.seeds} seeds'),
      if (episodes != null) episodes,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: live.isImporting ? null : progress,
            minHeight: widget.compact ? 5 : 6,
            color: widget.color,
            backgroundColor: widget.color == null ? null : theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 4),
        Text(details.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
      ],
    );
  }
}

class _RequestTile extends StatelessWidget {
  final MfRequest request;
  final Future<({CatalogItem item, String? thumbUrl})?> item;
  final bool autofocus;

  const _RequestTile({super.key, required this.request, required this.item, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MaggioflixLive.instance,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    return FutureBuilder<({CatalogItem item, String? thumbUrl})?>(
      future: item,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
        final status = _statusOf(request, theme);
        final locale = LocaleSettings.currentLocale.intlLocaleName;

        final meta = <String>[
          request.kind == MediaKind.movie ? _tr('Film', 'Movie') : _tr('Serie TV', 'TV show'),
          if (data?.item.year case final year?) '$year',
          if (request.is4k) '4K',
          if (request.kind == MediaKind.show && request.seasons.isNotEmpty)
            _tr('Stagioni ${request.seasons.join(', ')}', 'Seasons ${request.seasons.join(', ')}'),
          if (request.createdAt case final created?)
            _tr('richiesto il ${DateFormat.yMMMd(locale).format(created)}', 'requested ${DateFormat.yMMMd(locale).format(created)}'),
        ];

        return FocusableListTile(
          autofocus: autofocus,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 48,
              height: 72,
              child: data?.thumbUrl == null
                  ? ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Center(
                        child: AppIcon(
                          request.kind == MediaKind.movie ? Symbols.movie_rounded : Symbols.tv_rounded,
                          color: muted,
                        ),
                      ),
                    )
                  : Image.network(
                      data!.thumbUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) =>
                          ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                    ),
            ),
          ),
          title: Text(
            data?.item.title ?? (snapshot.connectionState == ConnectionState.done ? '—' : '…'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 2),
              Text(meta.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              const SizedBox(height: 6),
              Row(
                children: [
                  AppIcon(status.icon, fill: 1, size: 16, color: status.color),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      status.label,
                      style: theme.textTheme.bodyMedium?.copyWith(color: status.color, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (request.isDownloading) ...[
                const SizedBox(height: 6),
                _LiveDownloadProgress(request: request),
              ],
            ],
          ),
          onTap: data == null ? null : () => unawaited(navigateToCatalogItem(context, data.item)),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Telefono: scheda "Richieste" della pagina Richiedi
// ---------------------------------------------------------------------------

/// Colori degli stati, leggibili sia su tema scuro sia chiaro.
const Color mfGreen = Color(0xFF2EB872);
const Color mfAmber = Color(0xFFE0A030);
const Color mfCyan = Color(0xFF1BA8D8);

enum _MfRequestFilter { active, available, all }

/// Pagina a sé "Le mie richieste" sul telefono (aperta dalla notifica).
class MaggioflixRequestsPhonePage extends StatefulWidget {
  const MaggioflixRequestsPhonePage({super.key});

  @override
  State<MaggioflixRequestsPhonePage> createState() => _MaggioflixRequestsPhonePageState();
}

class _MaggioflixRequestsPhonePageState extends State<MaggioflixRequestsPhonePage> {
  final MfRequestsController _controller = MfRequestsController();
  VoidCallback? _releaseLive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = Provider.of<CatalogSourcesProvider>(context).seerrSource;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.bind(source);
      _releaseLive ??= MaggioflixLive.instance.watch(source);
      MaggioflixLive.instance.updateSource(source);
    });
  }

  @override
  void dispose() {
    _releaseLive?.call();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(maggioflixMyRequestsLabel())),
      body: MaggioflixRequestsTab(controller: _controller),
    );
  }
}

/// Riepilogo quote, filtri e schede delle richieste con stato a colori.
class MaggioflixRequestsTab extends StatefulWidget {
  final MfRequestsController controller;

  const MaggioflixRequestsTab({super.key, required this.controller});

  @override
  State<MaggioflixRequestsTab> createState() => _MaggioflixRequestsTabState();
}

class _MaggioflixRequestsTabState extends State<MaggioflixRequestsTab> {
  _MfRequestFilter _filter = _MfRequestFilter.active;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(MaggioflixRequestsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final active = c.requests.where((r) => r.isInProgress).toList();
    final available = c.requests.where((r) => r.isAvailable).toList();
    final shown = switch (_filter) {
      _MfRequestFilter.active => active,
      _MfRequestFilter.available => available,
      _MfRequestFilter.all => c.requests,
    };
    final now = DateTime.now();
    final recent = available
        .where((r) {
          final when = r.updatedAt ?? r.createdAt;
          return when != null && now.difference(when).inDays < 14;
        })
        .take(3)
        .toList();

    Widget chip(String label, _MfRequestFilter value) {
      final selected = _filter == value;
      return ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => setState(() => _filter = value),
      );
    }

    Widget card(MfRequest r) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _MfRequestCard(key: ValueKey('mf-card-${r.id}'), request: r, item: c.itemFor(r)),
    );

    final children = <Widget>[
      const MaggioflixQuotaBanner(style: MfQuotaStyle.card),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          chip(
            active.isEmpty ? _tr('In corso', 'In progress') : _tr('In corso · ${active.length}', 'In progress · ${active.length}'),
            _MfRequestFilter.active,
          ),
          chip(_tr('Disponibili', 'Available'), _MfRequestFilter.available),
          chip(_tr('Tutte', 'All'), _MfRequestFilter.all),
        ],
      ),
      const SizedBox(height: 14),
    ];

    if (c.loading) {
      children.add(const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())));
    } else if (c.failed) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(_tr('Impossibile caricare le richieste.', 'Could not load your requests.')),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => unawaited(c.load()), child: Text(t.common.retry)),
            ],
          ),
        ),
      );
    } else {
      if (shown.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              switch (_filter) {
                _MfRequestFilter.active => _tr('Nessuna richiesta in corso.', 'Nothing in progress.'),
                _MfRequestFilter.available => _tr('Ancora nessun titolo disponibile.', 'Nothing available yet.'),
                _MfRequestFilter.all => _tr('Non hai ancora fatto richieste.', "You haven't requested anything yet."),
              },
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ),
        );
      } else {
        children.addAll(shown.map(card));
      }
      if (_filter == _MfRequestFilter.active && recent.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 10),
            child: Text(
              _tr('Arrivati da poco', 'Recently arrived'),
              style: theme.textTheme.titleSmall?.copyWith(color: muted, fontWeight: FontWeight.w700),
            ),
          ),
        );
        children.addAll(recent.map(card));
      }
      if (_filter == _MfRequestFilter.all && c.requests.length < c.total) {
        children.add(
          Center(
            child: c.loadingMore
                ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
                : OutlinedButton(onPressed: () => unawaited(c.loadMore()), child: Text(_tr('Mostra altre', 'Show more'))),
          ),
        );
      }
    }

    return RefreshIndicator(
      onRefresh: () => c.load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: children,
      ),
    );
  }
}

class _MfPhoneStatus {
  final String label;
  final Color color;
  final String? detail;

  const _MfPhoneStatus(this.label, this.color, [this.detail]);
}

_MfPhoneStatus _phoneStatusOf(MfRequest r, CatalogItem? item, ThemeData theme) {
  final locale = LocaleSettings.currentLocale.intlLocaleName;
  if (r.status == 3) return _MfPhoneStatus(_tr('Rifiutata', 'Declined'), theme.colorScheme.error);
  if (r.status == 4) return _MfPhoneStatus(_tr('Non riuscita', 'Failed'), theme.colorScheme.error);
  if (r.isAvailable) return _MfPhoneStatus(_tr('Disponibile', 'Available'), mfGreen);
  final live = r.live;
  if (live != null) {
    return _MfPhoneStatus(live.isDownloading ? _tr('In download', 'Downloading') : live.stateLabel, mfCyan);
  }
  if (r.downloads.isNotEmpty) return _MfPhoneStatus(_tr('In download', 'Downloading'), mfCyan);
  if (r.mediaStatus == 4) {
    return _MfPhoneStatus(
      _tr('Parzialmente disponibile', 'Partially available'),
      mfGreen,
      _tr('Gli altri episodi arrivano man mano', 'More episodes on the way'),
    );
  }
  if (r.status == 1) return _MfPhoneStatus(_tr('In attesa di approvazione', 'Waiting for approval'), mfAmber);
  // Come su Seerr: approvata ma senza download in corso = "Richiesto".
  final release = item?.releaseDate;
  if (release != null && release.isAfter(DateTime.now())) {
    return _MfPhoneStatus(
      _tr('Richiesto', 'Requested'),
      mfAmber,
      _tr('Esce il ${DateFormat.yMMMMd(locale).format(release)}', 'Out ${DateFormat.yMMMMd(locale).format(release)}'),
    );
  }
  return _MfPhoneStatus(
    _tr('Richiesto', 'Requested'),
    mfAmber,
    _tr('Si scarica appena si trova una copia', 'Downloads as soon as a copy is found'),
  );
}

class _MfRequestCard extends StatelessWidget {
  final MfRequest request;
  final Future<({CatalogItem item, String? thumbUrl})?> item;

  const _MfRequestCard({super.key, required this.request, required this.item});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MaggioflixLive.instance,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    return FutureBuilder<({CatalogItem item, String? thumbUrl})?>(
      future: item,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
        final status = _phoneStatusOf(request, data?.item, theme);
        final title = data?.item.title ?? (snapshot.connectionState == ConnectionState.done ? '—' : '…');
        final seasons = request.kind == MediaKind.show && request.seasons.isNotEmpty
            ? (request.seasons.length == 1
                  ? _tr('Stagione ${request.seasons.first}', 'Season ${request.seasons.first}')
                  : _tr('Stagioni ${request.seasons.join(', ')}', 'Seasons ${request.seasons.join(', ')}'))
            : null;
        final meta = <String>[
          request.kind == MediaKind.movie ? _tr('Film', 'Movie') : _tr('Serie TV', 'TV show'),
          if (data?.item.year case final year?) '$year',
          if (request.is4k) '4K',
        ];
        final playLink = request.playLink;

        return Material(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: data == null ? null : () => unawaited(navigateToCatalogItem(context, data.item)),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 56,
                      height: 84,
                      child: data?.thumbUrl == null
                          ? ColoredBox(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Center(
                                child: AppIcon(
                                  request.kind == MediaKind.movie ? Symbols.movie_rounded : Symbols.tv_rounded,
                                  color: muted,
                                ),
                              ),
                            )
                          : Image.network(
                              data!.thumbUrl!,
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
                          seasons == null ? title : '$title · $seasons',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(meta.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: status.color, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                status.label,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: status.color,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (request.isDownloading) ...[
                          const SizedBox(height: 6),
                          _LiveDownloadProgress(request: request, color: mfCyan, compact: true),
                        ] else if (status.detail != null) ...[
                          const SizedBox(height: 3),
                          Text(status.detail!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                        ],
                      ],
                    ),
                  ),
                  if (request.isAvailable && playLink != null) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => DeepLinkService.instance.receive(playLink),
                      icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1, size: 18),
                      label: Text(_tr('Guarda', 'Watch')),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.onSurface,
                        foregroundColor: theme.colorScheme.surface,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Pillola di stato nella scheda di un titolo
// ---------------------------------------------------------------------------

/// Disponibile, Richiesto oppure, col ponte MaggioFlix Live, il download in
/// corso: la pillola si riempie man mano, con velocità e tempo che manca.
class MaggioflixLiveStatusPill extends StatefulWidget {
  final MediaKind kind;
  final int? tmdbId;
  final bool available;

  /// Download appena finito: in arrivo sul server.
  final bool finishing;

  /// Messa a fuoco col telecomando.
  final bool focused;

  const MaggioflixLiveStatusPill({
    super.key,
    required this.kind,
    required this.tmdbId,
    required this.available,
    this.finishing = false,
    this.focused = false,
  });

  @override
  State<MaggioflixLiveStatusPill> createState() => _MaggioflixLiveStatusPillState();
}

class _MaggioflixLiveStatusPillState extends State<MaggioflixLiveStatusPill> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    MaggioflixLive.instance.addListener(_changed);
    // Tra un aggiornamento e l'altro la barra e il tempo avanzano da soli.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_live?.isDownloading ?? false) _changed();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    MaggioflixLive.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  MfLiveItem? get _live {
    final tmdbId = widget.tmdbId;
    if (widget.available || tmdbId == null) return null;
    return MaggioflixLive.instance.itemFor(widget.kind, tmdbId: tmdbId) ??
        MaggioflixLive.instance.itemFor(widget.kind, tmdbId: tmdbId, is4k: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = LocaleSettings.currentLocale.intlLocaleName;
    final now = DateTime.now();
    final live = _live;

    Color accent;
    IconData icon;
    String title;
    String? subtitle;
    double? fill;

    if (widget.available) {
      accent = Colors.green;
      icon = Symbols.check_circle_rounded;
      title = maggioflixAvailableLabel();
    } else if (live != null) {
      accent = const Color(0xFF4FC3F7);
      final progress = live.progressAt(now);
      final pct = '${NumberFormat('0', locale).format((progress * 100).floorToDouble())}%';
      fill = live.isImporting ? 1.0 : progress;
      icon = switch (live.state) {
        'downloading' => Symbols.downloading_rounded,
        'stalled' => Symbols.travel_explore_rounded,
        'queued' => Symbols.schedule_rounded,
        'checking' => Symbols.sync_rounded,
        'metadata' => Symbols.hourglass_top_rounded,
        'paused' => Symbols.pause_circle_rounded,
        'error' => Symbols.error_rounded,
        _ => Symbols.move_to_inbox_rounded,
      };
      if (live.isDownloading) {
        final remaining = live.remainingAt(now);
        title = '${_tr('In download', 'Downloading')} · $pct';
        subtitle = [
          if (live.speed > 0) _formatSpeed(live.speed.toDouble(), locale),
          if (remaining != null) _tr('mancano ${_formatDuration(remaining)}', '${_formatDuration(remaining)} left'),
          if (live.episodes > 1) _tr('${live.episodes} episodi', '${live.episodes} episodes'),
        ].join(' · ');
      } else if (live.isImporting) {
        title = _tr('Scaricato', 'Downloaded');
        subtitle = _tr('In importazione sul server', 'Importing to the server');
      } else {
        title = '${live.stateLabel} · $pct';
        subtitle = live.state == 'stalled'
            ? _tr('${live.seeds} fonti · ${live.peers} peer', '${live.seeds} seeds · ${live.peers} peers')
            : null;
      }
      if (subtitle != null && subtitle.isEmpty) subtitle = null;
    } else if (widget.finishing) {
      accent = Colors.green;
      icon = Symbols.check_circle_rounded;
      title = _tr('Scaricato', 'Downloaded');
      subtitle = _tr('Arriva sul server tra poco', 'Reaching the server soon');
      fill = 1.0;
    } else {
      accent = Colors.lightBlueAccent;
      icon = Symbols.schedule_rounded;
      title = maggioflixRequestedLabel();
    }

    const tabular = [FontFeature.tabularFigures()];
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: 18, vertical: subtitle == null ? 10 : 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, fill: 1, size: 20, color: accent),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                    fontFeatures: tabular,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      fontFeatures: tabular,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      label: subtitle == null ? title : '$title, $subtitle',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        constraints: BoxConstraints(minHeight: 44, minWidth: fill != null ? 210 : 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: widget.focused ? theme.colorScheme.onSurface : accent.withValues(alpha: 0.7),
            width: widget.focused ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(23),
          child: Stack(
            children: [
              if (fill != null)
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedFractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      duration: const Duration(milliseconds: 1000),
                      curve: Curves.linear,
                      widthFactor: fill.clamp(0.03, 1.0).toDouble(),
                      heightFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [accent.withValues(alpha: 0.14), accent.withValues(alpha: 0.34)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ExcludeSemantics(child: content),
            ],
          ),
        ),
      ),
    );
  }
}
