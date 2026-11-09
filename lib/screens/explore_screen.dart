import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/focusable_action_bar.dart';
import '../focus/hub_vertical_navigation.dart';
import '../focus/locked_hub_controller.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../mixins/debounced_media_search.dart';
import '../mixins/refreshable.dart';
import '../mixins/tab_visibility_aware.dart';
import '../models/catalog/catalog_item.dart';
import '../navigation/main_screen_scope.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/explore_provider.dart';
import '../services/catalog/catalog_source.dart';
import '../services/settings_service.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_menu.dart';
import '../widgets/catalog_source_logo.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/hub_section.dart';
import '../widgets/focusable_media_card.dart';
import '../widgets/focusable_popup_menu_button.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/search_input_field.dart';
import '../widgets/settings_builder.dart';
import '../widgets/toolbar_scrim.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import 'catalog_search_screen.dart';
import 'libraries/state_messages.dart';
import '../maggioflix/requests.dart';
import '../maggioflix/calendar.dart';
import '../maggioflix/live.dart';
import '../media/catalog_item_ref.dart';
import '../media/media_kind.dart';
import '../models/catalog/catalog_metadata.dart';
import '../services/catalog/seerr_catalog_source.dart';
import '../services/deep_links/deep_link_service.dart';
import '../utils/catalog_navigation_helper.dart';
import '../widgets/seerr_request_sheet.dart';

/// The Explore tab: watchlist + discover rows from the active external
/// catalog source (Trakt). Only mounted when a source is connected (the tab
/// is hidden otherwise, see [NavigationTab.getVisibleTabs]).
///
/// Touch/pointer builds carry an inline search field under the app bar whose
/// results replace the rows while the query is non-empty. TV keeps the
/// toolbar's search action instead: a text field cannot share the spotlight
/// scaffold with the bottom-pinned browse rail and the on-screen keyboard,
/// so that path pushes [CatalogSearchScreen].
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => ExploreScreenState();
}

