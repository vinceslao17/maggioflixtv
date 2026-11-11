import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../media/media_source_info.dart';
import '../../../mpv/mpv.dart';
import '../../../services/playback_subtitle_resolver.dart';
import '../../../services/player_sync_offsets.dart';
import '../../../services/scoped_player_prefs.dart';
import '../../../services/settings_service.dart';
import '../../../utils/formatters.dart';
import '../../../services/track_selection_service.dart';
import '../../../i18n/strings.g.dart';
import '../../../utils/track_label_builder.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import 'base_video_control_sheet.dart';
import 'sheet_selection_column.dart';
import 'sheet_split_columns.dart';
import 'subtitle_search_sheet.dart';
import '../models/track_controls_state.dart';
import '../helpers/track_filter_helper.dart';
import '../helpers/track_selection_helper.dart';

/// Combined bottom sheet for selecting audio and subtitle tracks side-by-side.
class TrackSheet extends StatelessWidget {
  final Player player;
  final TrackControlsState trackControlsState;

  const TrackSheet({super.key, required this.player, required this.trackControlsState});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Tracks>(
      stream: player.streams.tracks,
      initialData: player.state.tracks,
      builder: (context, tracksSnapshot) {
        final tracks = tracksSnapshot.data;
        final playerAudioTracks = TrackFilterHelper.extractAndFilterTracks<AudioTrack>(tracks, (t) => t?.audio ?? []);
        final subtitleTracks = TrackFilterHelper.extractAndFilterTracks<SubtitleTrack>(
          tracks,
          (t) => t?.subtitle ?? [],
        );

        final state = trackControlsState;
        final hasExternalSourceAudio = state.sourceAudioTracks.any((track) => track.isExternal);
        final useSourceAudio =
            (state.isTranscoding || hasExternalSourceAudio) &&
            state.sourceAudioTracks.length > 1 &&
            state.onSwitchAudioStreamId != null;
        final useSourceSubtitles = state.canUseSourceSubtitles;
        final showAudio = useSourceAudio || playerAudioTracks.length > 1;
        final showSubtitles = state.hasSubtitleControls(tracks);

        final String title;
        final IconData icon;
        if (showAudio && showSubtitles) {
          title = t.videoControls.tracksButton;
          icon = Symbols.subtitles_rounded;
        } else if (showAudio) {
          title = t.videoControls.audioLabel;
          icon = Symbols.audiotrack_rounded;
        } else {
          title = t.videoControls.subtitlesLabel;
          icon = Symbols.subtitles_rounded;
        }

        return BaseVideoControlSheet(
          title: title,
          icon: icon,
          child: StreamBuilder<TrackSelection>(
            stream: player.streams.track,
            initialData: player.state.track,
            builder: (context, selSnapshot) {
              final selection = selSnapshot.data ?? player.state.track;

              final supportsSecondary = player.supportsSecondarySubtitles;

              Widget audioColumnFor(TrackSelection sel, bool showHeader) {
                if (useSourceAudio) {
                  return _SourceAudioColumn(
                    tracks: state.sourceAudioTracks,
                    selectedStreamId: state.selectedAudioStreamId,
                    isTranscoding: state.isTranscoding,
                    selection: sel,
                    mpvAudioTracks: tracks?.audio ?? const <AudioTrack>[],
                    onSelected: state.onSwitchAudioStreamId!,
                    showHeader: showHeader,
                  );
                }
                return _AudioColumn(
                  tracks: playerAudioTracks,
                  selection: sel,
                  player: player,
                  onTrackChanged: state.onAudioTrackChanged,
                  showHeader: showHeader,
                );
              }

              Widget subtitleColumnFor(TrackSelection sel, bool showHeader) {
                if (useSourceSubtitles) {
                  return _SourceSubtitleColumn(
                    tracks: state.sourceSubtitleTracks,
                    trackControlsState: state,
                    selection: sel,
                    showHeader: showHeader,
                    player: player,
                  );
                }
                return _SubtitleColumn(
                  tracks: subtitleTracks,
                  selection: sel,
                  player: player,
                  supportsSecondary: supportsSecondary,
                  showHeader: showHeader,
                  trackControlsState: state,
                  sourceSidecars: state.directPlaySourceSidecars,
                );
              }

              if (showAudio && showSubtitles) {
                return SheetSplitColumns(
                  start: FocusTraversalGroup(child: audioColumnFor(selection, true)),
                  end: FocusTraversalGroup(child: subtitleColumnFor(selection, true)),
                );
              }

              if (showAudio) {
                return audioColumnFor(selection, false);
              }

              return subtitleColumnFor(selection, false);
            },
          ),
        );
      },
    );
  }
}

