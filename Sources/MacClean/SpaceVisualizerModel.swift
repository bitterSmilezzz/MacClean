import Foundation
import SwiftUI
import CoreGraphics

// MARK: - 文件类型细分与色彩编码

enum FileTypeKind: String, CaseIterable, Identifiable, Codable {
    case video = "视频媒体"
    case audio = "音频音乐"
    case image = "照片图像"
    case archive = "压缩包与镜像"
    case document = "文档与办公"
    case codeAndDev = "代码与工程产物"
    case appOrBinary = "应用与系统库"
    case cacheOrLog = "缓存与日志"
    case other = "其他文件"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .archive: return "archivebox"
        case .document: return "doc.text"
        case .codeAndDev: return "chevron.left.forwardslash.chevron.right"
        case .appOrBinary: return "app.dashed"
        case .cacheOrLog: return "clock.arrow.circlepath"
        case .other: return "doc"
        }
    }

    /// 高对比度、不透明的色彩方案（与 Dark/Light 良好适配）
    var color: Color {
        switch self {
        case .video: return Color(hex: 0x8B5CF6)       // 紫罗兰
        case .audio: return Color(hex: 0xEC4899)       // 粉红
        case .image: return Color(hex: 0xF43F5E)       // 玫瑰红
        case .archive: return Color(hex: 0xF59E0B)     // 琥珀橙
        case .document: return Color(hex: 0x10B981)    // 祖母绿
        case .codeAndDev: return Color(hex: 0x0EA5E9)  // 天蓝
        case .appOrBinary: return Color(hex: 0x6366F1) // 靛蓝
        case .cacheOrLog: return Color(hex: 0x78716C)  // 暖褐灰
        case .other: return Color(hex: 0x94A3B8)       // 石板灰
        }
    }

    /// 智能推导路径对应的文件类型
    static func infer(path: String, isDir: Bool = false) -> FileTypeKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()

        // 1. 特殊开发工程与构建产物目录
        if isDir {
            if name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".bundle") || name.hasSuffix(".plugin") {
                return .appOrBinary
            }
            if name == "deriveddata" || name == "node_modules" || name == "build" || name == "target" ||
               name == ".git" || name == "pods" || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                return .codeAndDev
            }
            if name.contains("cache") || name == "caches" || name.contains("diagnosticreports") {
                return .cacheOrLog
            }
        }

        // 2. 按扩展名匹配
        switch ext {
        case "mp4", "mov", "mkv", "avi", "flv", "webm", "wmv", "m4v", "m2ts":
            return .video
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "wma", "aiff":
            return .audio
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "raw", "tiff", "psd", "ai", "svg", "bmp":
            return .image
        case "zip", "tar", "gz", "tgz", "7z", "rar", "dmg", "pkg", "iso", "xz", "bz2":
            return .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "pages", "numbers", "key", "csv", "rtf":
            return .document
        case "swift", "c", "cpp", "h", "m", "mm", "js", "ts", "py", "go", "rs", "java", "kt", "html", "css",
             "json", "yaml", "yml", "xml", "sh", "rb", "php", "sql", "xcarchive", "dylib", "o", "a":
            return .codeAndDev
        case "app", "framework", "bundle", "plugin", "kext", "xpc":
            return .appOrBinary
        case "log", "ips", "crash", "spin", "diag", "trace", "asl":
            return .cacheOrLog
        default:
            if isDir {
                if name.contains("cache") { return .cacheOrLog }
                if name.contains("log") { return .cacheOrLog }
                return .other
            }
            return .other
        }
    }
}

// MARK: - 文件闲置冷热度等级与色谱

enum FileAgeLevel: String, CaseIterable, Identifiable, Codable {
    case active = "30天内活跃"        // < 30 天
    case warm = "1~3个月"             // 30 ~ 89 天
    case cool = "3~6个月"             // 90 ~ 179 天
    case cold = "半年至1年"           // 180 ~ 364 天
    case frozen = "1年以上沉睡"       // >= 365 天

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .active: return "flame.fill"
        case .warm: return "bolt.fill"
        case .cool: return "leaf.fill"
        case .cold: return "cube.fill"
        case .frozen: return "snowflake"
        }
    }

    var color: Color {
        switch self {
        case .active: return Color(hex: 0x10B981)   // 翠绿 (活跃、鲜活)
        case .warm: return Color(hex: 0x06B6D4)     // 青蓝 (常规)
        case .cool: return Color(hex: 0xF59E0B)     // 琥珀黄 (温冷)
        case .cold: return Color(hex: 0xF97316)     // 橙红 (陈旧)
        case .frozen: return Color(hex: 0x8B5CF6)   // 紫罗兰 (极度冰冻沉睡)
        }
    }

    static func infer(days: Int) -> FileAgeLevel {
        if days < 30 { return .active }
        if days < 90 { return .warm }
        if days < 180 { return .cool }
        if days < 365 { return .cold }
        return .frozen
    }
}