class ExploreScreenState extends State<ExploreScreen>
    with
        ManualRefreshable,
        FullRefreshable,
        TabVisibilityAware,
        FocusableTab,
        DebouncedMediaSearch<ExploreScreen, MediaItem> {
  late ExploreProvider _explore;
  late CatalogSourcesProvider _sources;
  CatalogSourceId? _activeSourceId;

  /// Per-row focus keys, keyed by hub id so focus memory survives reloads.
  final Map<String, GlobalKey<HubSectionState>> _hubKeysById = {};
  List<GlobalKey<HubSectionState>> _orderedHubKeys = const [];
  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _sourceMenuKey = GlobalKey<AppMenuButtonState<CatalogSourceId>>();

  final _tvBrowseRailKey = GlobalKey<TvBrowseRailState>();

  // MaggioFlix (telefono): schede Scopri / Richieste / Calendario.
  int _mfTab = 0;
  bool _mfCalendarOpened = false;
  bool _mfTabVisible = true;
  _MfDiscoverFilter _mfFilter = _MfDiscoverFilter.all;
  final MfRequestsController _mfRequests = MfRequestsController()..pollingEnabled = false;
  bool get _mfTabbed => !PlatformDetector.isTV() && !PlatformDetector.isDesktopOS();
  VoidCallback? _releaseLive;

  void _watchLive(bool on) {
    if (on) {
      _releaseLive ??= MaggioflixLive.instance.watch(_sources.seerrSource);
    } else {
      _releaseLive?.call();
      _releaseLive = null;
    }
  }
  final _hubFocusMemory = HubFocusMemory();
  final TvSpotlightController _spotlight = TvSpotlightController();

  @override
  String get searchDebugLabel => 'ExploreSearch';

  /// Results take over the page the moment the field holds text: the mixin's
  /// [hasSearched] only flips once a query actually runs, so keying the swap
  /// off that would flash the rows back for the length of every debounce.
  bool get searchIsActive => searchController.text.trim().isNotEmpty;

  @override
  Future<List<MediaItem>> performSearchQuery(String query) async {
    final source = _explore.activeSource;
    if (source == null) return const [];
    final items = await source.search(query);
    return [for (final item in items) item.toMediaItem()];
  }

  @override
  void initState() {
    super.initState();
    _explore = context.read<ExploreProvider>();
    _explore.ensureFresh();
    _sources = context.read<CatalogSourcesProvider>();
    _activeSourceId = _sources.activeSource?.id;
    _sources.addListener(_onActiveSourceChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _mfTabVisible) _watchLive(true);
    });
    if (_mfTabbed) {
      _mfRequests.addListener(_onMfRequestsChanged);
      _scheduleMfBind();
    }
  }

  void _scheduleMfBind() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _mfTabbed) _mfRequests.bind(_sources.seerrSource);
    });
  }

  void _onMfRequestsChanged() {
    if (mounted) setState(() {});
  }

  void _setMfTab(int index) {
    if (index == _mfTab) return;
    setState(() {
      _mfTab = index;
      if (index == 2) _mfCalendarOpened = true;
    });
    _updateMfPolling();
    if (index == 1) _mfRequests.silentReload();
  }

  void _updateMfPolling() => _mfRequests.pollingEnabled = _mfTabVisible && _mfTab == 1;

  /// A live query belongs to the source it was typed against, so a source
  /// switch re-runs it instead of leaving the previous source's results
  /// sitting under the new source's name.
  void _onActiveSourceChanged() {
    if (_mfTabbed) _scheduleMfBind();
    MaggioflixLive.instance.updateSource(_sources.seerrSource);
    final id = _sources.activeSource?.id;
    if (id == _activeSourceId) return;
    _activeSourceId = id;
    if (!mounted) return;
    final query = searchController.text.trim();
    if (query.isEmpty) return;
    unawaited(runSearch(query));
  }

  @override
  void manualRefresh() => unawaited(_handleRefresh());

  /// Pull-to-refresh and the toolbar refresh action: re-run the query that is
  /// actually on screen, not the hidden rows behind it.
  Future<void> _handleRefresh() {
    final query = searchController.text.trim();
    if (query.isNotEmpty) return runSearch(query);
    return _explore.load();
  }

  @override
  void fullRefresh() {
    // Clearing routes through the text listener, which resets the search state.
    searchController.clear();
    unawaited(_explore.load());
  }

  @override
  void onTabShown() {
    _explore.ensureFresh();
    _mfTabVisible = true;
    _watchLive(true);
    _updateMfPolling();
    if (_mfTabbed) _mfRequests.silentReload();
  }

  @override
  void onTabHidden() {
    _mfTabVisible = false;
    _watchLive(false);
    _updateMfPolling();
  }

  @override
  void dispose() {
    _sources.removeListener(_onActiveSourceChanged);
    _watchLive(false);
    _mfRequests.removeListener(_onMfRequestsChanged);
    _mfRequests.dispose();
    _spotlight.dispose();
    super.dispose();
  }

  @override
  void focusActiveTabIfReady() {
    if (PlatformDetector.isTV()) {
      if (_explore.rowHubs.isNotEmpty) {
        _tvBrowseRailKey.currentState?.requestFocus();
      } else {
        _actionBarKey.currentState?.requestFocusOnFirst();
      }
      return;
    }
    if (searchIsActive) {
      // Never re-open the soft keyboard on a tab switch when results are
      // already there to land on.
      if (searchResults.isNotEmpty) {
        firstResultFocusNode.requestFocus();
      } else {
        searchFocusNode.requestFocus();
      }
      return;
    }
    _orderedHubKeys.firstOrNull?.currentState?.requestFocusFromMemory();
  }

  void _setSpotlightItem(MediaItem item) => _spotlight.select(item);

  void _updateHubKeys(List<ExploreRowHub> rowHubs) {
    final liveIds = <String>{for (final rowHub in rowHubs) rowHub.hub.id};
    _hubKeysById.removeWhere((id, _) => !liveIds.contains(id));
    _orderedHubKeys = [
      for (final rowHub in rowHubs) _hubKeysById.putIfAbsent(rowHub.hub.id, GlobalKey<HubSectionState>.new),
    ];
  }

  bool _handleVerticalNavigation(int hubIndex, bool isUp) {
    final keys = _orderedHubKeys;
    return navigateVerticalHubRows(
      hubCount: keys.length,
      hubIndex: hubIndex,
      isUp: isUp,
      onTopBoundary: searchFocusNode.requestFocus,
      requestFocus: (targetIndex) {
        keys[targetIndex].currentState?.requestFocusFromMemory();
      },
    );
  }

  void _navigateToSidebar() {
    MainScreenFocusScope.focusSidebarOf(context);
  }

  static IconData _rowIcon(CatalogRowId? row) => switch (row) {
    null => Symbols.thumb_up_rounded,
    CatalogRowId.watchlist => Symbols.bookmark_rounded,
    CatalogRowId.recommendedMovies ||
    CatalogRowId.recommendedShows ||
    CatalogRowId.suggestedAnime => Symbols.thumb_up_rounded,
    CatalogRowId.trendingMovies ||
    CatalogRowId.trendingShows ||
    CatalogRowId.trendingAnime ||
    CatalogRowId.airingAnime ||
    CatalogRowId.trending => Symbols.trending_up_rounded,
    CatalogRowId.popularMovies || CatalogRowId.popularShows || CatalogRowId.popularAnime => Symbols.whatshot_rounded,
    CatalogRowId.upcomingMovies || CatalogRowId.upcomingShows => Symbols.event_upcoming_rounded,
  };

  List<AppMenuEntry<CatalogSourceId>> _sourceMenuEntries(CatalogSourcesProvider sources, CatalogSource active) => [
    for (final source in sources.exploreSources)
      AppMenuItem<CatalogSourceId>(
        value: source.id,
        leading: CatalogSourceLogo(source.id),
        label: source.displayName,
        selected: source.id == active.id,
      ),
  ];

  Widget _buildSourceSwitcher(
    CatalogSourcesProvider sources,
    CatalogSource active, {
    TextStyle? textStyle,
    AppMenuAnchorAlignment anchorAlignment = AppMenuAnchorAlignment.start,
    bool parentOwnsFocus = false,
  }) {
    final trigger = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: .min,
        children: [
          CatalogSourceLogo(active.id, size: 22),
          const SizedBox(width: 8),
          Text(active.displayName, style: textStyle ?? Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 4),
          const AppIcon(Symbols.arrow_drop_down_rounded, fill: 1, size: 24),
        ],
      ),
    );
    if (parentOwnsFocus) {
      return AppMenuButton<CatalogSourceId>(
        key: _sourceMenuKey,
        tooltip: t.explore.selectSource,
        anchorAlignment: anchorAlignment,
        onSelected: (id) => unawaited(sources.setActiveSource(id)),
        entriesBuilder: (context) => _sourceMenuEntries(sources, active),
        child: trigger,
      );
    }
    return FocusablePopupMenuButton<CatalogSourceId>(
      menuKey: _sourceMenuKey,
      tooltip: t.explore.selectSource,
      semanticLabel: t.explore.selectSource,
      semanticValue: active.displayName,
      anchorAlignment: anchorAlignment,
      onSelected: (id) => unawaited(sources.setActiveSource(id)),
      itemBuilder: (context) => _sourceMenuEntries(sources, active),
      child: trigger,
    );
  }

  /// App-bar title: the active source name, as a switcher dropdown when more
  /// than one source is connected (mirrors the libraries dropdown).
  Widget _buildTitle(CatalogSourcesProvider sources) {
    final active = sources.activeSource;
    if (active == null) return Text(t.explore.title);
    if (sources.exploreSources.length < 2) {
      return Text(active.displayName);
    }
    return _buildSourceSwitcher(sources, active);
  }

  @override
  Widget build(BuildContext context) {
    final explore = context.watch<ExploreProvider>();
    final sources = context.watch<CatalogSourcesProvider>();
    final rowHubs = explore.rowHubs;
    _updateHubKeys(rowHubs);

    // The TV toolbar must remain mounted for loading, error, and empty
    // sources so users can always switch away from a source with no rows.
    if (PlatformDetector.isTV()) {
      return SettingsBuilder(
        prefs: const [SettingsService.hideSpoilers, SettingsService.libraryDensity, SettingsService.episodePosterMode],
        builder: (context) => _buildTvContent(rowHubs, sources),
      );
    }

    if (_mfTabbed) return _buildMaggioflixPhone(context, explore, sources, rowHubs);

    // One header mode for every state. Flipping floating/pinned between the
    // loading/empty scroll view and the content scroll view swaps the
    // SliverPersistentHeader variant (a different element type), which
    // reparents the GlobalKey'd action bar into a header that builds its
    // children during performLayout — and if a tooltip overlay is showing at
    // that moment (hover on refresh), its OverlayPortal re-activation
    // mutates the render tree mid-layout and asserts. Floating behaves
    // identically to pinned over the non-scrolling state widgets, so nothing
    // is lost by unifying.
    Widget appBar() => DesktopSliverAppBar(
      title: _buildTitle(sources),
      pinned: false,
      floating: true,
      snap: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      scrolledUnderElevation: 0,
      actions: [
        FocusableActionBar(
          key: _actionBarKey,
          onNavigateDown: searchFocusNode.requestFocus,
          actions: [
            if (sources.seerrSource != null)
              FocusableAction(
                icon: Symbols.list_alt_rounded,
                tooltip: maggioflixMyRequestsLabel(),
                onPressed: () => openMaggioflixRequests(context),
              ),
            FocusableAction(icon: Symbols.refresh_rounded, tooltip: t.common.refresh, onPressed: manualRefresh),
          ],
        ),
      ],
    );

    // The field sits in every state, so the sliver list keeps one shape and
    // search stays reachable while the rows are loading, empty, or failed.
    Widget searchField() => SliverToBoxAdapter(
      child: SearchInputField(
        controller: searchController,
        focusNode: searchFocusNode,
        debugLabel: searchDebugLabel,
        hintText: t.common.search,
        onNavigateLeft: _navigateToSidebar,
        onNavigateDown: _searchFieldDownTarget(),
        onEditingComplete: handleSearchSubmit,
      ),
    );

    Widget scroll(List<Widget> body) => CustomScrollView(
      // Android clamping physics won't start a drag on non-filling
      // content, killing pull-to-refresh in the loading/empty/error
      // states without this.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        appBar(),
        SliverToBoxAdapter(child: MaggioflixQuotaBanner(onOpenRequests: () => openMaggioflixRequests(context))),
        searchField(),
        ...body,
      ],
    );

    Widget content;
    if (searchIsActive) {
      content = scroll([_buildSearchResults()]);
    } else if (rowHubs.isEmpty && explore.isLoading) {
      content = scroll(const [SliverFillRemaining(child: Center(child: CircularProgressIndicator()))]);
    } else if (rowHubs.isEmpty && explore.state == ExploreLoadState.error) {
      content = scroll([
        SliverFillRemaining(
          child: ErrorStateWidget(
            message: explore.errorMessage ?? t.explore.emptyTitle,
            icon: Symbols.error_outline_rounded,
            onRetry: () => unawaited(_explore.load()),
          ),
        ),
      ]);
    } else if (rowHubs.isEmpty) {
      content = scroll([
        SliverFillRemaining(
          child: EmptyStateWidget(
            message: t.explore.emptyMessage(source: explore.activeSource?.displayName ?? ''),
            icon: Symbols.library_add_rounded,
          ),
        ),
      ]);
    } else {
      content = scroll([
        for (var i = 0; i < rowHubs.length; i++)
          SliverToBoxAdapter(
            child: HubSection(
              key: _orderedHubKeys[i],
              hub: rowHubs[i].hub,
              totalResults: rowHubs[i].totalResults,
              focusMemory: _hubFocusMemory,
              icon: _rowIcon(rowHubs[i].row),
              loadMoreItems: rowHubs[i].hub.more ? () => _explore.loadAllForHub(rowHubs[i]) : null,
              onVerticalNavigation: (isUp) => _handleVerticalNavigation(i, isUp),
              onNavigateUp: i == 0 ? searchFocusNode.requestFocus : null,
              onNavigateToSidebar: _navigateToSidebar,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ]);
    }

    return Scaffold(
      // Horizontal-only SafeArea, as on Search: the field, shelves, and
      // results clear a landscape notch or iPhone Duo's portrait sensor column.
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        child: SafeArea(top: false, bottom: false, child: content),
      ),
    );
  }

  /// DOWN out of the field: the first result when there is one to land on,
  /// otherwise the first shelf behind the (empty) query.
  VoidCallback? _searchFieldDownTarget() {
    if (searchIsActive) {
      return searchResults.isNotEmpty && !isSearching ? firstResultFocusNode.requestFocus : null;
    }
    final first = _orderedHubKeys.firstOrNull;
    if (first == null) return null;
    return () => first.currentState?.requestFocusFromMemory();
  }

  Widget _buildSearchResults() {
    if (isSearching) return LoadingIndicatorBox.sliver;
    if (lastSearchFailed) {
      return SliverFillRemaining(
        child: StateMessageWidget(message: t.explore.searchFailed, icon: Symbols.error_rounded, iconSize: 80),
      );
    }
    // The debounce window right after the field goes from empty to typed: no
    // query has run yet, so there is nothing truthful to show.
    if (!hasSearched) return const SliverToBoxAdapter(child: SizedBox.shrink());
    if (searchResults.isEmpty) {
      return SliverFillRemaining(
        child: StateMessageWidget(
          message: t.explore.searchEmpty(query: lastSearchedQuery),
          icon: Symbols.search_off_rounded,
          iconSize: 80,
        ),
      );
    }
    return buildResultsSliver((context, index) {
      final item = searchResults[index];
      return FocusableMediaCard(
        key: Key(item.globalKey),
        item: item,
        viewModeOverride: ViewMode.list,
        disableScale: true,
        focusNode: index == 0 ? firstResultFocusNode : null,
        onNavigateLeft: _navigateToSidebar,
        onNavigateUp: index == 0 ? searchFocusNode.requestFocus : null,
      );
    });
  }

  ExploreRowHub? _rowForHub(MediaHub hub) {
    for (final rowHub in _explore.rowHubs) {
      if (rowHub.hub.id == hub.id) return rowHub;
    }
    return null;
  }

  Widget _buildTvToolbar(CatalogSourcesProvider sources) {
    final active = sources.activeSource;
    final foregroundColor = Theme.of(context).colorScheme.onSurface;

    return ToolbarScrim(
      child: Row(
        children: [
          const Spacer(),
          const MaggioflixQuotaBanner(compact: true),
          const SizedBox(width: 16),
          FocusableActionBar(
            key: _actionBarKey,
            onNavigateLeft: _navigateToSidebar,
            onNavigateDown: _tvBrowseRailKey.currentState?.requestFocus,
            onBack: _navigateToSidebar,
            spacing: 4,
            actions: [
              if (active != null && sources.exploreSources.length > 1)
                FocusableAction(
                  debugLabel: 'ExploreSourceSwitcher',
                  onPressed: () => _sourceMenuKey.currentState?.showButtonMenu(focusFirstItem: true),
                  child: _buildSourceSwitcher(
                    sources,
                    active,
                    textStyle: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: foregroundColor, fontWeight: .w600),
                    anchorAlignment: AppMenuAnchorAlignment.end,
                    parentOwnsFocus: true,
                  ),
                ),
              if (active != null)
                FocusableAction(
                  icon: Symbols.search_rounded,
                  iconColor: foregroundColor,
                  tooltip: t.common.search,
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => CatalogSearchScreen(source: active))),
                ),
              FocusableAction(
                icon: Symbols.refresh_rounded,
                iconColor: foregroundColor,
                tooltip: t.common.refresh,
                onPressed: () => unawaited(_explore.load()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // MaggioFlix: pagina Richiedi del telefono
  // ---------------------------------------------------------------------------

  String _mfTr(String it, String en) => LocaleSettings.currentLocale.languageCode == 'it' ? it : en;

  Widget _buildMaggioflixPhone(
    BuildContext context,
    ExploreProvider explore,
    CatalogSourcesProvider sources,
    List<ExploreRowHub> rowHubs,
  ) {
    final theme = Theme.of(context);
    final header = SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t.navigation.explore,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (sources.seerrSource != null)
                  MaggioflixQuotaBanner(style: MfQuotaStyle.pill, onOpenRequests: () => _setMfTab(1)),
              ],
            ),
          ),
          SearchInputField(
            controller: searchController,
            focusNode: searchFocusNode,
            debugLabel: searchDebugLabel,
            hintText: _mfTr('Cerca film e serie', 'Search movies and shows'),
            onEditingComplete: handleSearchSubmit,
          ),
          if (!searchIsActive)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: _MfSegmentedTabs(
                index: _mfTab,
                labels: [
                  _mfTr('Scopri', 'Discover'),
                  _mfTr('Richieste', 'Requests'),
                  maggioflixCalendarLabel(),
                ],
                badges: [0, _mfRequests.activeCount, 0],
                onChanged: _setMfTab,
              ),
            ),
        ],
      ),
    );

    final Widget body;
    if (searchIsActive) {
      body = RefreshIndicator(
        onRefresh: _handleRefresh,
        child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [_buildSearchResults()]),
      );
    } else {
      body = IndexedStack(
        index: _mfTab,
        children: [
          _buildMfDiscover(explore, sources, rowHubs),
          MaggioflixRequestsTab(controller: _mfRequests),
          if (_mfCalendarOpened) const MaggioflixCalendarView() else const SizedBox.shrink(),
        ],
      );
    }

    return Scaffold(
      body: Column(
        children: [
          header,
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _buildMfDiscover(ExploreProvider explore, CatalogSourcesProvider sources, List<ExploreRowHub> rowHubs) {
    final kind = switch (_mfFilter) {
      _MfDiscoverFilter.all => null,
      _MfDiscoverFilter.movies => MediaKind.movie,
      _MfDiscoverFilter.series => MediaKind.show,
    };
    final rows = <({ExploreRowHub row, MediaHub hub})>[
      for (final rowHub in rowHubs)
        if (kind == null)
          (row: rowHub, hub: rowHub.hub)
        else if (rowHub.hub.items.where((i) => i.kind == kind).toList() case final items when items.isNotEmpty)
          (
            row: rowHub,
            hub: MediaHub(
              id: rowHub.hub.id,
              identifier: rowHub.hub.identifier,
              title: rowHub.hub.title,
              type: rowHub.hub.type,
              items: items,
              size: items.length,
            ),
          ),
    ];

    // Titolo in evidenza: il primo della prima riga con un'immagine di sfondo.
    MediaItem? heroItem;
    CatalogItem? heroCatalog;
    String? heroLabel;
    for (final r in rows) {
      for (final item in r.hub.items) {
        final catalog = item.catalogItem;
        if (catalog != null && catalog.backdropUrl != null) {
          heroItem = item;
          heroCatalog = catalog;
          heroLabel = r.hub.title;
          break;
        }
      }
      if (heroItem != null) break;
    }

    Widget chip(String label, _MfDiscoverFilter value) => ChoiceChip(
      label: Text(label),
      selected: _mfFilter == value,
      showCheckmark: false,
      onSelected: (_) => setState(() => _mfFilter = value),
    );

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              chip(_mfTr('Tutto', 'All'), _MfDiscoverFilter.all),
              chip(_mfTr('Film', 'Movies'), _MfDiscoverFilter.movies),
              chip(_mfTr('Serie TV', 'TV shows'), _MfDiscoverFilter.series),
            ],
          ),
        ),
      ),
    ];

    if (rowHubs.isEmpty && explore.isLoading) {
      slivers.add(const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator())));
    } else if (rowHubs.isEmpty && explore.state == ExploreLoadState.error) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorStateWidget(
            message: explore.errorMessage ?? t.explore.emptyTitle,
            icon: Symbols.error_outline_rounded,
            onRetry: () => unawaited(_explore.load()),
          ),
        ),
      );
    } else if (rows.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget(
            message: t.explore.emptyMessage(source: explore.activeSource?.displayName ?? ''),
            icon: Symbols.library_add_rounded,
          ),
        ),
      );
    } else {
      if (heroItem != null && heroCatalog != null) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _MfHeroCard(item: heroCatalog, label: heroLabel, seerr: sources.seerrSource),
            ),
          ),
        );
      }
      for (var i = 0; i < rows.length; i++) {
        final filtered = kind != null;
        slivers.add(
          SliverToBoxAdapter(
            child: HubSection(
              key: filtered ? null : _hubKeysById[rows[i].hub.id],
              hub: rows[i].hub,
              totalResults: filtered ? null : rows[i].row.totalResults,
              focusMemory: _hubFocusMemory,
              icon: _rowIcon(rows[i].row.row),
              loadMoreItems: !filtered && rows[i].hub.more ? () => _explore.loadAllForHub(rows[i].row) : null,
              onNavigateToSidebar: _navigateToSidebar,
            ),
          ),
        );
      }
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    }

    return RefreshIndicator(
      onRefresh: _handleRefresh,
      child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: slivers),
    );
  }

  Widget _buildTvContent(List<ExploreRowHub> rowHubs, CatalogSourcesProvider sources) {
    final tvHubs = [for (final rowHub in rowHubs) rowHub.hub];
    return TvSpotlightScaffold(
      hubs: tvHubs,
      spotlightListenable: _spotlight,
      resolveSpotlight: () => _spotlight.resolve(tvHubs),
      resolveClient: (spotlight) => context.tryGetMediaClientForServer(serverIdOrNull(spotlight?.serverId)),
      foreground: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          if (tvHubs.isEmpty && _explore.isLoading)
            const Center(child: CircularProgressIndicator())
          else if (tvHubs.isEmpty && _explore.state == ExploreLoadState.error)
            Center(
              child: ErrorStateWidget(
                message: _explore.errorMessage ?? t.explore.emptyTitle,
                icon: Symbols.error_outline_rounded,
                onRetry: () => unawaited(_explore.load()),
              ),
            )
          else if (tvHubs.isEmpty)
            Center(
              child: EmptyStateWidget(
                message: t.explore.emptyMessage(source: _explore.activeSource?.displayName ?? ''),
                icon: Symbols.library_add_rounded,
              ),
            ),
          if (tvHubs.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TvBrowseRail(
                key: _tvBrowseRailKey,
                hubs: tvHubs,
                focusMemory: _hubFocusMemory,
                iconForHub: (hub, _) => _rowIcon(_rowForHub(hub)?.row),
                onFocusedItemChanged: _setSpotlightItem,
                loadMoreItems: (hub) {
                  final rowHub = _rowForHub(hub);
                  return rowHub == null ? () => Future.value(hub.items) : () => _explore.loadAllForHub(rowHub);
                },
                onNavigateUp: _actionBarKey.currentState?.requestFocusOnFirst,
                onNavigateToSidebar: _navigateToSidebar,
                onBack: _navigateToSidebar,
                tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
                widePosterScale: TvBrowseRailLayout.compactEpisodeThumbnailScale,
              ),
            ),
          TvToolbarOverlay(child: _buildTvToolbar(sources)),
        ],
      ),
    );
  }
}


