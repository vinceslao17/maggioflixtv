/// MaggioFlix: quote delle richieste (banner nella pagina Request) e pagina
/// "Le mie richieste" con stato e avanzamento dei download, letti da Seerr.
library;

import 'dart:async';

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
  final DateTime? createdAt;
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
    required this.createdAt,
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
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}')?.toLocal(),
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
  unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MaggioflixRequestsScreen())));
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
class MaggioflixQuotaBanner extends StatefulWidget {
  /// Versione su una riga, per la barra della TV.
  final bool compact;

  /// Se presente, il banner mostra "Le mie richieste" e lo apre al tocco.
  final VoidCallback? onOpenRequests;

  const MaggioflixQuotaBanner({super.key, this.compact = false, this.onOpenRequests});

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
    return widget.compact ? _buildCompact(context, quota) : _buildFull(context, quota);
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

class MaggioflixRequestsScreen extends StatefulWidget {
  const MaggioflixRequestsScreen({super.key});

  @override
  State<MaggioflixRequestsScreen> createState() => _MaggioflixRequestsScreenState();
}

class _MaggioflixRequestsScreenState extends State<MaggioflixRequestsScreen> {
  static const _pageSize = 30;

  List<MfRequest> _requests = const [];
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _failed = false;
  int _generation = 0;
  Timer? _poll;
  int _ticks = 0;
  bool _inFlight = false;

  bool get _hasActive =>
      _requests.any((r) => r.downloads.isNotEmpty || r.status == 1 || (r.status == 2 && r.mediaStatus != 5));
  final Map<String, Future<({CatalogItem item, String? thumbUrl})?>> _items = {};

  @override
  void initState() {
    super.initState();
    maggioflixRequestsChanged.addListener(_silentReload);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
    // Aggiorna da solo stato e download: ogni 5 s se qualcosa è in corso,
    // altrimenti ogni 30 s.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      _ticks++;
      if (_hasActive || _ticks % 6 == 0) _silentReload();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    maggioflixRequestsChanged.removeListener(_silentReload);
    super.dispose();
  }

  void _silentReload() {
    if (mounted && !_loading && !_inFlight) unawaited(_load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
    final source = _seerrOf(context);
    if (source == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    final generation = ++_generation;
    if (!silent) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    _inFlight = true;
    try {
      final loaded = _requests.length;
      final take = !silent || loaded < _pageSize ? _pageSize : (loaded > 200 ? 200 : loaded);
      final json = await source.client.getUserRequests(source.client.session.userId, take: take);
      if (!mounted || generation != _generation) return;
      final results = json?['results'];
      final pageInfo = json?['pageInfo'];
      setState(() {
        _requests = [
          if (results is List)
            for (final r in results)
              if (r is Map<String, dynamic>) MfRequest.fromJson(r),
        ];
        _total = pageInfo is Map<String, dynamic> ? (_int(pageInfo['results']) ?? _requests.length) : _requests.length;
        _loading = false;
        _failed = false;
      });
    } catch (e) {
      appLogger.w('MaggioFlix: richieste Seerr non disponibili', error: e);
      if (!mounted || generation != _generation) return;
      if (!silent) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _loadMore() async {
    final source = _seerrOf(context);
    if (source == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final json = await source.client.getUserRequests(
        source.client.session.userId,
        take: _pageSize,
        skip: _requests.length,
      );
      if (!mounted) return;
      final results = json?['results'];
      setState(() {
        _requests = [
          ..._requests,
          if (results is List)
            for (final r in results)
              if (r is Map<String, dynamic>) MfRequest.fromJson(r),
        ];
      });
    } catch (e) {
      appLogger.w('MaggioFlix: altre richieste non disponibili', error: e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<({CatalogItem item, String? thumbUrl})?> _itemFor(MfRequest request) {
    final tmdbId = request.tmdbId;
    final source = _seerrOf(context);
    if (tmdbId == null || source == null) return Future.value(null);
    return _items.putIfAbsent(
      '${request.kind.name}:$tmdbId',
      () => source.maggioflixRequestedItem(request.kind, tmdbId).catchError((Object e) {
        appLogger.w('MaggioFlix: dettagli della richiesta non disponibili', error: e);
        return null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final autofocusFirst = InputModeTracker.isKeyboardMode(context);
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(_tr('Le mie richieste', 'My requests')),
      actions: [
        IconButton(
          tooltip: t.common.refresh,
          icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
          onPressed: () => unawaited(_load()),
        ),
      ],
      slivers: [
        const SliverToBoxAdapter(child: MaggioflixQuotaBanner()),
        if (_loading)
          const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
        else if (_failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_tr('Impossibile caricare le richieste.', 'Could not load your requests.')),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: () => unawaited(_load()), child: Text(t.common.retry)),
                ],
              ),
            ),
          )
        else if (_requests.isEmpty)
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
                key: ValueKey('mf-request-${_requests[index].id}'),
                request: _requests[index],
                item: _itemFor(_requests[index]),
                autofocus: autofocusFirst && index == 0,
              ),
              childCount: _requests.length,
            ),
          ),
          if (_requests.length < _total)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _loadingMore
                      ? const CircularProgressIndicator()
                      : OutlinedButton(
                          onPressed: () => unawaited(_loadMore()),
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
    3 => _StatusInfo(_tr('In elaborazione', 'Processing'), Symbols.sync_rounded, Colors.lightBlueAccent),
    7 => _StatusInfo(_tr('Eliminata', 'Deleted'), Symbols.delete_rounded, Colors.grey),
    _ => _StatusInfo(_tr('Approvata', 'Approved'), Symbols.thumb_up_rounded, Colors.lightBlueAccent),
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

  const _LiveDownloadProgress({required this.request});

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

    final details = <String>[
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
          child: LinearProgressIndicator(value: safeProgress, minHeight: 6),
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
              if (request.downloads.isNotEmpty) ...[
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