/// 空间透视色彩编码模式
enum ColorCodingMode: String, CaseIterable, Identifiable {
    case fileType = "按文件类型"
    case category = "按清理分类"
    case age = "按闲置时长"

    var id: String { rawValue }
}

// MARK: - 空间可视化节点数据模型

/// 空间层级节点（通用树结构）
struct SpaceNode: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String?
    let size: Int64
    let color: Color
    let icon: String?
    let category: CleanCategory?
    let fileTypeKind: FileTypeKind?
    let modificationDate: Date?
    var children: [SpaceNode]

    init(
        id: UUID = UUID(),
        name: String,
        path: String? = nil,
        size: Int64,
        color: Color,
        icon: String? = nil,
        category: CleanCategory? = nil,
        fileTypeKind: FileTypeKind? = nil,
        modificationDate: Date? = nil,
        children: [SpaceNode] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.color = color
        self.icon = icon
        self.category = category
        self.fileTypeKind = fileTypeKind ?? (path.map { FileTypeKind.infer(path: $0, isDir: !children.isEmpty) })
        self.modificationDate = modificationDate
        self.children = children
    }

    var isLeaf: Bool {
        children.isEmpty
    }

    var formattedSize: String {
        size.byteStringCN
    }

    var idleDays: Int? {
        guard let d = modificationDate else { return nil }
        return HistoryExporter.idleDays(for: d)
    }

    var ageLevel: FileAgeLevel? {
        guard let days = idleDays else { return nil }
        return FileAgeLevel.infer(days: days)
    }

    var isExpandableDir: Bool {
        guard let p = path, !p.isEmpty else { return false }
        let expanded = CleanPaths.expand(p)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    /// 判定该节点是否具有物理路径且存在
    var isPhysicalItem: Bool {
        guard let p = path, !p.isEmpty else { return false }
        let expanded = CleanPaths.expand(p)
        return FileManager.default.fileExists(atPath: expanded)
    }

    /// 判定该节点是否可作为超大/陈旧文件进行原位归档压缩或外接盘迁移
    var canArchiveOrMigrate: Bool {
        guard isPhysicalItem, let p = path else { return false }
        let norm = (CleanPaths.expand(p) as NSString).standardizingPath

        // 排除系统核心根目录与关键根目录
        let forbidden = ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/Volumes"]
        if forbidden.contains(norm) || norm == NSHomeDirectory() {
            return false
        }
        // 本身已经是 zip 的无需再归档
        if norm.lowercased().hasSuffix(".zip") {
            return false
        }
        // 体积门槛：> 10 MB 适合归档与迁移
        return size >= 10 * 1024 * 1024
    }

    /// 是否为沉睡冷文件（半年以上未修改）
    var isColdOrFrozen: Bool {
        guard let level = ageLevel else { return false }
        return level == .cold || level == .frozen
    }

    func displayColor(for mode: ColorCodingMode) -> Color {
        switch mode {
        case .category:
            return color
        case .fileType:
            return fileTypeKind?.color ?? color
        case .age:
            return ageLevel?.color ?? color
        }
    }

    func percentage(of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(size) / Double(total)))
    }

    func percentageString(of total: Int64) -> String {
        let pct = percentage(of: total) * 100.0
        if pct >= 10.0 {
            return String(format: "%.1f%%", pct)
        } else if pct >= 0.1 {
            return String(format: "%.1f%%", pct)
        } else if pct > 0 {
            return "<0.1%"
        } else {
            return "0%"
        }
    }
}

// MARK: - 空间层级构建引擎

enum SpaceHierarchyBuilder {
    // 这里原本还有一份自成一套的 8 色硬编码调色板（Royal Blue / Indigo / Purple …），
    // 与 ChartPalette 完全重复，而且没有任何调用点。节点颜色统一由
    // `CleanCategory.chartColor`（即 ChartPalette）提供，重复定义已删除。

