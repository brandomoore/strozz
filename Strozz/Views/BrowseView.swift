import SwiftUI

// MARK: - BrowseView

struct BrowseView: View {
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?

  @State private var service = BrowseService()
  @State private var path: [TwitchCategory] = []
  @State private var hasLoaded = false
  @Environment(PlaybackReturnRefreshCoordinator.self) private var playbackReturnRefresh

  var body: some View {
    NavigationStack(path: $path) {
      BrowseCategoriesView(
        service: service,
        isLoading: service.isLoadingCategories || !hasLoaded,
        onSelectCategory: { path.append($0) }
      )
      .navigationDestination(for: TwitchCategory.self) { category in
        CategoryStreamsView(
          category: category,
          selectedChannel: $selectedChannel,
          channelPageTarget: $channelPageTarget
        )
      }
      .task(id: path.isEmpty) {
        guard path.isEmpty else { return }
        await service.loadCategories()
        guard !Task.isCancelled else { return }
        hasLoaded = true
        playbackReturnRefresh.refreshThumbnails()
      }
    }
  }
}

// MARK: - Categories Grid

private struct BrowseCategoriesView: View {
  let service: BrowseService
  let isLoading: Bool
  let onSelectCategory: (TwitchCategory) -> Void

  @FocusState private var focusedID: String?
  @Namespace private var browseFocusNamespace

  private let columns = [
    GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 28)
  ]

  var body: some View {
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

          Button("Refresh") {
            Task { await service.loadCategories() }
          }
        }

        if let err = service.categoryErrorMessage {
          Text(err)
            .font(.footnote)
            .foregroundStyle(.orange)
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
            .contentShape(RoundedRectangle(cornerRadius: CategoryCardView.contentShapeCornerRadius))
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
      }
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.bottom, 12)
    }
    .scrollClipDisabled()
  }
}

// MARK: - Category Streams

/// A category's live streams, pushed one level deep from any tab (Home, Search,
/// or Browse). It owns its own `BrowseService` so it is fully self-contained as
/// a `navigationDestination`, and relies on the native tvOS Menu button to pop.
struct CategoryStreamsView: View {
  let category: TwitchCategory
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?
  @Environment(PlaybackReturnRefreshCoordinator.self) private var playbackReturnRefresh

  @State private var service: BrowseService
  @State private var hasLoaded = false
  @FocusState private var focusedStreamID: String?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue

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
    category: TwitchCategory,
    selectedChannel: Binding<FollowedChannel?>,
    channelPageTarget: Binding<ChannelPageTarget?>,
    service: BrowseService = BrowseService()
  ) {
    self.category = category
    self._selectedChannel = selectedChannel
    self._channelPageTarget = channelPageTarget
    self._service = State(initialValue: service)
  }

  private func preparePlaybackReturn() {
    playbackReturnRefresh.prepareOrigin {
      await service.loadStreams(for: category)
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 20) {
          // Header (scrolls with content)
          HStack(spacing: 20) {
            if let url = category.boxArtURL {
              CachedAsyncImage(url: url) { img in
                img.resizable().scaledToFill()
              } placeholder: {
                Color.primary.opacity(0.08)
              }
              .frame(width: 40, height: 53)
              .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(category.name)
                .font(.title.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
              if let viewers = category.viewerCount {
                Text("\(viewers) watching")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }

            if service.isLoadingStreams && service.categoryStreams.isEmpty {
              ProgressView().scaleEffect(0.85)
            }

            Spacer()
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
            Text("No live streams found for \(category.name) right now.")
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
                .zIndex(isFocused ? 2 : 0)
              }
            }
            .focusSection()
          }
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, gridBottomInset)
      }
      .scrollClipDisabled()
    }
    .padding(.top, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationBarHidden(true)
    .toolbar(.hidden, for: .tabBar)
    .task(id: category.id) {
      await service.loadStreams(for: category)
      hasLoaded = true
    }
    .onChange(of: service.categoryStreams) { previous, streams in
      if previous.isEmpty, focusedStreamID == nil, let first = streams.first {
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