class _SourceAudioColumn extends StatelessWidget {
  final List<MediaAudioTrack> tracks;
  final int? selectedStreamId;

  /// Whether the audio is baked into a server rendition rather than picked by
  /// the engine; decides which side is allowed to answer "what is playing".
  final bool isTranscoding;

  /// Engine truth (`player.streams.track`) and the raw engine audio list, used
  /// to map mpv's `aid` back onto a source row on a direct play.
  final TrackSelection selection;
  final List<AudioTrack> mpvAudioTracks;
  final Future<void> Function(int) onSelected;
  final bool showHeader;

  const _SourceAudioColumn({
    required this.tracks,
    required this.selectedStreamId,
    required this.isTranscoding,
    required this.selection,
    required this.mpvAudioTracks,
    required this.onSelected,
    required this.showHeader,
  });

  @override
  Widget build(BuildContext context) {
    final selectedId = _effectiveSelectedStreamId();
    final selectedIndex = selectedId == null ? null : tracks.indexWhere((t) => t.id == selectedId);

    return SheetSelectionColumn(
      headerLabel: showHeader ? t.videoControls.audioLabel : null,
      itemCount: tracks.length,
      initialIndex: selectedIndex,
      itemBuilder: (context, index, scope) {
        final track = tracks[index];
        return TrackSelectionHelper.buildTrackTile(
          context: context,
          key: scope.keyFor(index),
          label: track.label,
          isSelected: track.id == selectedId,
          onTap: () => scope.runExclusive(() => onSelected(track.id)),
        );
      },
    );
  }

  int? _effectiveSelectedStreamId() {
    final explicit = selectedStreamId;
    if (explicit != null && tracks.any((track) => track.id == explicit)) return explicit;
    // On a transcode the chosen row is baked into the rendition — mpv carries a
    // single audio track that is no particular source stream — so the server's
    // `selected` flag is the only answer that exists. On a direct play with
    // external source audio this column is still used but mpv owns the choice,
    // and that flag is the server's *request*, free to disagree with `aid`.
    if (isTranscoding) {
      for (final track in tracks) {
        if (track.selected) return track.id;
      }
      return null;
    }
    return playingSourceAudioTrack(
      selectedMpvTrack: selection.audio,
      mpvTracks: mpvAudioTracks,
      sourceTracks: tracks,
    )?.id;
  }
}

class _SourceSubtitleColumn extends StatelessWidget {
  final List<MediaSubtitleTrack> tracks;
  final TrackControlsState trackControlsState;

  /// Engine truth (`player.streams.track`), so the tick can be cross-checked
  /// against what mpv is actually playing rather than only what was requested.
  final TrackSelection selection;
  final bool showHeader;
  final Player player;

  const _SourceSubtitleColumn({
    required this.tracks,
    required this.trackControlsState,
    required this.selection,
    required this.showHeader,
    required this.player,
  });

  @override
  Widget build(BuildContext context) {
    final selectedChoice = _effectiveSelectedChoice();
    final selectedId = selectedChoice.sourceStreamId;
    final selectedIndex = selectedChoice.isOff ? 0 : tracks.indexWhere((t) => t.id == selectedId) + 1;

    return SheetSelectionColumn(
      headerLabel: showHeader ? t.videoControls.subtitlesLabel : null,
      itemCount: tracks.length + 1,
      initialIndex: selectedIndex,
      footer: _buildSubtitleSearchFooter(context, trackControlsState, player),
      itemBuilder: (context, index, scope) {
        if (index == 0) {
          return TrackSelectionHelper.buildOffTile(
            context: context,
            key: scope.keyFor(index),
            isSelected: selectedChoice.isOff,
            onTap: () => scope.runExclusive(
              () => trackControlsState.onSwitchSubtitle!(const PlaybackSourceSubtitleChoice.off()),
            ),
          );
        }

        final track = tracks[index - 1];
        return TrackSelectionHelper.buildTrackTile(
          context: context,
          label: track.labelForIndex(index - 1),
          isSelected: track.id == selectedId,
          onTap: () => scope.runExclusive(
            () => trackControlsState.onSwitchSubtitle!(PlaybackSourceSubtitleChoice.source(track.id)),
          ),
        );
      },
    );
  }