    /// 构建全盘存储空间概览树
    static func buildDiskOverview(app: AppState) -> SpaceNode {
        let total = max(1, app.diskTotal)
        var children: [SpaceNode] = []

        // 1. 已扫描的各大清理分类
        var scannedCleanableTotal: Int64 = 0
        for cat in CleanCategory.allCases {
            let st = app.state(for: cat)
            if st.totalSize > 0 {
                scannedCleanableTotal += st.totalSize
                let subNodes = buildCategorySubnodes(category: cat, state: st)
                children.append(SpaceNode(
                    name: cat.title,
                    path: nil,
                    size: st.totalSize,
                    color: cat.chartColor,
                    icon: cat.icon,
                    category: cat,
                    children: subNodes
                ))
            }
        }

        // 2. 重复文件多余占用
        let dupWasted = app.duplicateState.totalWastedBytes
        if dupWasted > 0 {
            scannedCleanableTotal += dupWasted
            var dupChildren: [SpaceNode] = []
            for grp in app.duplicateState.groups.prefix(8) {
                if grp.wastedBytes > 0 {
                    dupChildren.append(SpaceNode(
                        name: grp.items.first?.name ?? "重复组",
                        path: grp.items.first?.path,
                        size: grp.wastedBytes,
                        color: TilePalette.duplicates.shade(1.18),
                        icon: "doc.on.doc"
                    ))
                }
            }
            children.append(SpaceNode(
                name: "重复与相似文件",
                path: nil,
                size: dupWasted,
                color: TilePalette.duplicates,
                icon: "doc.on.doc",
                children: dupChildren
            ))
        }

        // 3. 系统核心与其它应用占用
        let systemAndOther = max(0, app.diskUsed - scannedCleanableTotal)
        if systemAndOther > 0 {
            children.append(SpaceNode(
                name: "系统与应用在用数据",
                path: "/System",
                size: systemAndOther,
                color: TilePalette.system,
                icon: "internaldrive.fill",
                children: [
                    SpaceNode(name: "macOS 系统组件与框架", path: "/System", size: systemAndOther * 4 / 10, color: TilePalette.system.shade(0.85), icon: "apple.logo"),
                    SpaceNode(name: "已安装应用程序本体", path: "/Applications", size: systemAndOther * 35 / 100, color: TilePalette.system.shade(1.0), icon: "app.dashed"),
                    SpaceNode(name: "用户个人文稿与媒体", path: NSHomeDirectory(), size: systemAndOther * 25 / 100, color: TilePalette.system.shade(1.2), icon: "folder.fill")
                ]
            ))
        }

        // 4. 可用空间 (Free)
        if app.diskAvailable > 0 {
            children.append(SpaceNode(
                name: "可用空间",
                path: nil,
                size: app.diskAvailable,
                color: Surface.emptyTile,
                icon: "circle.dashed",
                children: []
            ))
        }

        // 排序：按体积降序
        children.sort { $0.size > $1.size }

        return SpaceNode(
            name: "Macintosh HD",
            path: "/",
            size: total,
            color: Accent.tint,
            icon: "internaldrive",
            children: children
        )
    }

    /// 构建仅针对已扫描清理项的深入透视树
    static func buildCleanableDetail(app: AppState) -> SpaceNode {
        var children: [SpaceNode] = []
        var total: Int64 = 0

        for cat in CleanCategory.allCases {
            let st = app.state(for: cat)
            if st.totalSize > 0 {
                total += st.totalSize
                let subNodes = buildCategorySubnodes(category: cat, state: st)
                children.append(SpaceNode(
                    name: cat.title,
                    path: nil,
                    size: st.totalSize,
                    color: cat.chartColor,
                    icon: cat.icon,
                    category: cat,
                    children: subNodes
                ))
            }
        }

        let dupWasted = app.duplicateState.totalWastedBytes
        if dupWasted > 0 {
            total += dupWasted
            var dupChildren: [SpaceNode] = []
            for grp in app.duplicateState.groups.prefix(12) {
                if grp.wastedBytes > 0 {
                    dupChildren.append(SpaceNode(
                        name: grp.items.first?.name ?? "重复文件",
                        path: grp.items.first?.path,
                        size: grp.wastedBytes,
                        color: TilePalette.duplicates.shade(1.18),
                        icon: "doc.on.doc"
                    ))
                }
            }
            children.append(SpaceNode(
                name: "重复与相似文件",
                path: nil,
                size: dupWasted,
                color: TilePalette.duplicates,
                icon: "doc.on.doc",
                children: dupChildren
            ))
        }

        children.sort { $0.size > $1.size }

        return SpaceNode(
            name: "已扫描可清理项",
            path: nil,
            size: max(1, total),
            color: Accent.tint,
            icon: "checkmark.seal",
            children: children
        )
    }

