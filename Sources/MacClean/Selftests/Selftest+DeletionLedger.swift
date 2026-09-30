import Foundation
import Darwin

// 自检套件：删除记账与撤销快照的**单一出口** `DeletionLedger`（R2 的 P0）
//
// 背景（数字按 `git grep -c 'Cleaner\.clean(' efe1be2` 实测，别照抄本文案的旧版本）：
// 改动前产品源码里有 **7 处** `Cleaner.clean` 调用点，其中
// - **2 处一行账都不写**：`Uninstaller.uninstallSelected`、`OrphanScanner.clean`（孤儿残留）；
// - **2 处只写历史、把快照丢掉**：`DiskMonitor.performSilentAutoClean`（唯一"没人看着也会删"
//   的链路）、`DuplicateScanner` + `DuplicateView`（视图补 `recordClean`，从没写过快照）；
// - 另有 **2 处不经 `Cleaner` 的裸 `fm.trashItem`**（归档、跨卷迁移）同样零账。
// 四种形状的用户侧症状一样：界面上那条记录永远点不动，或者压根没出现过。
// 现在"动手"与"记账"绑在同一个函数里。本套件两条腿：
// ① 源码 lint：`Cleaner.clean(` 只允许出现在 `DeletionLedger.swift`；
// ② 行为：历史行 ↔ 撤销快照的配对、空跑不落行、真删一条走通 `clean()` 全程。
extension Selftest {
    static func suiteDeletionLedger() {

        // 1. 唯一的删除入口：产品源码里除 `DeletionLedger.swift` 之外不许出现 `Cleaner.clean(`。
        //    针脚拆开写：整串字面量会出现在这条 lint 自己的源码里，于是它第一次跑就"抓到自己"
        //    （本轮在同族 lint 上实测过这个坑）。
        check("G20 产品源码只有 DeletionLedger 能调 Cleaner.clean（想删就必须记账）") {
            let dir = Selftest.sourceDirectoryPath
            let files = ((try? FileManager.default.subpathsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".swift") }
                // 自检目录里为了造夹具会直接调 Cleaner，那条不算产品链路
                .filter { !$0.hasPrefix("Selftests/") }
                .sorted()
            // 不带左括号：这样 `let f = Cleaner.clean`（取函数引用后再调用）也被算成一次命中
            //   ——v1.73.15 二次复审 P1-1 实测到带括号的 needle 对这种写法完全瞎。
            let needle = "Cleaner." + "clean"
            // ⚠ 判据必须在**挤过空白**的代码上匹配——这是本仓 G18/G19 已经写明却被我这一版
            //   漏掉的规矩（v1.73.15 独立复审 P1-F2）：直接对原文 `contains` 的话，
            //   ① `Cleaner` 折行 `.clean(` 的绕过**完全不可见**（实测全绿），
            //   ② 反过来，出口自己折行会让命中数变 0，把一道良性排版变成发版红灯。
            var offenders: [String] = []
            var hits = 0
            var ledgerHits = 0
            for rel in files {
                let src = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent(rel),
                                      encoding: .utf8)) ?? ""
                let stripped = Selftest.stripSwiftComments(src)
                let code = stripped.components(separatedBy: .whitespacesAndNewlines).joined()
                var searchFrom = code.startIndex
                while let rng = code.range(of: needle, range: searchFrom..<code.endIndex) {
                    hits += 1
                    if rel != "DeletionLedger.swift" { offenders.append(rel) } else { ledgerHits += 1 }
                    searchFrom = rng.upperBound
                }
            }
            // 阳性对照：出口自己必须在。它不在了说明这一档整体改走了别的实现，
            // 那时 hits==0，lint 会因为"谁都没违规"而假绿。
            var bad: [String] = []
            // 判据写成**归属**而不是"总数恰好 1"：出口内部现在有两个分支
            //（`#if MACCLEAN_SELFTEST` 的注入缝 + `#else` 的真调用），总数会随发版开关变 1/2，
            // 但"出口之外必须 0 处""出口之内必须 ≥1 处"这两条在任何构建形态下都成立。
            if ledgerHits < 1 {
                bad.append("出口内部一处 `Cleaner.clean` 都没有（命中 \(ledgerHits)）——整档改走别处，lint 不能因「无人违规」而假绿")
            }
            if !offenders.isEmpty {
                bad.append("绕过出口直接删：\(offenders.joined(separator: ", "))")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 2. 五条曾经"只删不记"的链路必须接在出口上。
        //    这条不是冗余：`SpaceArchiveService` 用的是裸 `fm.trashItem`，上面那条 lint 抓不到它；
        //    把它的记账删掉，只有这里会红。
        // ⚠ 判据点的是**每处调用自己的字面量**，不是"文件里出现过出口名"或"出现几次"：
        //   变异验证第一轮在这里活下来过——`SpaceArchiveService` 的归档与迁移共用一个私有
        //   helper，数 `recordTrashedOriginal(` 会把 helper 的定义也算成一次调用点，
        //   删掉一处调用之后文件里仍然剩 2 次、判据不响。Presence 与计数都会骗人，
        //   点名"这一处调用长什么样"才不会。
        check("静默清理/卸载/去重/孤儿/归档五条链路都接在出口上（曾经只删不记）") {
            let dir = Selftest.sourceDirectoryPath
            let required: [(file: String, mustContain: [String])] = [
                ("DiskMonitor.swift", ["DeletionLedger." + "clean(", "智能静默定时清理"]),
                ("Uninstaller.swift", ["DeletionLedger." + "clean(", "App 卸载残留"]),
                ("DuplicateScanner.swift", ["DeletionLedger." + "clean(", "重复文件"]),
                ("OrphanScanner.swift", ["DeletionLedger." + "clean(", "孤儿残留清理"]),
                // 归档与迁移两处各点名一次：删任一处都判红，而上面那条 Cleaner lint 完全看不见它们
                ("SpaceArchiveService.swift", [#"categoryName: "大文件归档""#,
                                               #"categoryName: "跨卷迁移""#,
                                               "DeletionLedger." + "write("])
            ]
            var bad: [String] = []
            for one in required {
                let src = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent(one.file),
                                      encoding: .utf8)) ?? ""
                let stripped = Selftest.stripSwiftComments(src)
                let code = stripped.components(separatedBy: .whitespacesAndNewlines).joined()
                let compactNeedles = one.mustContain.map {
                    $0.components(separatedBy: .whitespacesAndNewlines).joined()
                }
                for needle in compactNeedles where !code.contains(needle) {
                    bad.append("\(one.file) 里找不到 \(needle)")
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 2b. 注入缝只许待在出口与自检里。
        //     `deleter` 是个可变全局：任何产品文件重赋它就能让"删除"跳过 `Cleaner` 里的
        //     `isSafeToClean`（G1/G6/G8），文件没删却落一行"成功"历史。
        //     它已经用 `#if MACCLEAN_SELFTEST` 关出 release 产物，这条 lint 再钉住
        //     "开发构建里也不许有产品文件引用它"（v1.73.15 二次复审 P1-1）。
        check("G20b 注入缝 DeletionLedger.deleter 只出现在出口与自检里") {
            let dir = Selftest.sourceDirectoryPath
            let files = ((try? FileManager.default.subpathsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".swift") }
                .filter { !$0.hasPrefix("Selftests/") }
                .sorted()
            // 判据是**成员引用**（`.deleter`）而不是 `DeletionLedger.deleter`：
            // 出口内部声明与调用都写裸 `deleter`（在自己的 enum 里），带类型名的形式
            // 在产品源码里出现 0 次才是正常的——上一版就是这么把自己的声明数漏掉了（实测报 0）。
            let useNeedle = "." + "deleter"          // 别的文件想用它，只能写成 `X.deleter`
            let declNeedle = "deleter"               // 出口内部的声明 + 调用
            var offenders: [String] = []
            var ledgerDeclarations = 0
            for rel in files {
                let src = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent(rel),
                                      encoding: .utf8)) ?? ""
                let compact = Selftest.stripSwiftComments(src)
                    .components(separatedBy: .whitespacesAndNewlines).joined()
                var from = compact.startIndex
                while let rng = compact.range(of: useNeedle, range: from..<compact.endIndex) {
                    if rel != "DeletionLedger.swift" { offenders.append(rel) }
                    from = rng.upperBound
                }
                if rel == "DeletionLedger.swift" {
                    // 声明一处 + 出口内调用一处，至少两次
                    from = compact.startIndex
                    while let rng = compact.range(of: declNeedle, range: from..<compact.endIndex) {
                        ledgerDeclarations += 1
                        from = rng.upperBound
                    }
                }
            }
            var bad: [String] = []
            if ledgerDeclarations < 2 {
                bad.append("出口里 `deleter` 只出现 \(ledgerDeclarations) 次（声明与调用至少各一处）——缝被删了不会有人说，注入能力与那条断言会一起消失")
            }
            if !offenders.isEmpty {
                bad.append("产品文件引用了注入缝：\(offenders.joined(separator: ", "))")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 2c. 主链路的软链防跳板必须在**解析之前**（R3 的 P0-3）。
        //     这条是顺序判据，不是存在判据：`isSafeToClean` 自己第一层就是 `isSymlink`，
        //     但 `Cleaner` 先 `realPath(path)` 再校验，传进去的已经是解析完的目标——
        //     那一层在主链路上永远不响。所以只查"文件里出现过 isSymlink"毫无判别力。
        //     ⚠ 三次复审 P2-1 实测到旧写法（整档比"谁第一次出现"）有两个洞：
        //       ① `isSymlink(realPath(path))`——形状仍是"软链判据在前"，实际判的是解析后的目标；
        //       ② 在别处（另一个函数、或一句永不执行的 `if false { _ = isSymlink(path) }`）
        //          先写一次 `isSymlink`，整档比法就被它背书，循环体里那条真判据删掉照样绿。
        //     所以按 `for path in item.paths` 的**循环体**切（大括号深度），并且要求
        //     切出来的体里那句是 `guard … else` 形状——存在/先后都不足以钉住这一档。
        check("G21 Cleaner 循环体里的软链 guard 排在路径解析之前（整档第一次会被别处背书）") {
            let dir = Selftest.sourceDirectoryPath
            let src = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent("Cleaner.swift"),
                                  encoding: .utf8)) ?? ""
            let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
            guard let head = code.range(of: "forpathinitem.paths{") else {
                print("      找不到 `for path in item.paths` 循环（形状改了？判据要跟着改，别删）")
                return false
            }
            // ⚠ 针脚本身**含**那朵 `{`，所以 head.upperBound 已在循环体内部：初值必须是 1，
            //   且不能再"找第一朵 `{` 当体首"——那样截出来的是 `else { … }` 那一小段。
            var i = head.upperBound
            let bodyStart = head.upperBound
            var endIdx = code.endIndex
            var depth = 1
            while i < code.endIndex {
                let c = code[i]
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 { endIdx = i; break }
                }
                i = code.index(after: i)
            }
            guard depth == 0, bodyStart < endIdx else {
                print("      循环体截不出来（大括号不配对）"); return false
            }
            let body = String(code[bodyStart..<endIdx])
            var bad: [String] = []
            let guardNeedle = "guard!" + "FileSystem.isSymlink(path)else{"
            guard let g = body.range(of: guardNeedle) else {
                print("      循环体里没有 guard 形状的软链判据——"
                      + "换成 `isSymlink(realPath(path))` 或挪到别处都会走到这里")
                return false
            }
            if let r = body.range(of: "FileSystem.realPath("), g.lowerBound > r.lowerBound {
                bad.append("软链 guard 排在 realPath 之后：传进去的目标已解析，那一层永远不响")
            }
            if body.contains("isSymlink(FileSystem.realPath(") {
                bad.append("判据对着解析结果问是不是软链（lstat 永远答「不是」，这就是修之前的形状）")
            }
            // 终审 F2 实测：`if false { guard … }` 这种"死分支包壳"里，形状与先后都漂亮，
            // 但那一条永远不执行——所以还要钉住它待在循环体**顶层**。
            if Selftest.braceDepth(in: body, upTo: g.lowerBound) != 0 {
                bad.append("软链 guard 不在循环体顶层：被包进任何分支（含永不执行的那一种）时，"
                           + "顺序判据看不见，只有行为腿拦得住")
            }
            if !bad.isEmpty {
                print("      " + bad.joined(separator: "\n      "))
                return false
            }
            return true
        }

        // 2d. 行为：软链项必须**原样留下**，而不是顺着它删掉指向的真文件。
        //     两侧都要钉：①软链被拒且**目标与软链都还在**；②同目录里的普通文件照常删掉。
        //     只钉①会犯 v1.73.8 那条错——"两侧都拒 → 恒真"：把判据改成"什么都别删"它照样全绿。
        check("主链路遇到软链项：拒删、报错、软链与目标都还在；同批普通文件照常删") {
            return ledgerScope("symlinkGuard") {
                let root = "/private/tmp/macclean_symlink_guard_\(UUID().uuidString)"
                let fm = FileManager.default
                try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
                defer { try? fm.removeItem(atPath: root) }
                let victim = root + "/合同.pdf"          // 软链指向的真文件（模拟用户的资料）
                let link = root + "/report.pdf"         // 列表上写着的那一项
                let plain = root + "/keep-me.txt"        // 正向对照：普通文件必须照删
                try? "合同正文".write(toFile: victim, atomically: true, encoding: .utf8)
                try? "普通内容".write(toFile: plain, atomically: true, encoding: .utf8)
                do { try fm.createSymbolicLink(atPath: link, withDestinationPath: victim) }
                catch { print("      造不出软链夹具，本条未执行：\(error)"); return false }
    
                let linkItem = CleanItem(name: "report.pdf", path: link, size: 12,
                                         rule: "T1", category: .largeFiles, note: "软链夹具")
                let plainItem = CleanItem(name: "keep-me.txt", path: plain, size: 12,
                                          rule: "T1", category: .largeFiles, note: "普通夹具")
                let result = DeletionLedger.clean([linkItem, plainItem],
                                                  permanently: true,
                                                  categoryName: "自检-软链护栏").result
                var bad: [String] = []
                if !FileManager.default.fileExists(atPath: victim) {
                    bad.append("软链指向的真文件被删了——这正是「删掉列表上根本没写的那个东西」")
                }
                if !FileManager.default.fileExists(atPath: link) {
                    bad.append("软链本身也被删了：护栏应当拒删整项而不是顺手清掉入口")
                }
                if FileManager.default.fileExists(atPath: plain) {
                    bad.append("同批的普通文件没删：判据被改成了「什么都不删」，正向对照失效")
                }
                if result.succeeded != 1 { bad.append("成功项数应为 1（软链那项必须算失败），实到 \(result.succeeded)") }
                if result.failedPaths != [link] { bad.append("失败集合没指到软链：\(result.failedPaths)") }
                // 释放量只能算那**一个**真删掉的文件：软链那一项既没删成也不该计进去
                if result.releasedBytes <= 0 { bad.append("删掉了一项却记 0 字节") }
                if result.releasedBytesByItem[plainItem.id] == nil {
                    bad.append("成功项没有逐 item 的释放量（LOW-4 那格）")
                }
                if result.releasedBytesByItem[linkItem.id] != nil {
                    bad.append("被拒的软链项也进了释放账")
                }
                if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
                return bad.isEmpty
            }
        }

        // 2e. 默认支（移入废纸篓）也必须有执法力 —— 三次复审 P1-1 实测：2d 只跑
        //     `permanently: true`，于是 `guard !(forcePermanent && isSymlink(path))` 这种
        //     "把判据门控到彻底删除那一支"的变异，两条判据**同时全绿**。
        //     ⚠ 这一条的前一版用**悬挂软链**，是一条假绿（我自己跑变异才发现的）：悬挂软链的
        //     `realPath` 按词法返回软链自己（`FileSystem.swift:41` 自述"不存在的末段保持原样"），
        //     于是门控变异走到 `isSafeToClean(target)` 时仍被它第一层的 `isSymlink` 拒掉，
        //     `failedPaths` 照旧是 `[link]`——**拒绝来自别人**，判据死了也不红。
        //     所以夹具必须用**活的**目标：默认支会真把它搬进废纸篓，收尾按仓里 §27 那条既有做法，
        //     只删自己建的东西、且删除清单直接取返回的 `trashedSnapshots`（实现正确时它是空的，
        //     defer 自然空转）。
        check("默认支（移入废纸篓）也拒软链：目标必须原地不动，且不许留下快照") {
            let root = "/private/tmp/macclean_symlink_default_\(UUID().uuidString)"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }
            let victim = root + "/victim.txt"      // 软链背后的那份真文件
            let link = root + "/listed.pdf"        // 列表上写着的那一项
            try? "合同正文".write(toFile: victim, atomically: true, encoding: .utf8)
            do { try fm.createSymbolicLink(atPath: link, withDestinationPath: victim) }
            catch { print("      造不出软链夹具，本条未执行：\(error)"); return false }
            let item = CleanItem(name: "listed.pdf", path: link, size: 12,
                                 rule: "T1", category: .largeFiles, note: "软链夹具")
            let result = Cleaner.clean([item], permanently: false) { _ in }
            // 只有判红分支才会有快照：那说明这一项被搬进了废纸篓，就把刚建的那份清走
            defer { for snap in result.trashedSnapshots { try? fm.removeItem(atPath: snap.trashPath) } }
            var bad: [String] = []
            if !result.trashedSnapshots.isEmpty {
                bad.append("软链被搬进了废纸篓（\(result.trashedSnapshots.count) 份快照，记的还是目标路径 "
                           + "\(result.trashedSnapshots.first?.originalPath ?? "?")，不是用户点名的那一项）"
                           + "——判据被 forcePermanent 门控掉就是这一形状")
            }
            if !fm.fileExists(atPath: victim) {
                bad.append("软链指向的真文件没了——这正是「删掉列表上根本没写的那个东西」")
            }
            if result.failedPaths != [link] {
                bad.append("软链没进失败集合（\(result.failedPaths)）——被门控掉的那一支会静默跳过")
            }
            if result.succeeded != 0 { bad.append("一项都没删成却计了成功：\(result.succeeded)") }
            if result.releasedBytes != 0 { bad.append("什么都没删却报释放 \(result.releasedBytes) 字节") }
            var st = stat()
            if lstat(link, &st) != 0 || (st.st_mode & S_IFMT) != S_IFLNK {
                bad.append("软链入口不在了（被顺手清掉了？）")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 3. 行为：历史行与撤销快照必须成对。这是 P0 的正题——以前两条分开写，
        //    "写了历史忘写快照"在结构上是允许的。
        check("DeletionLedger.write：移入废纸篓的记录一定能按 recordID 找到同条目数的快照") {
            ledgerScope("pair") {
                let entries = [
                    TrashedItemEntry(originalPath: "/Users/example/a.txt",
                                     trashPath: "/Users/example/.Trash/a.txt",
                                     size: 2_000, itemName: "a.txt"),
                    TrashedItemEntry(originalPath: "/Users/example/b.txt",
                                     trashPath: "/Users/example/.Trash/b.txt",
                                     size: 3_000, itemName: "b.txt")
                ]
                let written = DeletionLedger.write(categoryName: "自检-配对",
                                                   itemCount: 2, bytes: 5_000,
                                                   trashedBytes: 5_000, failures: 0,
                                                   permanently: false, snapshots: entries)
                var bad: [String] = []
                guard let record = written.record else {
                    print("      历史行没写出来"); return false
                }
                if HistoryStore.load().first(where: { $0.id == record.id }) == nil {
                    bad.append("落盘后读不回这条记录")
                }
                guard let session = UndoManagerStore.session(for: record.id) else {
                    print("      历史行有了、撤销快照没有 —— 正是本轮修的那个 P0 形状")
                    return false
                }
                if session.entries.count != 2 { bad.append("快照条目数 \(session.entries.count) ≠ 2") }
                if session.recordID != record.id { bad.append("快照挂到了别的记录上") }
                if written.undoSessionID != session.id { bad.append("返回的 undoSessionID 与实际会话不符") }
                if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
                return bad.isEmpty
            }
        }

        // 4. 彻底删除**不许**留快照（留了就是承诺一个放不回来的"放回原位"）。
        check("DeletionLedger.write：彻底删除的记录不配撤销快照") {
            ledgerScope("perm") {
                let written = DeletionLedger.write(categoryName: "自检-彻底删除",
                                                   itemCount: 1, bytes: 1_000, trashedBytes: 0,
                                                   failures: 0, permanently: true,
                                                   snapshots: [TrashedItemEntry(originalPath: "/Users/example/x.txt",
                                                                                trashPath: "/Users/example/.Trash/x.txt",
                                                                                size: 1_000, itemName: "x.txt")])
                guard let record = written.record else { print("      历史行没写出来"); return false }
                if UndoManagerStore.session(for: record.id) != nil {
                    print("      彻底删除却写了撤销快照（放回原位是个假承诺）"); return false
                }
                if record.mode != "彻底删除" { print("      mode 与实际落点不符：\(record.mode)"); return false }
                return true
            }
        }

        // 5. 空跑不落行：什么都没删成、也没失败时不许刷历史（200 条上限不该用在噪声上）。
        //    反过来，**全失败**必须落一行：否则"没人看着的那条链路一直删不动"永远看不见。
        check("DeletionLedger.write：无事发生不落行，全失败必须落行") {
            ledgerScope("empty") {
                if DeletionLedger.write(categoryName: "自检-空跑", itemCount: 0, bytes: 0,
                                        trashedBytes: 0, failures: 0,
                                        permanently: false, snapshots: []).record != nil {
                    print("      什么都没删却写了一行历史"); return false
                }
                if !HistoryStore.load().isEmpty {
                    print("      盘上多了一条空记录"); return false
                }
                guard let failed = DeletionLedger.write(categoryName: "自检-全失败", itemCount: 0, bytes: 0,
                                                        trashedBytes: 0, failures: 3,
                                                        permanently: false, snapshots: []).record else {
                    print("      3 项失败被当成无事发生（静默链路于是永远看不见失败）"); return false
                }
                if failed.failures != 3 { print("      失败数没落进历史"); return false }
                return true
            }
        }

        // 6. 走通 `clean()` 全程：真删一个临时文件。用 `permanently: true`，
        //    因此**不碰用户真实废纸篓**（同 §12 那条 toTrash 纪律）。
        check("DeletionLedger.clean 端到端：删成的项落一行、mode 与实际落点一致") {
            let tmpDir = "/private/tmp/macclean_ledger_e2e_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }
            let file = tmpDir + "/gone.txt"
            try? "payload".write(toFile: file, atomically: true, encoding: .utf8)

            return ledgerScope("e2e") {
                let item = CleanItem(name: "gone.txt", path: file, size: 7,
                                     rule: "T1", category: .largeFiles, note: "自检端到端夹具")
                let outcome = DeletionLedger.clean([item], permanently: true, categoryName: "自检-端到端")
                var bad: [String] = []
                if outcome.result.succeeded != 1 { bad.append("夹具没删成：succeeded=\(outcome.result.succeeded)") }
                if FileManager.default.fileExists(atPath: file) { bad.append("文件还在，却宣称删成了") }
                if let row = outcome.record {
                    if row.mode != "彻底删除" { bad.append("mode 与实际落点不符：\(row.mode)") }
                    // 一次性目录里只该有出口刚写的这一条：多一条说明记账写到了别处，
                    // 少一条说明 `clean()` 的记账分支根本没跑。
                    let rows = HistoryStore.load()
                    if rows.count != 1 { bad.append("历史里有 \(rows.count) 条（应为 1 条）") }
                    if UndoManagerStore.session(for: row.id) != nil { bad.append("彻底删除不该有撤销快照") }
                } else {
                    bad.append("删成了却没有历史行")
                }
                if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
                return bad.isEmpty
            }
        }

        // 7. 出口必须把**落盘后合并回来的整份清单**交回去，而不是调用方那份陈旧缓存
        //    （v1.72 的真实事故：某调用方拿启动时读到的列表整片写回，抹掉了并发写入的记录）。
        check("DeletionLedger.write 返回合并后的完整清单（陈旧缓存整片覆盖的老形状不许回来）") {
            ledgerScope("merge") {
                HistoryStore.replaceAllForSelftest([CleanRecord(categoryName: "自检-别人先写的",
                                                                itemCount: 1, bytes: 1,
                                                                mode: "废纸篓", failures: 0)])
                let written = DeletionLedger.write(categoryName: "自检-我后写的", itemCount: 1,
                                                   bytes: 2, trashedBytes: 2, failures: 0,
                                                   permanently: false, snapshots: [])
                guard let merged = written.history else { print("      没返回合并清单"); return false }
                if merged.count != 2 {
                    print("      合并清单只有 \(merged.count) 条，另一条被覆盖"); return false
                }
                let names = Set(HistoryStore.load().map(\.categoryName))
                return names.contains("自检-别人先写的") && names.contains("自检-我后写的")
            }
        }
        // 8. `clean()` 的**废纸篓分支**必须由注入缝覆盖。
        //    端到端那条（第 6 号）故意用 `permanently: true`——不污染真废纸篓的代价是
        //    永远走不到快照分支，于是"把 `snapshots:` 改成 `[]`""把 `trashedBytes:` 改成 0"
        //    这两种改动都能让全量自检一字不差地全绿（v1.73.15 复审 P1-F1 实测）。
        //    注入缝把 `Cleaner` 的返回值变成可造的数据，账本搬运的每一列都可断言。
        check("DeletionLedger.clean 把结果里的快照与落点原样搬进账本（注入缝，不碰真废纸篓）") {
            ledgerScope("seam") {
                // ⚠ 四个数必须**两两不等**：上一版让 `size == releasedBytes == trashedBytes == 4_000`，
                //   于是把 `bytes: result.releasedBytes`（实际释放）改回
                //   `bytes: Σitem.size`（**计划量**，正是 N8 明令禁止的那条退行）实测全绿
                //   ——v1.73.15 二次复审 P2。同理 `failures` 在旧夹具里恒 0，硬编 0 也不红。
                let fakeSnapshots = [TrashedItemEntry(originalPath: "/Users/example/a.bin",
                                                      trashPath: "/Users/example/.Trash/a.bin",
                                                      size: 1_111, itemName: "a.bin"),
                                     TrashedItemEntry(originalPath: "/Users/example/b.bin",
                                                      trashPath: "/Users/example/.Trash/b.bin",
                                                      size: 2_222, itemName: "b.bin")]
                let plannedTotal: Int64 = 9_999     // 三项的计划量
                let released: Int64 = 3_333          // 实际释放，故意 ≠ 计划量
                let trashed: Int64 = 2_222           // 其中还压在废纸篓里的，又与 released 不等
                let saved = DeletionLedger.deleter
                defer { DeletionLedger.deleter = saved }
                DeletionLedger.deleter = { _, _, _ in
                    var r = Cleaner.Result()
                    r.succeeded = 2
                    r.releasedBytes = released
                    r.trashedBytes = trashed
                    r.failures = ["copy failed"]
                    r.trashedSnapshots = fakeSnapshots
                    return r
                }
                let items = [
                    CleanItem(name: "a.bin", path: "/Users/example/a.bin", size: 4_444,
                              rule: "T1", category: .userCaches, note: "注入夹具"),
                    CleanItem(name: "b.bin", path: "/Users/example/b.bin", size: plannedTotal - 4_444,
                              rule: "T1", category: .userCaches, note: "注入夹具")
                ]
                let outcome = DeletionLedger.clean(items, permanently: false, categoryName: "自检-注入")
                var bad: [String] = []
                guard let row = outcome.record else { print("      没落历史行"); return false }
                if row.trashedBytes != trashed { bad.append("落点列没搬进账：trashedBytes=\(String(describing: row.trashedBytes)) ≠ \(trashed)") }
                if row.bytes != released { bad.append("字节列搬错了：bytes=\(row.bytes)，既不是实际释放 \(released) 也不该是计划量 \(plannedTotal)") }
                if row.bytes == plannedTotal { bad.append("bytes 退回了**计划量**（N8 禁止的那条）") }
                if row.itemCount != 2 { bad.append("条数没搬进账：\(row.itemCount)") }
                if row.failures != 1 { bad.append("失败数没搬进账：\(row.failures)") }
                if row.mode != "废纸篓" { bad.append("mode 与 permanently 不符：\(row.mode)") }
                guard let session = UndoManagerStore.session(for: row.id) else {
                    print("      快照没写 —— 正是可以在 clean() 里静默丢掉的那一格")
                    return false
                }
                if session.entries.count != 2 {
                    bad.append("快照条目数 \(session.entries.count) ≠ 2")
                } else {
                    if session.entries.map(\.trashPath).sorted() != ["/Users/example/.Trash/a.bin", "/Users/example/.Trash/b.bin"].sorted() {
                        bad.append("快照的废纸篓落点与注入的不符：\(session.entries.map(\.trashPath))")
                    }
                    if session.entries.reduce(Int64(0), { $0 + $1.size }) != 1_111 + 2_222 {
                        bad.append("快照里的字节数没搬对")
                    }
                }
                if outcome.undoSessionID != session.id { bad.append("返回的会话 id 与实际不符") }
                if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
                return bad.isEmpty
            }
        }

        // 8b. 归档拿到落点时**必须真的写快照**。上一版只喂 `trashPath: nil` 那一支，
        //     于是把 `snapshots: snapshots` 改成 `snapshots: []`（拿得到落点也不写）实测全绿
        //     ——v1.73.15 二次复审 P1-2，而这正是本轮 P0 的正题在归档链路上的形状。
        check("归档记账：有废纸篓落点就必须能按 recordID 取回那份快照") {
            ledgerScope("withTrashURL") {
                SpaceArchiveService.recordTrashedOriginal(categoryName: "自检-归档有落点",
                                                          originalPath: "/Users/example/big.tar",
                                                          trashPath: "/Users/example/.Trash/big.tar",
                                                          size: 7_000)
                guard let row = HistoryStore.load().first(where: { $0.categoryName == "自检-归档有落点" }) else {
                    print("      历史里没这条"); return false
                }
                guard let session = UndoManagerStore.session(for: row.id) else {
                    print("      有落点却没写快照 —— 「放回原位」在归档链路上又变成假承诺"); return false
                }
                guard let e = session.entries.first else { print("      快照是空的"); return false }
                if e.originalPath != "/Users/example/big.tar" || e.trashPath != "/Users/example/.Trash/big.tar" {
                    print("      快照内容与实参不符：\(e.originalPath) → \(e.trashPath)"); return false
                }
                if e.size != 7_000 { print("      快照里的体积没搬对：\(e.size)"); return false }
                return true
            }
        }

        // 9. 归档/迁移拿不到废纸篓落点时**仍要落一行**（UI 已经播报"原件已移入废纸篓"）。
        //    以前 `guard let trashPath else { return }` 会连账一起跳过（v1.73.15 复审 P1-F4），
        //    而那条链路唯一的运行时套件（SpaceArchiveDeep）在本机是崩溃未执行的，
        //     lint 也只判字面存在——包一层 `if !skip` 就能全绿，所以必须这样直接调它断言。
        check("归档记账：拿不到废纸篓落点也落一行，只是不给放回按钮") {
            ledgerScope("noTrashURL") {
                SpaceArchiveService.recordTrashedOriginal(categoryName: "自检-归档无落点",
                                                          originalPath: "/Users/example/old.tar",
                                                          trashPath: nil,
                                                          size: 9_000)
                let rows = HistoryStore.load()
                guard let row = rows.first(where: { $0.categoryName == "自检-归档无落点" }) else {
                    print("      历史里查无此事，而 UI 会播『原件已移入废纸篓』")
                    return false
                }
                if row.itemCount != 1 { print("      落了行但条数不对：\(row.itemCount)"); return false }
                // 没有落点就没有快照：这是**降级按钮**，不是降级账。
                if UndoManagerStore.session(for: row.id) != nil {
                    print("      没有废纸篓落点却写了快照（放回原位会失败）"); return false
                }
                return true
            }
        }

        // 10. G21 同族第三处（v1.73.15）：`HardlinkDedupService.preflight` 此前也是
        //     先 `realPath`、再拿解析完的路径去问 `isSymlink`——同一具死判据，第二个出口。
        //     ⚠ lint 必须**按函数体**切：这个文件里 `guardRejection` 自己也有一处合法的
        //     `realPath`，整档比"谁先出现"会被它背书（取窗会被相邻定义顶掉，见 RELEASE-CHECKLIST §活性证据）。
        check("G21b 硬链接去重的软链判据排在解析之前（按 preflight 函数体切，不靠整档第一次）") {
            let dir = Selftest.sourceDirectoryPath
            let src = (try? String(contentsOfFile: (dir as NSString)
                                    .appendingPathComponent("HardlinkDedupService.swift"),
                                  encoding: .utf8)) ?? ""
            let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
            guard let head = code.range(of: "funcpreflight(source:String,target:String,") else {
                print("      找不到 preflight 签名（签名改了？判据要跟着改，别删）"); return false
            }
            // 从签名往后走到第一个 `{`，再按大括号深度截出函数体
            var i = head.upperBound
            var bodyStart = code.endIndex
            var endIdx = code.endIndex
            var depth = 0
            while i < code.endIndex {
                let c = code[i]
                if c == "{" {
                    if depth == 0 { bodyStart = code.index(after: i) }
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 { endIdx = i; break }
                }
                i = code.index(after: i)
            }
            guard depth == 0, bodyStart < endIdx else {
                print("      preflight 函数体截不出来"); return false
            }
            let body = String(code[bodyStart..<endIdx])
            guard let firstResolve = body.range(of: "FileSystem.realPath(") else {
                print("      preflight 里没有 realPath——出口整块搬走了，这条判据不能沉默"); return false
            }
            let pre = String(body[body.startIndex..<firstResolve.lowerBound])
            var bad: [String] = []
            // 三个 needle 各拦一种改法：只查先后顺序的话，把循环遍历换成解析后的两个变量
            // （文本位置不动、语义仍是死的）照样全绿。
            if !pre.contains("isSymlink(path)") {
                bad.append("解析之前没有软链判据——挪到 realPath 之后 lstat 就永远答「不是」")
            }
            if !pre.contains("(\"源\",source)") { bad.append("软链循环没遍历未解析的 source") }
            if !pre.contains("(\"目标\",target)") { bad.append("软链循环没遍历未解析的 target") }
            if body.contains("isSymlink(realSource)") || body.contains("isSymlink(realTarget)") {
                bad.append("判据对着解析后的 realSource/realTarget 问是不是软链（这就是修之前的形状）")
            }
            // 同 2c：终审 F2 实测"死分支包壳"（`if false { for … }`）能让形状与先后都过关。
            if let loop = body.range(of: "for(role,path)in[(\"源\",source)") {
                if Selftest.braceDepth(in: body, upTo: loop.lowerBound) != 0 {
                    bad.append("软链循环不在 preflight 顶层：整块包进任何分支时形状不变、判据已经不执行")
                }
            } else {
                bad.append("找不到顶层的软链循环（针脚形状改了？判据要跟着改，别删）")
            }
            if !bad.isEmpty {
                print("      " + bad.joined(separator: "\n      "))
                return false
            }
            return true
        }

        // 11. 行为两侧都钉：软链必须拒（**源与目标两档**各测一次），且被它指的那份文件与软链本身
        //     都原样留下；反向对照是真重复副本必须**照常去重**——只钉前一半，实现改成「什么都拒」也全绿。
        check("硬链接去重遇到软链：源/目标两档都拒绝、背后文件与软链都还在；真重复副本照常去重") {
            ledgerScope("dedupSymlink") {
                let root = "/private/tmp/macclean_dedup_symlink_\(UUID().uuidString)"
                let fm = FileManager.default
                try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
                defer { try? fm.removeItem(atPath: root) }
                let keep = root + "/keep.bin"         // 真实源
                let victim = root + "/victim.bin"     // 软链背后的那份：用户从没点过名
                let link = root + "/dup.bin"          // 列表上写着的那一项，其实是软链
                let twin = root + "/twin.bin"         // 正向对照：货真价实的重复副本
                let payload = Data(repeating: 0x41, count: 200_000)   // 跨过内容抽查的 64 KB 取样窗口
                for p in [keep, victim, twin] {
                    HardlinkTestSupport.writeRaw(URL(fileURLWithPath: p), payload)
                    HardlinkTestSupport.age(p, days: 30)              // 绕过「刚被写入 = 可能在用」
                }
                do { try fm.createSymbolicLink(atPath: link, withDestinationPath: victim) }
                catch { print("      造不出软链夹具，本条未执行：\(error)"); return false }

                var bad: [String] = []
                let asTarget = HardlinkDedupService.performDedup(sourcePath: keep, targetPath: link,
                                                                 journal: .module(categoryName: "自检-软链拒绝"))
                if case .rejected(let reason) = asTarget.status {
                    if !reason.contains("符号链接") { bad.append("拒了，但理由不是软链：\(reason)") }
                } else {
                    bad.append("目标位置是软链却没拒——会 rename 覆盖背后的那份文件，且不可撤销：\(asTarget.status)")
                }
                if !fm.fileExists(atPath: victim) { bad.append("软链指向的真文件被动过了") }
                var st = stat()
                if lstat(link, &st) != 0 || (st.st_mode & S_IFMT) != S_IFLNK {
                    bad.append("软链本身不在了（或被换成硬链接）")
                }
                if HistoryStore.load().contains(where: { $0.categoryName == "自检-软链拒绝" }) {
                    bad.append("一次都没动却落了一行历史")
                }
                let asSource = HardlinkDedupService.performDedup(sourcePath: link, targetPath: keep,
                                                                 journal: .none)
                if case .rejected(let reason) = asSource.status {
                    if !reason.contains("符号链接") { bad.append("源是软链，拒错了理由：\(reason)") }
                } else {
                    bad.append("源位置是软链却没拒：\(asSource.status)")
                }
                let ok = HardlinkDedupService.performDedup(sourcePath: keep, targetPath: twin, journal: .none)
                if case .linked = ok.status {
                    // 正向对照通过
                } else {
                    bad.append("一致内容的真副本被误拒（判据是不是被改成「什么都拒」）：\(ok.status)")
                }
                if !bad.isEmpty {
                    print("      " + bad.joined(separator: "\n      "))
                    return false
                }
                return true
            }
        }
    }

    /// 在一次性目录里跑一段断言：历史与撤销快照两份存储都指过去，结束时**恢复原值**并删目录。
    /// 存回原值而不是 nil：nil 会把后面的用例落回真实状态目录，等于让这条用例改坏别人的环境。
    private static func ledgerScope(_ tag: String, _ body: () -> Bool) -> Bool {
        let savedHistory = HistoryStore.fileURLOverride
        let savedUndo = UndoManagerStore.fileURLOverride
        let dir = "/private/tmp/macclean_ledger_\(tag)_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        HistoryStore.fileURLOverride = URL(fileURLWithPath: dir + "/history.json")
        UndoManagerStore.fileURLOverride = URL(fileURLWithPath: dir + "/undo.json")
        defer {
            HistoryStore.fileURLOverride = savedHistory
            UndoManagerStore.fileURLOverride = savedUndo
            try? FileManager.default.removeItem(atPath: dir)
        }
        return body()
    }

    /// 数一段切片里、`idx` **之前**的净花括号深度（0 = 与该切片的顶层同层）。
    /// 为什么需要它：顺序判据只比"谁先出现"，于是 `if false { guard … }` 这种死分支包壳
    /// 让它照样绿——形状对、先后对、就是不执行（v1.73.15 终审 F2 实测两条 lint 双双放过）。
    /// 把"必须待在顶层"钉进来之后，包壳要红就得同时改形状，而改形状会被同一批 needle 抓住。
    private static func braceDepth(in code: String, upTo idx: String.Index) -> Int {
        var depth = 0
        var i = code.startIndex
        while i < idx {
            if code[i] == "{" { depth += 1 }
            else if code[i] == "}" { depth -= 1 }
            i = code.index(after: i)
        }
        return depth
    }
}
