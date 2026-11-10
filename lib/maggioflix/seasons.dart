// MaggioFlix: stagioni di una serie con il loro stato sul server.
//
// Lo stato arriva prima dal server (Sonarr tramite il ponte: quanti episodi ci
// sono davvero) e dal download in corso (qBittorrent), poi da Seerr.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/media_kind.dart';
import '../services/catalog/seerr_catalog_source.dart';
import '../utils/app_logger.dart';
import '../widgets/app_icon.dart';
import 'live.dart';
import 'requests.dart';

bool get _isItalian => LocaleSettings.currentLocale.languageCode == 'it';

String _tr(String it, String en) => _isItalian ? it : en;

int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

class MfSeasonInfo {
  final int number;
  final String name;

  /// Episodi della stagione secondo TMDB.
  final int episodes;

  /// Sonarr: episodi già sul server, usciti finora, totali (null se Sonarr non la segue).
  final int? files;
  final int? aired;
  final int? total;
  final bool monitored;

  /// Seerr: 1 sconosciuto, 2 in attesa, 3 in lavorazione, 4 in parte, 5 disponibile.
  final int seerrStatus;

  /// C'è una richiesta aperta che la comprende.
  final bool requested;

  /// Plex: episodi della stagione presenti nell'app (null se Plex non è raggiungibile).
  final int? plexEpisodes;

  const MfSeasonInfo({
    required this.number,
    required this.name,
    required this.episodes,
    this.files,
    this.aired,
    this.total,
    this.monitored = false,
    this.seerrStatus = 1,
    this.requested = false,
    this.plexEpisodes,
  });

  int get _count => total != null && total! > 0 ? total! : episodes;

  /// Episodi davvero presenti: prima Plex (quello che si vede nell'app), poi i
  /// file di Sonarr. Null: il server non lo sa, si usa Seerr (che si accorge
  /// tardi delle cancellazioni).
  int? get _have => plexEpisodes ?? files;

  /// Lo stato viene dal server, non da Seerr.
  bool get serverKnown => _have != null;

  /// Tutti gli episodi sono sul server.
  bool get isComplete {
    final have = _have;
    if (have != null) return have > 0 && have >= _count;
    return seerrStatus == 5;
  }

  /// Almeno un episodio sul server.
  bool get hasSome {
    final have = _have;
    if (have != null) return have > 0;
    return seerrStatus >= 4;
  }

  /// Già richiesta o seguita dal server: non serve richiederla.
  bool get covered =>
      isComplete ||
      hasSome ||
      monitored ||
      requested ||
      seerrStatus == 2 ||
      seerrStatus == 3 ||
      (!serverKnown && seerrStatus >= 4);
}

enum MfSeasonState { available, partial, downloading, importing, requested, missing }

class MfSeasonStatus {
  final MfSeasonState state;
  final String label;
  final Color color;
  final IconData icon;

  const MfSeasonStatus(this.state, this.label, this.color, this.icon);
}

