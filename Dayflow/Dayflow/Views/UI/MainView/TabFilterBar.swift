import SwiftUI

struct TabFilterBar: View {
  let categories: [TimelineCategory]
  let idleCategory: TimelineCategory?
  let onManageCategories: () -> Void

  @State private var chipRowWidth: CGFloat = 0

  private let editButtonSize: CGFloat = 24
  private let chipButtonSpacing: CGFloat = 8

  var body: some View {
    GeometryReader { geometry in
      let availableWidth = max(0, geometry.size.width)
      let maxChipRowWidth = max(0, availableWidth - editButtonSize - chipButtonSpacing)
      let hasMeasuredChipRow = chipRowWidth > 0
      let isOverflowing = hasMeasuredChipRow && chipRowWidth > maxChipRowWidth
      let chipRowFrameWidth =
        hasMeasuredChipRow
        ? min(chipRowWidth, maxChipRowWidth)
        : maxChipRowWidth

      ZStack(alignment: .topLeading) {
        HStack(spacing: chipButtonSpacing) {
          visibleChipRow(width: chipRowFrameWidth)
          editButton
        }
        .frame(width: availableWidth, height: editButtonSize, alignment: .leading)
        .overlay(alignment: .trailing) {
          if isOverflowing {
            overflowGradient
              .padding(.trailing, editButtonSize + chipButtonSpacing)
          }
        }

        measuredChipRow
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .frame(width: availableWidth, height: editButtonSize, alignment: .leading)
    }
    .frame(height: editButtonSize)
    .onPreferenceChange(ChipRowWidthPreferenceKey.self) { chipRowWidth = $0 }
  }

  struct CategoryChip: View {
    let category: TimelineCategory
    let isIdle: Bool

    var body: some View {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(hex: category.colorHex))
          .frame(width: 10, height: 10)

        Text(category.name)
          .font(
            Font.custom("Figtree", size: 13)
              .weight(.medium)
          )
          .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
          .lineLimit(1)
          .fixedSize()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(height: 26)
      .background(.white.opacity(0.76))
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .inset(by: 0.25)
          .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 0.5)
      )
    }
  }

  private func visibleChipRow(width: CGFloat) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      chipRowContent
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 26)
    }
    .frame(width: max(0, width), height: 26, alignment: .leading)
    .clipped()
  }

  private var measuredChipRow: some View {
    chipRowContent
      .fixedSize(horizontal: true, vertical: false)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: ChipRowWidthPreferenceKey.self, value: proxy.size.width)
        }
      )
  }

  private var chipRowContent: some View {
    HStack(spacing: 5) {
      ForEach(categories) { category in
        CategoryChip(category: category, isIdle: false)
      }

      if let idleCategory {
        CategoryChip(category: idleCategory, isIdle: true)
      }
    }
    .padding(.leading, 2)
  }

  private var editButton: some View {
    CategoryEditCircleButton(
      action: onManageCategories,
      diameter: editButtonSize
    )
  }

  private var overflowGradient: some View {
    LinearGradient(
      gradient: Gradient(colors: [Color.clear, Color(hex: "FFF8F1")]),
      startPoint: .leading,
      endPoint: .trailing
    )
    .frame(width: 40)
    .allowsHitTesting(false)
  }

  private struct ChipRowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = nextValue()
    }
  }
}

// "검토 필요만" filter toggle. A small togglable pill that mirrors the visual
// language of `TabFilterBar.CategoryChip`. View-only filter — when on, the day
// timeline shows only needsReview cards. The caller is responsible for hiding
// this chip when there are no needsReview cards for the day.
struct NeedsReviewFilterChip: View {
  @Binding var isOn: Bool
  let count: Int

  @State private var isHovering = false

  var body: some View {
    Button {
      withAnimation(.easeOut(duration: 0.18)) {
        isOn.toggle()
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.circle")
          .font(.system(size: 11, weight: .semibold))

        Text("검토 필요만")
          .font(Font.custom("Figtree", size: 13).weight(.medium))
          .lineLimit(1)
          .fixedSize()

        Text("\(count)")
          .font(Font.custom("Figtree", size: 11).weight(.semibold))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            Capsule().fill(
              isOn ? Color.white.opacity(0.85) : Color(red: 0.92, green: 0.74, blue: 0.55).opacity(0.35)
            )
          )
      }
      .foregroundColor(
        isOn ? .white : Color(red: 0.45, green: 0.32, blue: 0.18)
      )
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(height: 26)
      .background(
        isOn
          ? Color(red: 0.85, green: 0.49, blue: 0.16)
          : (isHovering ? Color.white.opacity(0.92) : Color.white.opacity(0.76))
      )
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .inset(by: 0.25)
          .stroke(
            isOn
              ? Color(red: 0.85, green: 0.49, blue: 0.16)
              : Color(red: 0.88, green: 0.78, blue: 0.66),
            lineWidth: 0.5
          )
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { isHovering = $0 }
    .help(isOn ? "전체 카드 보기" : "검토 필요 카드만 보기")
    .accessibilityLabel("검토 필요만 필터")
    .accessibilityValue(isOn ? "켜짐" : "꺼짐")
  }
}