  /// The row to tick.
  ///
  /// A requested source subtitle is not proof of a playing one: when
  /// [TrackManager] misses its resolve deadline the ladder falls through to off
  /// while the session keeps naming the track, so the picker claimed subtitles
  /// were on while mpv held `sid=no`. A source pick therefore only stands when
  /// the engine confirms it — or when there is nothing for the engine to
  /// confirm because the server burned the subtitle into the picture.
  PlaybackSourceSubtitleChoice _effectiveSelectedChoice() {
    const off = PlaybackSourceSubtitleChoice.off();
    final explicit = trackControlsState.selectedSubtitleChoice;
    if (explicit == null) return off;
    if (explicit.isOff) return explicit;
    if (!tracks.any((track) => track.id == explicit.sourceStreamId)) return off;
    if (trackControlsState.burnsSelectedSubtitle) return explicit;
    final engineSubtitle = selection.subtitle;
    return engineSubtitle != null && engineSubtitle.id != SubtitleTrack.off.id ? explicit : off;
  }
}

class _AudioColumn extends StatelessWidget {
  final List<AudioTrack> tracks;
  final TrackSelection selection;
  final Player player;
  final Function(AudioTrack)? onTrackChanged;
  final bool showHeader;

  const _AudioColumn({
    required this.tracks,
    required this.selection,
    required this.player,
    this.onTrackChanged,
    required this.showHeader,
  });

  @override
  Widget build(BuildContext context) {
    final selectedId = selection.audio?.id ?? '';
    final selectedIndex = tracks.indexWhere((t) => t.id == selectedId);

    return SheetSelectionColumn(
      headerLabel: showHeader ? t.videoControls.audioLabel : null,
      itemCount: tracks.length,
      initialIndex: selectedIndex,
      itemBuilder: (context, index, scope) {
        final track = tracks[index];
        final label = TrackLabelBuilder.audioLabel(
          title: track.title,
          language: track.language,
          codec: track.codec,
          codecProfile: track.codecProfile,
          channels: track.channelsCount,
          index: index,
        );
        return TrackSelectionHelper.buildTrackTile(
          context: context,
          key: scope.keyFor(index),
          label: label,
          isSelected: track.id == selectedId,
          onTap: () {
            player.selectAudioTrack(track);
            onTrackChanged?.call(track);
            OverlaySheetController.of(context).close();
          },
        );
      },
    );
  }
}

class _SubtitleColumn extends StatelessWidget {
  final List<SubtitleTrack> tracks;
  final TrackSelection selection;
  final Player player;
  final bool supportsSecondary;
  final bool showHeader;
  final TrackControlsState trackControlsState;
  final List<MediaSubtitleTrack> sourceSidecars;

  const _SubtitleColumn({
    required this.tracks,
    required this.selection,
    required this.player,
    this.supportsSecondary = false,
    required this.showHeader,
    required this.trackControlsState,
    this.sourceSidecars = const [],
  });