MfSeasonStatus mfSeasonStatus(MfSeasonInfo s, MfLiveItem? live) {
  if (live != null && live.isActive && live.seasons.contains(s.number)) {
    if (live.isDownloading) {
      return MfSeasonStatus(
        MfSeasonState.downloading,
        '${_tr('In download', 'Downloading')} · ${(live.progressAt(DateTime.now()) * 100).floor()}%',
        mfCyan,
        Symbols.downloading_rounded,
      );
    }
    return MfSeasonStatus(MfSeasonState.importing, live.stateLabel, mfCyan, Symbols.move_to_inbox_rounded);
  }
  if (live != null && live.isImported && live.seasons.contains(s.number) && !s.isComplete) {
    return MfSeasonStatus(MfSeasonState.importing, _tr('Importazione', 'Importing'), mfCyan, Symbols.move_to_inbox_rounded);
  }
  if (s.isComplete) {
    return MfSeasonStatus(MfSeasonState.available, _tr('Disponibile', 'Available'), mfGreen, Symbols.check_circle_rounded);
  }
  if (s.hasSome) {
    final have = s._have;
    final label = have != null && have > 0
        ? _tr('$have di ${s._count} episodi', '$have of ${s._count} episodes')
        : _tr('In parte', 'Partial');
    return MfSeasonStatus(MfSeasonState.partial, label, mfGreen, Symbols.incomplete_circle_rounded);
  }
  if (s.monitored || s.requested || s.seerrStatus == 2 || s.seerrStatus == 3) {
    final notOut = s.aired != null && s.aired == 0;
    return MfSeasonStatus(
      MfSeasonState.requested,
      notOut ? _tr('Richiesta · non ancora uscita', 'Requested · not out yet') : _tr('Richiesta', 'Requested'),
      mfAmber,
      Symbols.schedule_rounded,
    );
  }
  return MfSeasonStatus(
    MfSeasonState.missing,
    _tr('Non richiesta', 'Not requested'),
    Colors.white.withValues(alpha: 0.45),
    Symbols.radio_button_unchecked_rounded,
  );
}

String mfSeasonsCountLabel(int complete, int total) =>
    _tr('$complete di $total stagioni', '$complete of $total seasons');

/// Quante stagioni sono complete sul server, su quante.
({int complete, int total, bool any}) mfSeasonsSummary(List<MfSeasonInfo> seasons) => (
  complete: seasons.where((s) => s.isComplete).length,
  total: seasons.length,
  any: seasons.any((s) => s.hasSome),
);

abstract final class MaggioflixSeasons {
  /// Stagioni da Seerr (nomi, episodi, richieste) e dal server (Sonarr tramite il ponte).
  static Future<List<MfSeasonInfo>> load(SeerrCatalogSource source, int tmdbId, {int? tvdbId}) async {
    final rawFuture = source.client.getTvRaw(tmdbId);
    Map<String, Map<String, dynamic>> sonarr = {};
    Map<String, int>? plex;
    try {
      final query = 'tmdb=$tmdbId${tvdbId != null ? '&tvdb=$tvdbId' : ''}';
      final json = await maggioflixBridgeGet(source, '/api/series?$query');
      if (json is Map && json['seasons'] is List) {
        for (final s in json['seasons'] as List) {
          if (s is Map<String, dynamic> && _int(s['season']) != null) sonarr['${_int(s['season'])}'] = s;
        }
      }
      final p = json is Map ? json['plex'] : null;
      if (p is Map && p['plex'] == true) {
        plex = {};
        final seasons = p['seasons'];
        if (seasons is Map) {
          seasons.forEach((k, v) {
            final n = _int(v);
            if (n != null) plex!['$k'] = n;
          });
        }
      }
    } catch (e) {
      appLogger.w('MaggioFlix: stagioni dal server non disponibili', error: e);
    }
    final raw = await rawFuture;
    if (raw == null) return const [];

    final seerrStatus = <int, int>{};
    final requested = <int>{};
    final mediaInfo = raw['mediaInfo'];
    if (mediaInfo is Map) {
      if (mediaInfo['seasons'] is List) {
        for (final s in mediaInfo['seasons'] as List) {
          if (s is! Map) continue;
          final n = _int(s['seasonNumber']);
          if (n != null) seerrStatus[n] = _int(s['status']) ?? 1;
        }
      }
      if (mediaInfo['requests'] is List) {
        for (final r in mediaInfo['requests'] as List) {
          if (r is! Map || r['is4k'] == true) continue;
          final status = _int(r['status']) ?? 0;
          if (status != 1 && status != 2) continue; // solo richieste aperte (non rifiutate, fallite o concluse)
          if (r['seasons'] is List) {
            for (final s in r['seasons'] as List) {
              final n = s is Map ? _int(s['seasonNumber']) : null;
              if (n != null) requested.add(n);
            }
          }
        }
      }
    }

    final out = <MfSeasonInfo>[];
    if (raw['seasons'] is List) {
      for (final s in raw['seasons'] as List) {
        if (s is! Map) continue;
        final n = _int(s['seasonNumber']);
        final episodes = _int(s['episodeCount']) ?? 0;
        if (n == null || n <= 0 || episodes <= 0) continue;
        final son = sonarr['$n'];
        out.add(
          MfSeasonInfo(
            number: n,
            name: (s['name'] as String?)?.trim().isNotEmpty == true
                ? (s['name'] as String).trim()
                : _tr('Stagione $n', 'Season $n'),
            episodes: episodes,
            files: son == null ? null : _int(son['files']),
            aired: son == null ? null : _int(son['aired']),
            total: son == null ? null : _int(son['total']),
            monitored: son?['monitored'] == true,
            seerrStatus: seerrStatus[n] ?? 1,
            requested: requested.contains(n),
            plexEpisodes: plex == null ? null : (plex['$n'] ?? 0),
          ),
        );
      }
    }
    out.sort((a, b) => a.number.compareTo(b.number));
    return out;
  }
}