    /// 根据分类项自底向上提取子节点
    private static func buildCategorySubnodes(category: CleanCategory, state: CategoryState) -> [SpaceNode] {
        guard !state.items.isEmpty else { return [] }

        // 取出最大的前 15 项展示，其余合并为「其他小型项目」
        let sorted = state.items.sorted { $0.size > $1.size }
        let topCount = min(12, sorted.count)
        var subNodes: [SpaceNode] = []

        var topTotal: Int64 = 0
        for i in 0..<topCount {
            let it = sorted[i]
            topTotal += it.size
            let colorIdx = i
            subNodes.append(SpaceNode(
                name: it.name,
                path: it.path,
                size: it.size,
                color: ChartPalette.color(at: colorIdx),
                icon: category.icon,
                category: category,
                modificationDate: it.modificationDate
            ))
        }

        let remaining = state.totalSize - topTotal
        if remaining > 0 && sorted.count > topCount {
            subNodes.append(SpaceNode(
                name: "其他 \(sorted.count - topCount) 个项目",
                path: nil,
                size: remaining,
                color: TilePalette.residual,
                icon: "ellipsis.circle",
                category: category
            ))
        }

        return subNodes
    }

    /// 动态对物理目录按需展开生成下一级 SpaceNode 节点
    static func expandDirectory(path: String, colorMode: ColorCodingMode = .fileType, topLimit: Int = 16) -> [SpaceNode] {
        let expanded = CleanPaths.expand(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let children = FileSystem.children(of: expanded, keepHidden: false)
        guard !children.isEmpty else { return [] }

        var items: [(name: String, path: String, size: Int64, isDir: Bool, kind: FileTypeKind, mtime: Date?)] = []
        for child in children {
            let name = (child as NSString).lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            var subIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: child, isDirectory: &subIsDir)
            let sz = FileSystem.size(at: child)
            if sz > 0 {
                let kind = FileTypeKind.infer(path: child, isDir: subIsDir.boolValue)
                let attrs = try? FileManager.default.attributesOfItem(atPath: child)
                let mtime = attrs?[.modificationDate] as? Date
                items.append((name: name, path: child, size: sz, isDir: subIsDir.boolValue, kind: kind, mtime: mtime))
            }
        }

        guard !items.isEmpty else { return [] }
        items.sort { $0.size > $1.size }

        let count = min(topLimit, items.count)
        var result: [SpaceNode] = []
        var topTotal: Int64 = 0

        for i in 0..<count {
            let it = items[i]
            topTotal += it.size
            let defaultColor = ChartPalette.color(at: i)
            let nodeColor: Color
            switch colorMode {
            case .fileType:
                nodeColor = it.kind.color
            case .category:
                nodeColor = defaultColor
            case .age:
                if let mtime = it.mtime {
                    let days = HistoryExporter.idleDays(for: mtime)
                    nodeColor = FileAgeLevel.infer(days: days).color
                } else {
                    nodeColor = defaultColor
                }
            }
            let iconName = it.isDir ? (it.kind == .appOrBinary ? "app.dashed" : "folder.fill") : it.kind.icon

            result.append(SpaceNode(
                name: it.name,
                path: it.path,
                size: it.size,
                color: nodeColor,
                icon: iconName,
                category: nil,
                fileTypeKind: it.kind,
                modificationDate: it.mtime,
                children: []
            ))
        }

        let totalDirSize = items.reduce(0) { $0 + $1.size }
        let remaining = totalDirSize - topTotal
        if remaining > 0 && items.count > count {
            result.append(SpaceNode(
                name: "其他 \(items.count - count) 个小型项目",
                path: nil,
                size: remaining,
                color: TilePalette.residual,
                icon: "ellipsis.circle",
                category: nil,
                fileTypeKind: .other,
                children: []
            ))
        }

        return result
    }
}

// MARK: - Squarified 矩形树图布局引擎

/// 渲染图元：节点与其在画布中的绝对布局矩形
struct TreemapTile: Identifiable, Equatable {
    let id: UUID
    let node: SpaceNode
    let rect: CGRect

    init(node: SpaceNode, rect: CGRect) {
        self.id = node.id
        self.node = node
        self.rect = rect
    }
}

