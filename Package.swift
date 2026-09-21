// swift-tools-version:5.9
import Foundation
import PackageDescription

// MARK: - 自检是否参与构建
//
// 56 个 `Selftests/Selftest*.swift` 合计 15,674 行，占仓库约 24%，
// 且只有它们 `import ViewInspector`（一个纯测试用的库）。它们此前无条件
// 链进 `dist/MacClean.app` —— 用户机器上跑的二进制里带着整套测试代码。
//
// 拆成独立 target 不可行：自检要读每个类型的内部成员，同 module 才能做到，
// 拆出去就得把大量内部 API 改成 public，那是更糟的封装。
// 所以按**目录整体排除**：release 打包时设 `MACCLEAN_NO_SELFTEST=1` 即可，
// 日常 `swift build` / `swift run MacClean --selftest` 的行为完全不变。
//
// 副作用（已知且接受）：两种模式交替构建时 `Package.resolved` 会随
// ViewInspector 的有无而变动。若嫌噪音，把 `packageDependencies` 改成常量即可，
// 代价是 release 仍要解析并编译这个测试库。
let includeSelftest = ProcessInfo.processInfo.environment["MACCLEAN_NO_SELFTEST"] == nil

// 包依赖**始终声明**，只把 target 级依赖做成条件式。
// 若连包依赖也去掉，release 构建会顺手删掉 tracked 的 `Package.resolved`，
// 下次开发构建又生成回来——两种模式交替一次，仓库里就多一次无意义的增删。
// 保留声明的代价只是 release 仍会解析/编译这个测试库；
// 没有任何源文件 import 它，链接期就不会进最终二进制，瘦身效果不受影响。
let targetDependencies: [Target.Dependency] =
    includeSelftest ? ["ViewInspector"] : []

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacClean",
            dependencies: targetDependencies,
            path: "Sources/MacClean",
            exclude: includeSelftest ? [] : ["Selftests"],
            swiftSettings: includeSelftest ? [.define("MACCLEAN_SELFTEST")] : []
        ),
    ]
)