/// Elenco delle stagioni con lo stato di ciascuna e, sotto, "Richiedi altre stagioni".
class MfSeasonsPanel extends StatefulWidget {
  final List<MfSeasonInfo> seasons;
  final MediaKind kind;
  final int? tmdbId;
  final int? tvdbId;

  /// Null: nessun pulsante (su TV c'è già nella barra in alto).
  final VoidCallback? onRequestMore;

  const MfSeasonsPanel({
    super.key,
    required this.seasons,
    required this.kind,
    required this.tmdbId,
    this.tvdbId,
    this.onRequestMore,
  });

  @override
  State<MfSeasonsPanel> createState() => _MfSeasonsPanelState();
}

class _MfSeasonsPanelState extends State<MfSeasonsPanel> {
  static const _collapsedCount = 6;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MaggioflixLive.instance,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.65);
    final live = MaggioflixLive.instance;
    final liveItem = live.itemFor(widget.kind, tmdbId: widget.tmdbId, tvdbId: widget.tvdbId) ??
        live.itemFor(widget.kind, tmdbId: widget.tmdbId, tvdbId: widget.tvdbId, is4k: true);
    final summary = mfSeasonsSummary(widget.seasons);
    final canRequestMore = widget.seasons.any((s) => !s.covered);
    final visible = _expanded || widget.seasons.length <= _collapsedCount + 1
        ? widget.seasons
        : widget.seasons.take(_collapsedCount).toList();

    Widget row(MfSeasonInfo s) {
      final status = mfSeasonStatus(s, liveItem);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      _tr('Stagione ${s.number}', 'Season ${s.number}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _tr('${s.episodes} ep.', '${s.episodes} ep.'),
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AppIcon(status.icon, fill: 1, size: 18, color: status.color),
            const SizedBox(width: 6),
            Text(
              status.label,
              style: theme.textTheme.labelMedium?.copyWith(color: status.color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(
              children: [
                Text(
                  _tr('Stagioni', 'Seasons'),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  _tr(
                    '${summary.complete} di ${summary.total} sul server',
                    '${summary.complete} of ${summary.total} on the server',
                  ),
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 14, endIndent: 14, color: scheme.outlineVariant.withValues(alpha: 0.3)),
            row(visible[i]),
          ],
          if (visible.length < widget.seasons.length)
            TextButton(
              onPressed: () => setState(() => _expanded = true),
              child: Text(_tr('Mostra tutte (${widget.seasons.length})', 'Show all (${widget.seasons.length})')),
            ),
          if (widget.onRequestMore != null && canRequestMore)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: FilledButton.tonalIcon(
                onPressed: widget.onRequestMore,
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                icon: const AppIcon(Symbols.playlist_add_rounded, fill: 1),
                label: Text(maggioflixRequestMoreLabel()),
              ),
            )
          else
            const SizedBox(height: 6),
        ],
      ),
    );
  }
}
