import SwiftUI

struct KeywordTagChip: View {
    let tag: String
    var isSelected = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.caption)
                .lineLimit(1)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove tag")
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isSelected ? Color.accentColor.opacity(0.3) : Color.accentColor.opacity(0.12),
            in: Capsule()
        )
        .overlay {
            if isSelected {
                Capsule().stroke(Color.accentColor, lineWidth: 1)
            }
        }
    }
}

/// Wrapping row layout for tag chips in the editor sheet and filter popover.
/// Table cells intentionally do not use it; row heights are fixed there.
struct KeywordTagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = makeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for row in rows {
            var rowHeight: CGFloat = 0
            var rowWidth: CGFloat = 0
            for entry in row {
                rowHeight = max(rowHeight, entry.sizeThatFits.height)
                rowWidth += entry.sizeThatFits.width
            }
            rowWidth += spacing * CGFloat(max(0, row.count - 1))
            height += rowHeight
            width = max(width, rowWidth)
        }
        height += spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in makeRows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let rowHeight = row.map(\.sizeThatFits.height).max() ?? 0
            for entry in row {
                entry.subview.place(
                    at: CGPoint(x: x, y: y + (rowHeight - entry.sizeThatFits.height) / 2),
                    proposal: ProposedViewSize(entry.sizeThatFits)
                )
                x += entry.sizeThatFits.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private struct RowEntry {
        let subview: LayoutSubview
        let sizeThatFits: CGSize
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [[RowEntry]] {
        var rows: [[RowEntry]] = []
        var currentRow: [RowEntry] = []
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let projectedWidth = currentWidth + (currentRow.isEmpty ? 0 : spacing) + size.width
            if !currentRow.isEmpty, projectedWidth > maxWidth {
                rows.append(currentRow)
                currentRow = []
                currentWidth = 0
            }
            currentWidth += (currentRow.isEmpty ? 0 : spacing) + size.width
            currentRow.append(RowEntry(subview: subview, sizeThatFits: size))
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}

struct KeywordTagsCell: View {
    static let visibleChipLimit = 2

    let row: KeywordWorkspaceRow
    let editTags: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: editTags) {
            HStack(spacing: 5) {
                if row.track.tags.isEmpty {
                    if isHovered {
                        Text("Add Tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    ForEach(row.track.tags.prefix(Self.visibleChipLimit), id: \.self) { tag in
                        KeywordTagChip(tag: tag)
                    }

                    if row.track.tags.count > Self.visibleChipLimit {
                        Text("+\(row.track.tags.count - Self.visibleChipLimit)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .help(row.track.tags.isEmpty ? "Add tags" : row.track.tags.joined(separator: ", "))
        .onHover { isHovered = $0 }
    }
}
