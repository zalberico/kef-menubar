import SwiftUI

/// Equal-width cells in as few rows as fit, balanced (six cells that fit four to a row
/// become two rows of three), each row's cells stretched to share the full width.
struct EvenGridLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cell = cellSize(subviews)
        let width = proposal.width ?? (cell.width * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1))
        let (_, rows) = grid(count: subviews.count, cellWidth: cell.width, width: width)
        return CGSize(width: width, height: cell.height * CGFloat(rows) + spacing * CGFloat(rows - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cell = cellSize(subviews)
        let (columns, _) = grid(count: subviews.count, cellWidth: cell.width, width: bounds.width)
        let width = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        for index in subviews.indices {
            let row = index / columns, column = index % columns
            let origin = CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing),
                                 y: bounds.minY + CGFloat(row) * (cell.height + spacing))
            subviews[index].place(at: origin, proposal: ProposedViewSize(width: width, height: cell.height))
        }
    }

    private func cellSize(_ subviews: Subviews) -> CGSize {
        subviews.reduce(.zero) { size, subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return CGSize(width: max(size.width, ideal.width), height: max(size.height, ideal.height))
        }
    }

    private func grid(count: Int, cellWidth: CGFloat, width: CGFloat) -> (columns: Int, rows: Int) {
        let fit = max(1, Int((width + spacing) / (cellWidth + spacing)))
        let rows = Int((Double(count) / Double(min(fit, count))).rounded(.up))
        let columns = Int((Double(count) / Double(rows)).rounded(.up))
        return (columns, rows)
    }
}