enum _MfDiscoverFilter { all, movies, series }

/// Tre schede a pillola in alto nella pagina Richiedi del telefono.
class _MfSegmentedTabs extends StatelessWidget {
  final int index;
  final List<String> labels;
  final List<int> badges;
  final ValueChanged<int> onChanged;

  const _MfSegmentedTabs({required this.index, required this.labels, required this.badges, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                selected: i == index,
                button: true,
                child: Material(
                  color: i == index ? theme.colorScheme.onSurface : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onChanged(i),
                    child: SizedBox(
                      height: 38,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              labels[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: i == index
                                    ? theme.colorScheme.surface
                                    : theme.colorScheme.onSurface.withValues(alpha: 0.75),
                                fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (badges[i] > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              constraints: const BoxConstraints(minWidth: 18),
                              height: 18,
                              padding: const EdgeInsets.symmetric(horizontal: 5),
                              decoration: BoxDecoration(
                                color: const Color(0xFFC9262B),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${badges[i]}',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Titolo in evidenza in cima a "Scopri": sfondo, dati essenziali e azioni.
class _MfHeroCard extends StatelessWidget {
  final CatalogItem item;
  final String? label;
  final SeerrCatalogSource? seerr;

  const _MfHeroCard({required this.item, this.label, this.seerr});

  String _tr(String it, String en) => LocaleSettings.currentLocale.languageCode == 'it' ? it : en;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = item.serverState;
    final available =
        state?.availability == CatalogAvailability.available || state?.availability4k == CatalogAvailability.available;
    final requested = !available && (state?.request != null || state?.request4k != null);
    final tmdbId = item.ids.tmdb;
    final runtime = item.runtimeMinutes;
    final meta = <String>[
      if (item.year != null) '${item.year}',
      if (item.genres?.isNotEmpty ?? false) item.genres!.first,
      if (runtime != null && runtime > 0 && item.kind == MediaKind.movie)
        runtime >= 60 ? '${runtime ~/ 60} h ${(runtime % 60).toString().padLeft(2, '0')}' : '$runtime min',
      if (item.kind == MediaKind.show) _tr('Serie TV', 'TV show'),
      if (item.rating != null && item.rating! > 0) '★ ${item.rating!.toStringAsFixed(1).replaceAll('.', _tr(',', '.'))}',
    ];
    final playLink = tmdbId == null ? null : 'maggioflix://play?type=${item.kind == MediaKind.movie ? 'movie' : 'show'}&tmdb=$tmdbId';

    final Widget primary;
    if (available && playLink != null) {
      primary = FilledButton.icon(
        onPressed: () => DeepLinkService.instance.receive(playLink),
        icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1, size: 18),
        label: Text(_tr('Guarda', 'Watch')),
        style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
      );
    } else if (requested) {
      primary = FilledButton.icon(
        onPressed: null,
        icon: const AppIcon(Symbols.schedule_rounded, size: 18),
        label: Text(_tr('Richiesto', 'Requested')),
      );
    } else if (seerr != null && tmdbId != null) {
      primary = FilledButton.icon(
        onPressed: () => unawaited(
          showSeerrRequestSheet(context, source: seerr!, kind: item.kind, tmdbId: tmdbId, title: item.title),
        ),
        icon: const AppIcon(Symbols.add_rounded, size: 18),
        label: Text(_tr('Richiedi', 'Request')),
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC9262B), foregroundColor: Colors.white),
      );
    } else {
      primary = const SizedBox.shrink();
    }

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => unawaited(navigateToCatalogItem(context, item)),
        child: SizedBox(
          height: 220,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                item.backdropUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.25, 1.0],
                    colors: [Color(0x00000000), Color(0xE6000000)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (label != null)
                      Text(
                        label!.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFFFFB4A8),
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta.join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        primary,
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => unawaited(navigateToCatalogItem(context, item)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
                          ),
                          child: Text(_tr('Dettagli', 'Details')),
                        ),
                      ],
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