enum TreemapEngine {
    /// 计算 Squarified 矩形树图布局
    static func layout(nodes: [SpaceNode], in targetRect: CGRect) -> [TreemapTile] {
        guard targetRect.width > 2 && targetRect.height > 2 else { return [] }

        // 过滤空尺寸并降序
        let validNodes = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard !validNodes.isEmpty else { return [] }

        let totalSize = validNodes.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return [] }

        // 映射为面积 (像素平方)
        let totalArea = Double(targetRect.width * targetRect.height)
        let areas = validNodes.map { (Double($0.size) / Double(totalSize)) * totalArea }

        var tiles: [TreemapTile] = []
        squarify(
            nodes: validNodes,
            areas: areas,
            currentRow: [],
            rowAreaSum: 0,
            rect: targetRect,
            tiles: &tiles
        )

        return tiles
    }

    private static func squarify(
        nodes: [SpaceNode],
        areas: [Double],
        currentRow: [SpaceNode],
        rowAreaSum: Double,
        rect: CGRect,
        tiles: inout [TreemapTile]
    ) {
        guard !nodes.isEmpty else {
            if !currentRow.isEmpty {
                layoutRow(currentRow, areaSum: rowAreaSum, in: rect, tiles: &tiles)
            }
            return
        }

        guard rect.width > 1 && rect.height > 1 else { return }

        let shortestEdge = Double(min(rect.width, rect.height))
        guard shortestEdge > 0 else { return }

        let nextNode = nodes[0]
        let nextArea = areas[0]

        let remainingNodes = Array(nodes.dropFirst())
        let remainingAreas = Array(areas.dropFirst())

        if currentRow.isEmpty {
            // 开启新行
            squarify(
                nodes: remainingNodes,
                areas: remainingAreas,
                currentRow: [nextNode],
                rowAreaSum: nextArea,
                rect: rect,
                tiles: &tiles
            )
        } else {
            let currentWorst = worstAspectRatio(rowAreas: currentRowAreas(currentRow, totalSum: rowAreaSum), length: shortestEdge)
            let newRow = currentRow + [nextNode]
            let newAreaSum = rowAreaSum + nextArea
            let newWorst = worstAspectRatio(rowAreas: currentRowAreas(newRow, totalSum: newAreaSum), length: shortestEdge)

            if newWorst <= currentWorst {
                // 加入此行并继续优化
                squarify(
                    nodes: remainingNodes,
                    areas: remainingAreas,
                    currentRow: newRow,
                    rowAreaSum: newAreaSum,
                    rect: rect,
                    tiles: &tiles
                )
            } else {
                // 冻结当前行，裁剪剩余区域并开启新行
                let remainingRect = layoutRow(currentRow, areaSum: rowAreaSum, in: rect, tiles: &tiles)
                squarify(
                    nodes: nodes,
                    areas: areas,
                    currentRow: [],
                    rowAreaSum: 0,
                    rect: remainingRect,
                    tiles: &tiles
                )
            }
        }
    }

    private static func worstAspectRatio(rowAreas: [Double], length: Double) -> Double {
        guard length > 0, !rowAreas.isEmpty else { return Double.infinity }
        let s = rowAreas.reduce(0, +)
        guard s > 0 else { return Double.infinity }
        let l2 = length * length
        var maxRatio: Double = 0
        for r in rowAreas {
            guard r > 0 else { continue }
            let ratio = max((l2 * r) / (s * s), (s * s) / (l2 * r))
            if ratio > maxRatio { maxRatio = ratio }
        }
        return maxRatio
    }

    private static func currentRowAreas(_ row: [SpaceNode], totalSum: Double) -> [Double] {
        let totalSize = row.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return row.map { _ in 0.0 } }
        return row.map { (Double($0.size) / Double(totalSize)) * totalSum }
    }

    /// 布局一行并返回剩余可用矩形
    @discardableResult
    private static func layoutRow(
        _ row: [SpaceNode],
        areaSum: Double,
        in rect: CGRect,
        tiles: inout [TreemapTile]
    ) -> CGRect {
        guard !row.isEmpty, areaSum > 0 else { return rect }

        let isHorizontal = rect.width >= rect.height
        let totalRowSize = row.reduce(0) { $0 + $1.size }
        guard totalRowSize > 0 else { return rect }

        if isHorizontal {
            // 水平切割：这一行占用的宽度为 areaSum / height
            let rowWidth = min(rect.width, CGFloat(areaSum / Double(rect.height)))
            var currentY = rect.minY

            for node in row {
                let fraction = Double(node.size) / Double(totalRowSize)
                let itemHeight = CGFloat(Double(rect.height) * fraction)
                let tileRect = CGRect(x: rect.minX, y: currentY, width: rowWidth, height: itemHeight)
                tiles.append(TreemapTile(node: node, rect: tileRect))
                currentY += itemHeight
            }

            return CGRect(
                x: rect.minX + rowWidth,
                y: rect.minY,
                width: max(0, rect.width - rowWidth),
                height: rect.height
            )
        } else {
            // 垂直切割：这一行占用的高度为 areaSum / width
            let rowHeight = min(rect.height, CGFloat(areaSum / Double(rect.width)))
            var currentX = rect.minX

            for node in row {
                let fraction = Double(node.size) / Double(totalRowSize)
                let itemWidth = CGFloat(Double(rect.width) * fraction)
                let tileRect = CGRect(x: currentX, y: rect.minY, width: itemWidth, height: rowHeight)
                tiles.append(TreemapTile(node: node, rect: tileRect))
                currentX += itemWidth
            }

            return CGRect(
                x: rect.minX,
                y: rect.minY + rowHeight,
                width: rect.width,
                height: max(0, rect.height - rowHeight)
            )
        }
    }
}

