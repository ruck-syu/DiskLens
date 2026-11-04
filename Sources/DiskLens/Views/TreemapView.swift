import SwiftUI

struct TreemapTile {
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let color: Color
    /// True when this tile's children are drawn inside it.
    let isNested: Bool
}

enum TreemapLayout {
    static let maxDepth = 3
    private static let hues: [Double] = [0.58, 0.47, 0.08, 0.92, 0.75, 0.13, 0.33, 0.0, 0.66, 0.52, 0.83, 0.25]

    static func tiles(for node: FileNode, in bounds: CGRect) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        build(node, in: bounds, depth: 0, hue: nil, into: &tiles)
        return tiles
    }

    private static func build(_ node: FileNode, in rect: CGRect, depth: Int, hue: Double?, into tiles: inout [TreemapTile]) {
        let children = node.children.filter { $0.size > 0 }
        guard !children.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let rects = squarify(children.map { Double($0.size) }, in: rect)

        for (index, (child, r)) in zip(children, rects).enumerated() {
            guard r.width >= 1, r.height >= 1 else { continue }
            let tileHue = hue ?? hues[index % hues.count]
            let nests = child.isDirectory && depth < maxDepth - 1 && r.width > 48 && r.height > 36 && !child.children.isEmpty
            tiles.append(TreemapTile(node: child, rect: r, depth: depth, color: color(for: child, hue: tileHue, depth: depth), isNested: nests))
            if nests {
                let inner = CGRect(x: r.minX + 3, y: r.minY + 17, width: r.width - 6, height: r.height - 20)
                build(child, in: inner, depth: depth + 1, hue: tileHue, into: &tiles)
            }
        }
    }

    private static func color(for node: FileNode, hue: Double, depth: Int) -> Color {
        if node.kind == .aggregate { return Color(white: 0.55) }
        let d = Double(depth)
        let saturation = node.isDirectory ? 0.62 - d * 0.1 : 0.45 - d * 0.06
        let brightness = node.isDirectory ? 0.62 + d * 0.1 : 0.78 + d * 0.05
        return Color(hue: hue, saturation: saturation, brightness: min(brightness, 0.95))
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk). Values must be sorted descending.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var remaining = rect
        var i = 0

        func worst(_ sum: Double, _ maxV: Double, _ minV: Double, _ side: Double) -> Double {
            guard sum > 0, minV > 0 else { return .infinity }
            let s2 = sum * sum, w2 = side * side
            return max(w2 * maxV / s2, s2 / (w2 * minV))
        }

        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else {
                result.append(contentsOf: Array(repeating: .zero, count: areas.count - i))
                break
            }
            var sum = areas[i], maxV = areas[i], minV = areas[i]
            var j = i + 1
            while j < areas.count {
                let v = areas[j]
                let newSum = sum + v, newMax = max(maxV, v), newMin = min(minV, v)
                if worst(newSum, newMax, newMin, side) <= worst(sum, maxV, minV, side) {
                    sum = newSum; maxV = newMax; minV = newMin; j += 1
                } else {
                    break
                }
            }

            if remaining.width >= remaining.height {
                let w = CGFloat(sum) / remaining.height
                var y = remaining.minY
                for k in i..<j {
                    let h = CGFloat(areas[k]) / w
                    result.append(CGRect(x: remaining.minX, y: y, width: w, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(sum) / remaining.width
                var x = remaining.minX
                for k in i..<j {
                    let w = CGFloat(areas[k]) / h
                    result.append(CGRect(x: x, y: remaining.minY, width: w, height: h))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(0, remaining.height - h))
            }
            i = j
        }
        return result
    }
}

/// Holds the last computed layout so hover updates don't recompute it.
private final class TreemapCache {
    struct Key: Equatable {
        let node: ObjectIdentifier
        let size: CGSize
        let version: Int
    }

    var key: Key?
    var tiles: [TreemapTile] = []