  @override
  Widget build(BuildContext context) {
    final selectedSub = selection.subtitle;
    final secondarySub = selection.secondarySubtitle;
    final isOffSelected = selectedSub == null || selectedSub.id == 'no';
    final hasSecondary = supportsSecondary && secondarySub != null;
    final selectedSourceId = trackControlsState.selectedSubtitleChoice?.sourceStreamId;
    final selectedSecondarySourceId = trackControlsState.selectedSecondarySubtitleStreamId;
    final attachedSourceSidecarIds = <int>{};
    for (final sidecar in trackControlsState.sourceSubtitleSidecars) {
      final sourceStreamId = sidecar.sourceStreamId;
      final uri = sidecar.track.uri;
      if (sourceStreamId == null || uri == null) continue;
      if (tracks.any((track) => track.isExternal && track.uri == uri)) {
        attachedSourceSidecarIds.add(sourceStreamId);
      }
    }
    final unloadedSourceSidecars = sourceSidecars
        .where(
          (track) =>
              !attachedSourceSidecarIds.contains(track.id) &&
              track.id != selectedSourceId &&
              track.id != selectedSecondarySourceId,
        )
        .toList(growable: false);

    // +1 for "Off". Source sidecars represented by native external tracks,
    // plus active source IDs awaiting native discovery, are not appended.
    final itemCount = tracks.length + unloadedSourceSidecars.length + 1;

    final selectedIndex = isOffSelected ? null : tracks.indexWhere((t) => t.id == selectedSub.id) + 1;

    return SheetSelectionColumn(
      headerLabel: showHeader ? t.videoControls.subtitlesLabel : null,
      itemCount: itemCount,
      initialIndex: selectedIndex,
      footer: _buildSubtitleSearchFooter(context, trackControlsState, player),
      itemBuilder: (context, index, scope) {
        if (index == 0) {
          return TrackSelectionHelper.buildOffTile(
            context: context,
            key: scope.keyFor(index),
            isSelected: isOffSelected,
            onTap: () {
              // Turning off primary also clears secondary
              if (hasSecondary) {
                player.selectSecondarySubtitleTrack(SubtitleTrack.off);
                trackControlsState.onSecondarySubtitleTrackChanged?.call(SubtitleTrack.off);
              }
              player.selectSubtitleTrack(SubtitleTrack.off);
              trackControlsState.onSubtitleTrackChanged?.call(SubtitleTrack.off);
              OverlaySheetController.of(context).close();
            },
            onLongPress: supportsSecondary && hasSecondary
                ? () {
                    player.selectSecondarySubtitleTrack(SubtitleTrack.off);
                    trackControlsState.onSecondarySubtitleTrackChanged?.call(SubtitleTrack.off);
                  }
                : null,
            onSecondaryTap: supportsSecondary && hasSecondary
                ? () {
                    player.selectSecondarySubtitleTrack(SubtitleTrack.off);
                    trackControlsState.onSecondarySubtitleTrackChanged?.call(SubtitleTrack.off);
                  }
                : null,
          );
        }

        final trackIndex = index - 1;
        if (trackIndex >= tracks.length) {
          final sourceIndex = trackIndex - tracks.length;
          final sourceTrack = unloadedSourceSidecars[sourceIndex];
          return TrackSelectionHelper.buildTrackTile(
            context: context,
            label: sourceTrack.labelForIndex(trackIndex),
            isSelected: false,
            onTap: () => scope.runExclusive(
              () => trackControlsState.onSwitchSubtitle!(PlaybackSourceSubtitleChoice.source(sourceTrack.id)),
            ),
          );
        }

        final track = tracks[trackIndex];
        final isPrimary = !isOffSelected && track.id == selectedSub.id;
        final isSecondary = hasSecondary && track.id == secondarySub.id;
        final label = TrackLabelBuilder.subtitleLabel(
          title: track.title,
          language: track.language,
          codec: track.codec,
          forced: track.isForced,
          index: trackIndex,
        );

        Widget? badge;
        if (supportsSecondary && hasSecondary) {
          if (isPrimary) {
            badge = TrackSelectionHelper.buildTrackBadge(context, 1);
          } else if (isSecondary) {
            badge = TrackSelectionHelper.buildTrackBadge(context, 2);
          }
        }

        return TrackSelectionHelper.buildTrackTile(
          context: context,
          label: label,
          isSelected: isPrimary,
          badge: badge,
          onTap: () {
            // If tapping a track that is currently the secondary, clear secondary first
            if (isSecondary) {
              player.selectSecondarySubtitleTrack(SubtitleTrack.off);
              trackControlsState.onSecondarySubtitleTrackChanged?.call(SubtitleTrack.off);
            }
            player.selectSubtitleTrack(track);
            trackControlsState.onSubtitleTrackChanged?.call(track);
            OverlaySheetController.of(context).close();
          },
          onLongPress: supportsSecondary
              ? () {
                  if (isSecondary) {
                    // Already secondary — clear it
                    player.selectSecondarySubtitleTrack(SubtitleTrack.off);
                    trackControlsState.onSecondarySubtitleTrackChanged?.call(SubtitleTrack.off);
                  } else if (!isPrimary) {
                    // Set as secondary (don't close sheet so user sees badge update)
                    player.selectSecondarySubtitleTrack(track);
                    trackControlsState.onSecondarySubtitleTrackChanged?.call(track);
                  }
                }
              : null,
          onSecondaryTap: supportsSecondary
              ? () {
                  if (isSecondary) {
                    player.selectSecondarySubtitleTrack(SubtitleTrack.off);
                    trackControlsState.onSecondarySubtitleTrackChanged?.call(SubtitleTrack.off);
                  } else if (!isPrimary) {
                    player.selectSecondarySubtitleTrack(track);
                    trackControlsState.onSecondarySubtitleTrackChanged?.call(track);
                  }
                }
              : null,
        );
      },
    );
  }
}