// MARK: - 太阳花旭日图 (Sunburst) 几何引擎

/// 单个极坐标扇区图元
struct SunburstSector: Identifiable, Equatable {
    let id: UUID
    let node: SpaceNode
    let level: Int
    let startAngle: Double // 弧度 (0 ~ 2π)
    let endAngle: Double   // 弧度
    let innerRadius: Double
    let outerRadius: Double

    var angularSpan: Double {
        endAngle - startAngle
    }
}

enum SunburstEngine {
    /// 计算旭日图几何分块
    static func layout(root: SpaceNode, center: CGPoint, maxRadius: Double) -> [SunburstSector] {
        guard maxRadius > 20 else { return [] }

        var sectors: [SunburstSector] = []

        // 中心圆半径 (Level 0)
        let hubRadius = maxRadius * 0.28
        // 环宽
        let ringWidth = (maxRadius - hubRadius) / 2.0
        let level1Inner = hubRadius + 6.0
        let level1Outer = level1Inner + ringWidth - 4.0
        let level2Inner = level1Outer + 4.0
        let level2Outer = maxRadius

        let children = root.children.filter { $0.size > 0 }
        let total = children.reduce(0) { $0 + $1.size }
        guard total > 0 else { return [] }

        var currentAngle: Double = -Double.pi / 2.0 // 从正上方 12 点钟开始

        for child in children {
            let fraction = Double(child.size) / Double(total)
            let span = fraction * 2.0 * Double.pi
            let childStart = currentAngle
            let childEnd = currentAngle + span

            // Level 1 扇区
            sectors.append(SunburstSector(
                id: child.id,
                node: child,
                level: 1,
                startAngle: childStart,
                endAngle: childEnd,
                innerRadius: level1Inner,
                outerRadius: level1Outer
            ))

            // Level 2 扇区 (该子节点的下级目录/文件)
            let subChildren = child.children.filter { $0.size > 0 }
            let subTotal = subChildren.reduce(0) { $0 + $1.size }
            if subTotal > 0 {
                var subAngle = childStart
                for sub in subChildren {
                    let subFraction = Double(sub.size) / Double(subTotal)
                    let subSpan = subFraction * span
                    sectors.append(SunburstSector(
                        id: sub.id,
                        node: sub,
                        level: 2,
                        startAngle: subAngle,
                        endAngle: subAngle + subSpan,
                        innerRadius: level2Inner,
                        outerRadius: level2Outer
                    ))
                    subAngle += subSpan
                }
            }

            currentAngle = childEnd
        }

        return sectors
    }
}

// MARK: - 面包屑层级导航控制器

struct BreadcrumbNavigator: Equatable {
    private(set) var stack: [SpaceNode] = []
    private(set) var current: SpaceNode
    let root: SpaceNode

    init(root: SpaceNode) {
        self.root = root
        self.current = root
    }

    mutating func drillDown(into node: SpaceNode) {
        guard !node.children.isEmpty else { return }
        stack.append(current)
        current = node
    }

    mutating func popOneLevel() {
        guard let parent = stack.popLast() else { return }
        current = parent
    }

    mutating func popTo(index: Int) {
        guard stack.indices.contains(index) else { return }
        let target = stack[index]
        stack = Array(stack.prefix(index))
        current = target
    }

    mutating func popToRoot() {
        stack.removeAll()
        current = root
    }
}

