import SwiftUI

/// The Home tab's "Recommended categories" rail. Tapping a category pushes it
/// onto `HomeView`'s navigation path so the category view is genuinely L2 of
/// Home. The rail keeps its footprint while categories load.
struct HomeRecommendedCategoriesSection: View {
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  @Binding var homePath: [TwitchCategory]
  @FocusState.Binding var focusedItemID: String?

  @Environment(AppEnvironment.self) private var environment
  private var recommendations: RecommendationsService { environment.recommendations }

  var body: some View {
    let isLoading = recommendations.isLoading || recommendations.lastUpdatedAt == nil
    let categoryWidth = max(180, min(240, rail.mediaWidth * 0.6))

    VStack(alignment: .leading, spacing: 2) {
      Text("Recommended categories")
        .font(.system(size: 32, weight: .bold))
        .accessibilityAddTraits(.isHeader)

      HomeRailScrollView(rail: rail, style: style) {
        if recommendations.categories.isEmpty {
          ForEach(LoadingSkeleton.categories) { category in
            CategoryCardView(category: category, isFocused: false, width: categoryWidth)
              .modifier(LoadingSkeletonStyle())
              .opacity(isLoading ? 1 : 0)
          }
        }
        ForEach(recommendations.categories) { category in
          let itemID = "category-\(category.id)"
          let isFocused = focusedItemID == itemID

          CategoryCardView(
            category: category,
            isFocused: isFocused,
            width: categoryWidth
          )
          .contentShape(RoundedRectangle(cornerRadius: CategoryCardView.contentShapeCornerRadius))
          .focusable(true)
          .focused($focusedItemID, equals: itemID)
          .focusEffectDisabled()
          .onTapGesture {
            homePath.append(category)
          }
          .accessibilityAddTraits(.isButton)
          .zIndex(isFocused ? 2 : 0)
        }
      }
      .overlay(alignment: .leading) {
        if recommendations.categories.isEmpty, !isLoading {
          Text("No categories are available right now.").foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(recommendations.categories.isEmpty && isLoading ? Text("Loading categories") : Text(""))
    }
  }
}