List<Widget> _buildSubtitleSearchFooter(BuildContext context, TrackControlsState state, Player player) {
  return [
    Divider(height: 1, color: Theme.of(context).dividerColor),
    _SubtitleQuickAdjust(player: player, state: state),
    if (state.canSearchSubtitles) Divider(height: 1, color: Theme.of(context).dividerColor),
    if (state.canSearchSubtitles)
    FocusableListTile(
      leading: const AppIcon(Symbols.search_rounded),
      title: Text(t.videoControls.searchSubtitles),
      onTap: () {
        OverlaySheetController.of(context).push(
          builder: (_) => SubtitleSearchSheet(
            ratingKey: state.ratingKey,
            serverId: state.serverId!,
            mediaTitle: state.mediaTitle,
            onSubtitleDownloaded: state.onSubtitleDownloaded,
          ),
        );
      },
    ),
  ];
}

/// Dimensione e ritardo dei sottotitoli a portata di mano, nello stesso pannello
/// in cui si sceglie la traccia: così non serve aprire le impostazioni del player.
class _SubtitleQuickAdjust extends StatefulWidget {
  final Player player;
  final TrackControlsState state;

  const _SubtitleQuickAdjust({required this.player, required this.state});

  @override
  State<_SubtitleQuickAdjust> createState() => _SubtitleQuickAdjustState();
}

class _SubtitleQuickAdjustState extends State<_SubtitleQuickAdjust> {
  static const int _sizeStep = 4;
  static const int _sizeMin = 16;
  static const int _sizeMax = 90;
  static const int _delayStepMs = 100;

  late int _size;
  late int _delayMs;

  @override
  void initState() {
    super.initState();
    _size = SettingsService.instance.read(SettingsService.subtitleFontSize);
    _delayMs = PlayerSyncOffsets.of(widget.player).subtitleMs;
  }

  Future<void> _changeSize(int delta) async {
    final next = (_size + delta).clamp(_sizeMin, _sizeMax).toInt();
    if (next == _size) return;
    setState(() => _size = next);
    final svc = SettingsService.instance;
    await svc.write(SettingsService.subtitleFontSize, next);
    final player = widget.player;
    try {
      await player.setProperty('sub-font-size', next.toString());
      if (player.playerType == 'exoplayer') {
        await player.setSubtitleStyle(
          fontSize: next.toDouble(),
          textColor: svc.read(SettingsService.subtitleTextColor),
          borderSize: svc.read(SettingsService.subtitleBorderSize).toDouble(),
          borderColor: svc.read(SettingsService.subtitleBorderColor),
          bgColor: svc.read(SettingsService.subtitleBackgroundColor),
          bgOpacity: svc.read(SettingsService.subtitleBackgroundOpacity),
          subtitlePosition: svc.read(SettingsService.subtitlePosition),
          bold: svc.read(SettingsService.subtitleBold),
          italic: svc.read(SettingsService.subtitleItalic),
          anchorToScreen: svc.read(SettingsService.subtitleAnchorToScreen),
        );
      }
    } catch (_) {
      // La preferenza è salvata comunque: si applica al prossimo avvio.
    }
  }

  Future<void> _changeDelay(int deltaMs) async {
    final next = _delayMs + deltaMs;
    setState(() => _delayMs = next);
    final player = widget.player;
    try {
      await player.setProperty(PlayerSyncOffsets.subtitleProperty, (next / 1000.0).toString());
      PlayerSyncOffsets.of(player).recordApplied(PlayerSyncOffsets.subtitleProperty, next);
      await ScopedPlayerPrefs.write(ScopedPlayerPrefs.subtitleSyncOffset, widget.state.metadata, next);
    } catch (_) {
      // Il ritardo resta quello precedente se il player non lo accetta.
    }
  }

  Widget _group({
    required String label,
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 6),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '$label −',
          icon: const AppIcon(Symbols.remove_rounded),
          onPressed: onMinus,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44),
          child: Text(value, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '$label +',
          icon: const AppIcon(Symbols.add_rounded),
          onPressed: onPlus,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          _group(
            label: 'Dimensione',
            value: '$_size',
            onMinus: () => unawaited(_changeSize(-_sizeStep)),
            onPlus: () => unawaited(_changeSize(_sizeStep)),
          ),
          _group(
            label: 'Ritardo',
            value: formatSyncOffset(_delayMs.toDouble()),
            onMinus: () => unawaited(_changeDelay(-_delayStepMs)),
            onPlus: () => unawaited(_changeDelay(_delayStepMs)),
          ),
        ],
      ),
    );
  }
}
