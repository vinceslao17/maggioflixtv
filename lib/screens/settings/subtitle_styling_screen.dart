import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/settings_service.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import 'settings_utils.dart';

class SubtitleStylingScreen extends StatelessWidget {
  const SubtitleStylingScreen({super.key});

  String _assOverrideLabel(SubAssOverride value) {
    return switch (value) {
      SubAssOverride.no => t.common.no,
      SubAssOverride.yes => t.common.yes,
      SubAssOverride.scale => t.subtitlingStyling.overrideScale,
      SubAssOverride.force => t.subtitlingStyling.overrideForce,
      SubAssOverride.strip => t.subtitlingStyling.overrideStrip,
    };
  }

  String _formatPosition(int value) {
    if (value == 0) return t.subtitlingStyling.positionTop;
    if (value == 100) return t.subtitlingStyling.positionBottom;
    return '$value%';
  }

  String _renderResolutionLabel(SubtitleRenderResolution value) {
    return switch (value) {
      SubtitleRenderResolution.screen => t.subtitlingStyling.renderResolutionScreen,
      SubtitleRenderResolution.video => t.subtitlingStyling.renderResolutionVideo,
      SubtitleRenderResolution.threeQuarter => '¾',
      SubtitleRenderResolution.half => '½',
      SubtitleRenderResolution.third => '⅓',
      SubtitleRenderResolution.quarter => '¼',
    };
  }

  @override
  Widget build(BuildContext context) {
    // Each backend exposes its own text-subtitle placement preference.
    final exoActive = Platform.isAndroid && SettingsService.instance.read(SettingsService.useExoPlayer);
    return SettingsPage.slivers(
      title: Text(t.screens.subtitleStyling),
      slivers: [
        const SliverPersistentHeader(pinned: true, delegate: _SubtitlePreviewHeader()),
        SliverList(delegate: SliverChildListDelegate(_buildGroups(exoActive))),
      ],
    );
  }

  List<Widget> _buildGroups(bool exoActive) {
    return [
        SettingsGroup(
          title: t.subtitlingStyling.text,
          children: [
            SettingSelectionTile<SubAssOverride>(
              pref: SettingsService.subAssOverride,
              icon: Symbols.subtitles_rounded,
              title: t.subtitlingStyling.assOverride,
              subtitleBuilder: _assOverrideLabel,
              options: SubAssOverride.values.map((v) => DialogOption(value: v, title: _assOverrideLabel(v))).toList(),
            ),
            // Apple avfoundation VO: screen vs video-resolution basis.
            if (Platform.isIOS || Platform.isMacOS)
              SettingSelectionTile<SubtitleRenderResolution>(
                pref: SettingsService.subtitleRenderResolution,
                icon: Symbols.aspect_ratio_rounded,
                title: t.subtitlingStyling.renderResolution,
                subtitleBuilder: _renderResolutionLabel,
                options: const [
                  SubtitleRenderResolution.screen,
                  SubtitleRenderResolution.video,
                ].map((v) => DialogOption(value: v, title: _renderResolutionLabel(v))).toList(),
              ),
            // Android libass overlay: full or a fractional render scale (perf knob for
            // render-bound low-end TVs; heavy/animated signs raster faster at < 1).
            if (Platform.isAndroid)
              SettingSelectionTile<SubtitleRenderResolution>(
                pref: SettingsService.subtitleRenderResolution,
                icon: Symbols.aspect_ratio_rounded,
                title: t.subtitlingStyling.renderResolution,
                subtitleBuilder: _renderResolutionLabel,
                options: const [
                  SubtitleRenderResolution.screen,
                  SubtitleRenderResolution.threeQuarter,
                  SubtitleRenderResolution.half,
                  SubtitleRenderResolution.third,
                  SubtitleRenderResolution.quarter,
                ].map((v) => DialogOption(value: v, title: _renderResolutionLabel(v))).toList(),
              ),
            SettingNumberTile(
              pref: SettingsService.subtitleFontSize,
              icon: Symbols.format_size_rounded,
              title: t.subtitlingStyling.fontSize,
              subtitleBuilder: (v) => '$v',
              labelText: t.subtitlingStyling.fontSize,
              suffixText: '',
            ),
            SettingColorTile(
              pref: SettingsService.subtitleTextColor,
              icon: Symbols.format_color_text_rounded,
              title: t.subtitlingStyling.textColor,
            ),
            SettingNumberTile(
              pref: SettingsService.subtitlePosition,
              icon: Symbols.vertical_align_bottom_rounded,
              title: t.subtitlingStyling.position,
              subtitleBuilder: _formatPosition,
              labelText: t.subtitlingStyling.position,
              suffixText: '%',
            ),
            if (!exoActive)
              SettingSwitchTile(
                pref: SettingsService.subtitleUseMargins,
                icon: Symbols.fit_screen_rounded,
                title: t.subtitlingStyling.useMargins,
                subtitle: t.subtitlingStyling.useMarginsDescription,
              ),
            if (exoActive)
              SettingSwitchTile(
                pref: SettingsService.subtitleAnchorToScreen,
                icon: Symbols.fit_screen_rounded,
                title: t.subtitlingStyling.anchorToScreen,
                subtitle: t.subtitlingStyling.anchorToScreenDescription,
              ),
            SettingSwitchTile(
              pref: SettingsService.subtitleBold,
              icon: Symbols.format_bold_rounded,
              title: t.subtitlingStyling.bold,
            ),
            SettingSwitchTile(
              pref: SettingsService.subtitleItalic,
              icon: Symbols.format_italic_rounded,
              title: t.subtitlingStyling.italic,
            ),
          ],
        ),

        SettingsGroup(
          title: t.subtitlingStyling.border,
          children: [
            SettingNumberTile(
              pref: SettingsService.subtitleBorderSize,
              icon: Symbols.border_style_rounded,
              title: t.subtitlingStyling.borderSize,
              subtitleBuilder: (v) => '$v',
              labelText: t.subtitlingStyling.borderSize,
              suffixText: '',
            ),
            SettingColorTile(
              pref: SettingsService.subtitleBorderColor,
              icon: Symbols.border_color_rounded,
              title: t.subtitlingStyling.borderColor,
            ),
          ],
        ),

        SettingsGroup(
          title: t.subtitlingStyling.background,
          children: [
            SettingNumberTile(
              pref: SettingsService.subtitleBackgroundOpacity,
              icon: Symbols.opacity_rounded,
              title: t.subtitlingStyling.backgroundOpacity,
              subtitleBuilder: (v) => '$v%',
              labelText: t.subtitlingStyling.backgroundOpacity,
              suffixText: '%',
            ),
            SettingColorTile(
              pref: SettingsService.subtitleBackgroundColor,
              icon: Symbols.format_color_fill_rounded,
              title: t.subtitlingStyling.backgroundColor,
            ),
          ],
        ),
        const SizedBox(height: 24),
    ];
  }
}

