import SwiftUI

/// Places its subviews left to right and wraps to the next line when the next one does not fit. Tags only grow downwards.
struct FlowLayout: Layout {
    var spacing: CGFloat = Tok.Space.xs
    var lineSpacing: CGFloat = Tok.Space.xs

    /// Indices of the items on each line. An item wider than the row sits alone on its line.
    static func breakLines(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var used: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            if let last = lines.indices.last, used + spacing + size.width <= width {
                lines[last].append(i); used += spacing + size.width
            } else {
                lines.append([i]); used = size.width
            }
        }
        return lines
    }

    private func measure(_ subviews: Subviews, width: CGFloat) -> (sizes: [CGSize], lines: [[Int]]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return (sizes, Self.breakLines(sizes, width: width, spacing: spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (sizes, lines) = measure(subviews, width: width)
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for line in lines {
            var lineWidth: CGFloat = spacing * CGFloat(max(line.count - 1, 0))
            var lineHeight: CGFloat = 0
            for i in line { lineWidth += sizes[i].width; lineHeight = max(lineHeight, sizes[i].height) }
            widest = max(widest, lineWidth)
            height += lineHeight
        }
        height += lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (sizes, lines) = measure(subviews, width: bounds.width)
        var y = bounds.minY
        for line in lines {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (height - sizes[i].height) / 2), proposal: ProposedViewSize(width: min(sizes[i].width, bounds.width), height: sizes[i].height))
                x += sizes[i].width + spacing
            }
            y += height + lineSpacing
        }
    }
}
