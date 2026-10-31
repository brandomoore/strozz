import SwiftUI

// MARK: - BrowseView

struct BrowseView: View {
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?

  @State private var service = BrowseService()
  @State private var path: [TwitchCategory] = []
  @State private var hasLoaded = false
  @State private var showsCategories = false
  @AppStorage(BrowsePlatformFilter.storageKey) private var platformFilter = BrowsePlatformFilter.all
  @AppStorage(StreamLanguagePreference.storageKey) private var language = StreamLanguagePreference.deviceDefault()
  @Environment(PlaybackReturnRefreshCoordinator.self) private var playbackReturnRefresh

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if showsCategories {
          BrowseCategoriesView(
            service: service, isLoading: service.isLoadingCategories || !hasLoaded,
            onSelectCategory: { path.append($0) }, platformFilter: $platformFilter,
            onShowStreams: { showsCategories = false })
        } else {
          CategoryStreamsView(selectedChannel: $selectedChannel, channelPageTarget: $channelPageTarget,
            service: service, platformFilter: $platformFilter, onShowCategories: { showsCategories = true })
        }
      }
      .navigationDestination(for: TwitchCategory.self) { category in
        CategoryStreamsView(
          category: category,
          selectedChannel: $selectedChannel,
          channelPageTarget: $channelPageTarget
        )
      }
      .task(id: "\(path.isEmpty):\(showsCategories):\(platformFilter.rawValue):\(language)") {
        guard path.isEmpty, showsCategories else { return }
        hasLoaded = false
        await service.loadCategories(filter: platformFilter)
        guard !Task.isCancelled else { return }
        hasLoaded = true
        playbackReturnRefresh.refreshThumbnails()
      }
    }
  }
}

// MARK: - Categories Grid

struct BrowseCategoriesView: View {
  let service: BrowseService
  let isLoading: Bool
  let onSelectCategory: (TwitchCategory) -> Void
  @Binding var platformFilter: BrowsePlatformFilter
  var onShowStreams: (() -> Void)?

  init(service: BrowseService, isLoading: Bool, onSelectCategory: @escaping (TwitchCategory) -> Void,
       platformFilter: Binding<BrowsePlatformFilter> = .constant(.twitch), onShowStreams: (() -> Void)? = nil) {
    self.service = service
    self.isLoading = isLoading
    self.onSelectCategory = onSelectCategory
    _platformFilter = platformFilter
    self.onShowStreams = onShowStreams
  }

  @FocusState private var focusedID: String?
  @Namespace private var browseFocusNamespace

  private let columns = [
    GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 28)
  ]

  var body: some View {
    GeometryReader { viewport in
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 24) {
          HStack {
            Text("Browse")
              .font(.title.weight(.bold))
              .accessibilityAddTraits(.isHeader)

            if service.isLoadingCategories {
              ProgressView().scaleEffect(0.85)
            }

            Spacer()

            if let onShowStreams {
              BrowsePlatformPicker(selection: $platformFilter)
              Button("Live streams", action: onShowStreams)
            }
            MultiviewLineupButton()

            Button("Refresh") {
              Task { await service.loadCategories(filter: platformFilter) }
            }
          }

          if let err = service.categoryErrorMessage {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.orange)
          }

          if !isLoading, service.categories.isEmpty, service.categoryErrorMessage == nil {
            Text("No live categories found right now.").foregroundStyle(.secondary)
          }
          LazyVGrid(columns: columns, spacing: 28) {
            if service.categories.isEmpty && isLoading {
              ForEach(LoadingSkeleton.categories) { category in
                CategoryCardView(category: category, isFocused: false)
                  .modifier(LoadingSkeletonStyle())
              }
            }
            ForEach(service.categories) { category in
              let isFocused = focusedID == category.id
              CategoryCardView(
                category: category,
                isFocused: isFocused
              )
              .contentShape(
                RoundedRectangle(cornerRadius: CategoryCardView.contentShapeCornerRadius)
              )
              .focusable(true)
              .focused($focusedID, equals: category.id)
              .prefersDefaultFocus(
                category.id == service.categories.first?.id,
                in: browseFocusNamespace
              )
              .focusEffectDisabled()
              .onTapGesture {
                onSelectCategory(category)
              }
              .zIndex(isFocused ? 2 : 0)
            }
          }
          .padding(.vertical, 8)
          .focusSection()
          .focusScope(browseFocusNamespace)
          if let error = service.moreCategoriesErrorMessage {
            Text(error).font(.footnote).foregroundStyle(.secondary)
          }
          if service.isLoadingMoreCategories {
            ProgressView("Loading categories")
          } else if service.nextKickCategoryPage != nil {
            Button("Load more") { Task { await service.loadMoreCategories() } }
              .accessibilityIdentifier("browse-load-more-categories")
          }
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.bottom, 12)
      }
      .contentMargins(.top, viewport.safeAreaInsets.top, for: .scrollContent)
      .contentMargins(.bottom, viewport.safeAreaInsets.bottom, for: .scrollContent)
      .ignoresSafeArea(.container, edges: .vertical)
      .scrollClipDisabled()
    }
  }
}

// MARK: - Category Streams

/// The root live directory or a category's streams. Category destinations own
/// their service; the root shares its service with the categories grid.
struct CategoryStreamsView: View {
  let category: TwitchCategory?
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?
  @Environment(PlaybackReturnRefreshCoordinator.self) private var playbackReturnRefresh

  @State private var service: BrowseService
  @State private var hasLoaded = false
  @Binding private var platformFilter: BrowsePlatformFilter
  private let onShowCategories: (() -> Void)?
  @FocusState private var focusedStreamID: String?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue
  @AppStorage(StreamLanguagePreference.storageKey) private var language = StreamLanguagePreference.deviceDefault()