    func tiles(for node: FileNode, size: CGSize, version: Int) -> (Key, [TreemapTile]) {
        let newKey = Key(node: ObjectIdentifier(node), size: size, version: version)
        if newKey != key {
            key = newKey
            tiles = TreemapLayout.tiles(for: node, in: CGRect(origin: .zero, size: size))
        }
        return (newKey, tiles)
    }
}

struct TreemapView: View {
    let node: FileNode
    let version: Int
    let highlighted: Set<ObjectIdentifier>
    @Binding var hovered: FileNode?
    var onActivate: (FileNode) -> Void
    var onTrash: (FileNode) -> Void

    @State private var cache = TreemapCache()

    var body: some View {
        GeometryReader { geo in
            let (key, tiles) = cache.tiles(for: node, size: geo.size, version: version)
            ZStack(alignment: .topLeading) {
                TreemapCanvas(key: key, tiles: tiles).equatable()

                ForEach(tiles.indices.filter { highlighted.contains(ObjectIdentifier(tiles[$0].node)) }, id: \.self) { i in
                    outline(tiles[i].rect, color: .accentColor, width: 3)
                }
                if let hovered, let tile = tiles.last(where: { $0.node === hovered }) {
                    outline(tile.rect, color: .white, width: 2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = hit(tiles, point)?.node
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let tile = hit(tiles, value.location) { onActivate(tile.node) }
            })
            .contextMenu {
                if let hovered, hovered.kind != .aggregate {
                    NodeMenu(node: hovered, onOpen: onActivate, onTrash: onTrash)
                }
            }
        }
        .background(Color.black.opacity(0.85))
    }

    private func outline(_ rect: CGRect, color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(color, lineWidth: width)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    private func hit(_ tiles: [TreemapTile], _ point: CGPoint) -> TreemapTile? {
        // Children are appended after their parent, so the last match is the deepest.
        tiles.last { $0.rect.contains(point) }
    }
}

private struct TreemapCanvas: View, Equatable {
    let key: TreemapCache.Key
    let tiles: [TreemapTile]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View {
        Canvas { ctx, _ in
            for tile in tiles {
                let r = tile.rect.insetBy(dx: 0.5, dy: 0.5)
                guard r.width >= 1, r.height >= 1 else { continue }
                let radius = min(3, r.width / 4, r.height / 4)
                let path = Path(roundedRect: r, cornerRadius: radius)
                ctx.fill(path, with: .linearGradient(
                    Gradient(colors: [tile.color.opacity(1), tile.color.opacity(0.82)]),
                    startPoint: CGPoint(x: r.minX, y: r.minY),
                    endPoint: CGPoint(x: r.maxX, y: r.maxY)))
                ctx.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 0.5)

                guard r.width > 44, r.height > 15 else { continue }
                ctx.drawLayer { layer in
                    layer.clip(to: Path(r.insetBy(dx: 3, dy: 1)))
                    let title = Text(tile.node.name)
                        .font(.system(size: 11, weight: tile.isNested ? .semibold : .medium))
                        .foregroundStyle(.white)
                    layer.draw(title, at: CGPoint(x: r.minX + 5, y: r.minY + 2), anchor: .topLeading)
                    if !tile.isNested, r.height > 32 {
                        let size = Text(tile.node.size.formattedBytes)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                        layer.draw(size, at: CGPoint(x: r.minX + 5, y: r.minY + 16), anchor: .topLeading)
                    }
                }
            }
        }
        .drawingGroup()
    }
}

/// Shared context menu for a file or folder node.
struct NodeMenu: View {
    let node: FileNode
    var onOpen: (FileNode) -> Void
    var onTrash: (FileNode) -> Void

    var body: some View {
        if node.isDirectory {
            Button("Zoom In") { onOpen(node) }
        }
        Button("Open") { Finder.open(node.path) }
        Button("Reveal in Finder") { Finder.reveal([node.path]) }
        Button("Copy Path") { Finder.copyPath(node.path) }
        Divider()
        Button("Move to Trash…", role: .destructive) { onTrash(node) }
    }
}