/// Anteprima fissa in alto: mostra un esempio di sottotitolo con dimensione,
/// colori, bordo e sfondo scelti, in proporzione a un video 16:9.
class _SubtitlePreviewHeader extends SliverPersistentHeaderDelegate {
  const _SubtitlePreviewHeader();

  static const double _padding = 8;

  double _frameHeight(double width) => (width * 9 / 16).clamp(90.0, 150.0).toDouble();

  @override
  double get minExtent => 98 + _padding * 2;

  @override
  double get maxExtent => 150 + _padding * 2;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final frameH = _frameHeight(constraints.maxWidth - 32).clamp(90.0, constraints.maxHeight - _padding * 2).toDouble();
        final frameW = (frameH * 16 / 9).clamp(0.0, constraints.maxWidth - 32).toDouble();
        return Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: _padding),
          alignment: Alignment.center,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(width: frameW, height: frameH, child: _SubtitlePreviewFrame(frameHeight: frameH)),
          ),
        );
      },
    );
  }

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) => false;
}

class _SubtitlePreviewFrame extends StatelessWidget {
  final double frameHeight;
  const _SubtitlePreviewFrame({required this.frameHeight});

  @override
  Widget build(BuildContext context) {
    final svc = SettingsService.instance;
    final listenable = svc.listenableOfAll([
      SettingsService.subtitleFontSize,
      SettingsService.subtitleTextColor,
      SettingsService.subtitleBorderSize,
      SettingsService.subtitleBorderColor,
      SettingsService.subtitleBackgroundColor,
      SettingsService.subtitleBackgroundOpacity,
      SettingsService.subtitleBold,
      SettingsService.subtitleItalic,
      SettingsService.subtitlePosition,
    ]);
    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        // La dimensione del player è riferita a un video alto 720: si scala sul riquadro.
        final scale = frameHeight / 720;
        final fontSize = svc.read(SettingsService.subtitleFontSize).toDouble() * scale;
        final borderSize = svc.read(SettingsService.subtitleBorderSize).toDouble() * scale;
        final bgOpacity = (svc.read(SettingsService.subtitleBackgroundOpacity) / 100).clamp(0.0, 1.0);
        final position = svc.read(SettingsService.subtitlePosition).clamp(0, 100).toDouble();
        final textColor = hexToColor(svc.read(SettingsService.subtitleTextColor));
        final borderColor = hexToColor(svc.read(SettingsService.subtitleBorderColor));
        final bgColor = hexToColor(svc.read(SettingsService.subtitleBackgroundColor)).withValues(alpha: bgOpacity);
        final weight = svc.read(SettingsService.subtitleBold) ? FontWeight.w700 : FontWeight.w500;
        final style = svc.read(SettingsService.subtitleItalic) ? FontStyle.italic : FontStyle.normal;
        const sample = 'Questo è un esempio\ndi sottotitolo';

        TextStyle base() => TextStyle(fontSize: fontSize, fontWeight: weight, fontStyle: style, height: 1.15);

        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3A4252), Color(0xFF1B1F27)],
            ),
          ),
          child: Align(
            alignment: Alignment(0, -0.85 + 1.7 * position / 100),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 6 * scale + 2, vertical: 2),
                color: bgColor,
                child: Stack(
                  children: [
                    if (borderSize > 0)
                      Text(
                        sample,
                        textAlign: TextAlign.center,
                        style: base().copyWith(
                          foreground: Paint()
                            ..style = PaintingStyle.stroke
                            ..strokeWidth = borderSize * 2
                            ..strokeJoin = StrokeJoin.round
                            ..color = borderColor,
                        ),
                      ),
                    Text(sample, textAlign: TextAlign.center, style: base().copyWith(color: textColor)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