  private var cardSpacing: CGFloat {
    let count = StreamCardSize.resolve(streamCardSizeRaw).visibleCardCount
    return ChannelRailLayout.baseCardSpacing * ChannelRailLayout.spacingScale(forVisibleCardCount: count)
  }
  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: cardSpacing),
      count: StreamCardSize.resolve(streamCardSizeRaw).visibleCardCount
    )
  }
  private let gridBottomInset: CGFloat = 12

  init(
    category: TwitchCategory? = nil,
    selectedChannel: Binding<FollowedChannel?>,
    channelPageTarget: Binding<ChannelPageTarget?>,
    service: BrowseService = BrowseService(),
    platformFilter: Binding<BrowsePlatformFilter> = .constant(.twitch),
    onShowCategories: (() -> Void)? = nil
  ) {
    self.category = category
    self._selectedChannel = selectedChannel
    self._channelPageTarget = channelPageTarget
    self._service = State(initialValue: service)
    self._platformFilter = platformFilter
    self.onShowCategories = onShowCategories
  }

  private func preparePlaybackReturn() {
    playbackReturnRefresh.prepareOrigin {
      await service.loadStreams(for: category, filter: platformFilter)
    }
  }

  var body: some View {
    GeometryReader { viewport in
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 20) {
          // Header (scrolls with content)
          HStack(spacing: 20) {
            if let url = category?.boxArtURL {
              CachedAsyncImage(url: url) { img in
                img.resizable().scaledToFill()
              } placeholder: {
                Color.primary.opacity(0.08)
              }
              .frame(width: 40, height: 53)
              .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(category?.name ?? String(localized: "Browse"))
                .font(.title.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
              if let viewers = category?.viewerCount {
                Text("\(viewers) watching")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }

            if service.isLoadingStreams && service.categoryStreams.isEmpty {
              ProgressView().scaleEffect(0.85)
            }

            Spacer()
            if let onShowCategories {
              BrowsePlatformPicker(selection: $platformFilter)
              Button("Categories", action: onShowCategories)
            }
            MultiviewLineupButton()
            Button("Refresh") {
              Task { await service.loadStreams(for: category, filter: platformFilter) }
            }
          }
          .focusSection()

          if let err = service.streamsErrorMessage {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.orange)
          }

          if hasLoaded && !service.isLoadingStreams && service.categoryStreams.isEmpty
            && service.streamsErrorMessage == nil
          {
            Text("No live streams found right now.")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 8)
          } else {
            LazyVGrid(columns: columns, spacing: cardSpacing) {
              if service.categoryStreams.isEmpty && (service.isLoadingStreams || !hasLoaded) {
                ForEach(LoadingSkeleton.channels) { channel in
                  StreamChannelCard(channel: channel, isFocused: false)
                    .modifier(LoadingSkeletonStyle())
                }
              }
              ForEach(service.categoryStreams, id: \.channelKey) { channel in
                let isFocused = focusedStreamID == channel.channelKey
                StreamChannelCard(
                  channel: channel,
                  isFocused: isFocused,
                  onWatch: {
                    preparePlaybackReturn()
                    selectedChannel = $0
                  },
                  onGoToChannel: {
                    preparePlaybackReturn()
                    channelPageTarget = ChannelPageTarget(channel: $0)
                  }
                )
                .contentShape(RoundedRectangle(cornerRadius: CardMetrics.gridCardCornerRadius))
                .focusable(true)
                .focused($focusedStreamID, equals: channel.channelKey)
                .focusEffectDisabled()
                .onTapGesture {
                  preparePlaybackReturn()
                  selectedChannel = channel
                }
                .modifier(MultiviewCardShortcut(channel: channel))
                .zIndex(isFocused ? 2 : 0)
              }
            }
            .focusSection()
          }
          if let error = service.moreStreamsErrorMessage {
            Text(error).font(.footnote).foregroundStyle(.secondary)
          }
          if service.isLoadingMore {
            ProgressView("Loading streams")
          } else if service.nextKickCursor != nil {
            Button("Load more") { Task { await service.loadMoreStreams() } }
              .accessibilityIdentifier("browse-load-more")
          }
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, gridBottomInset)
      }
      // Clipping alone does not control lazy-grid culling. Make the scroll
      // viewport full-height and keep resting header spacing inside its content.
      .contentMargins(.top, viewport.safeAreaInsets.top, for: .scrollContent)
      .contentMargins(.bottom, viewport.safeAreaInsets.bottom, for: .scrollContent)
      .ignoresSafeArea(.container, edges: .vertical)
      .scrollClipDisabled()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationBarHidden(true)
    .toolbar(category == nil ? .visible : .hidden, for: .tabBar)
    .task(id: "\(category?.id ?? "directory"):\(platformFilter.rawValue):\(language)") {
      hasLoaded = false
      await service.loadStreams(for: category, filter: platformFilter)
      if !Task.isCancelled { hasLoaded = true }
    }

    .onChange(of: service.categoryStreams) { previous, streams in
      if category != nil, previous.isEmpty, focusedStreamID == nil, let first = streams.first {
        Task {
          try? await Task.sleep(for: .milliseconds(150))
          guard !Task.isCancelled, selectedChannel == nil, channelPageTarget == nil, focusedStreamID == nil,
            service.categoryStreams.contains(where: { $0.channelKey == first.channelKey }) else { return }
          focusedStreamID = first.channelKey
        }
      }
    }
  }
}

private struct BrowsePlatformPicker: View {
  @Binding var selection: BrowsePlatformFilter

  var body: some View {
    Picker("Platform", selection: $selection) {
      ForEach(BrowsePlatformFilter.allCases, id: \.self) { filter in
        Text(filter.title).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 380)
    .accessibilityIdentifier("browse-platform-filter")
  }
}
