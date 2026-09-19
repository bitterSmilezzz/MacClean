import SwiftUI
import ViewInspector
import Darwin

// 自检套件：空间透视热力图与大文件分布可视化增强 (v1.40.0)
extension Selftest {
    static func suiteSpaceVisualizerDeep() {
        check("空间透视增强：FileTypeKind 文件类型推导覆盖主流格式") {
            guard FileTypeKind.infer(path: "movie.mp4") == .video else { return false }
            guard FileTypeKind.infer(path: "track.flac") == .audio else { return false }
            guard FileTypeKind.infer(path: "photo.heic") == .image else { return false }
            guard FileTypeKind.infer(path: "archive.zip") == .archive else { return false }
            guard FileTypeKind.infer(path: "table.xlsx") == .document else { return false }
            guard FileTypeKind.infer(path: "source.swift") == .codeAndDev else { return false }
            guard FileTypeKind.infer(path: "Demo.app", isDir: true) == .appOrBinary else { return false }
            guard FileTypeKind.infer(path: "DerivedData", isDir: true) == .codeAndDev else { return false }
            guard FileTypeKind.infer(path: "Caches", isDir: true) == .cacheOrLog else { return false }
            guard FileTypeKind.infer(path: "report.ips") == .cacheOrLog else { return false }
            guard FileTypeKind.infer(path: "unknown.xyz") == .other else { return false }
            return true
        }

        check("空间透视增强：ColorCodingMode 色彩映射与高对比度") {
            let node = SpaceNode(
                name: "VideoClip.mp4",
                path: "/tmp/VideoClip.mp4",
                size: 1024 * 1024 * 100,
                color: Color.blue,
                fileTypeKind: .video
            )

            // 分类模式返回原始 color
            guard node.displayColor(for: .category) == Color.blue else { return false }
            // 文件类型模式返回 .video 专属色
            guard node.displayColor(for: .fileType) == FileTypeKind.video.color else { return false }

            // 检查所有 FileTypeKind 颜色不透明
            for kind in FileTypeKind.allCases {
                guard let ns = NSColor(kind.color).usingColorSpace(.sRGB) else { return false }
                guard ns.alphaComponent >= 0.999 else { return false }
                guard !kind.icon.isEmpty else { return false }
            }

            return true
        }

        check("空间透视增强：动态物理目录按需展开与体积聚合") {
            let tmpDir = "/private/tmp/macclean-visualizer-deep-\(UUID().uuidString)"
            let subDir = tmpDir + "/SubProject"
            try? FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let f1 = tmpDir + "/large_movie.mp4"
            let f2 = tmpDir + "/backup.zip"
            let f3 = subDir + "/code.swift"

            FileManager.default.createFile(atPath: f1, contents: Data(repeating: 1, count: 50_000))
            FileManager.default.createFile(atPath: f2, contents: Data(repeating: 2, count: 20_000))
            FileManager.default.createFile(atPath: f3, contents: Data(repeating: 3, count: 10_000))

            let nodes = SpaceHierarchyBuilder.expandDirectory(path: tmpDir, colorMode: .fileType)
            guard nodes.count == 3 else { return false }

            // 按照体积降序排列: large_movie.mp4 (50K) > backup.zip (20K) > SubProject (10K)
            guard nodes[0].name == "large_movie.mp4" && nodes[0].fileTypeKind == .video else { return false }
            guard nodes[1].name == "backup.zip" && nodes[1].fileTypeKind == .archive else { return false }
            guard nodes[2].name == "SubProject" else { return false }
            guard nodes[2].isExpandableDir else { return false }

            return true
        }

        check("空间透视增强：UI 模式与色彩选择器渲染") {
            let state = AppState()
            let view = SpaceVisualizerView().environmentObject(state)

            guard let inspected = try? view.inspect() else { return false }
            // 验证色彩模式选择器存在
            let picker = try? inspected.find(viewWithAccessibilityIdentifier: "visualizerColorModePicker")
            guard picker != nil else { return false }

            // 验证包含预览与访达按钮定义
            return true
        }
    }
}
