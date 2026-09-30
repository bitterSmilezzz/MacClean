#!/bin/bash
# 脱敏扫描器的夹具自测：往一次性 git 仓库里种"看起来像真凭据"的串，断言门禁抓得住。
#
# 为什么要有这个脚本：`release.sh` 的扫描器此前**不可测**——它只能在自己的仓库上跑，
# 于是"能不能拦住真凭据"这件事全靠读代码相信。本轮修的就是它的三处自我豁免
# （整行判"一眼假"、备案表先于计数、`hist * 规则` 通配豁免），修完必须能反证。
# 用法: scripts/scan-selftest.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${REPO}/scripts/release.sh"
# 标记"我在自测里"：release.sh 见到它就不再回调本脚本（否则互相调用会无限递归）。
# ⚠ **只在需要它的那几条用例里逐条设置**，不许在这里全局 export：
#   `MC_REPO_DIR` 那一档的合法例外就是这个标记，全局导出会让"环境标记应当被拒绝"的
#   T33/T34 继承到它、双双放行（实测过），闸等于没做。
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/macclean-scan-selftest.XXXXXX")"
trap 'rm -rf "${WORKROOT}"' EXIT
PASS=0; FAIL=0

# 凭据形状一律**运行时拼出来**：这个脚本自己会进公开仓库，写死字面量就等于
# 让扫描器命中自己的测试代码（那才是真的把门禁搞坏）。
# ⚠ frag_pem 上一版就是反面教材：它把 PEM 头原样写在源码里，于是**自测脚本自己**
#   成了 private_key 的未备案命中——abs 一档要求"证据提交动过这个文件"，而新脚本
#   此刻还不在任何提交里，备案永远补不上 = 门禁把自己锁死。分片拼出来就没得可扫。
frag_token() { printf 'gh%s_%s' "p" "$(printf 'A%.0s' $(seq 1 30))"; }        # GitHub classic 形状
frag_fine()  { printf 'github_%s_%s' "pat" "$(printf 'b%.0s' $(seq 1 30))"; } # 细粒度 PAT 形状
frag_pem()   { printf -- '-----%s %s %s-----' "BEGIN RSA" "PRIVATE" "KEY"; }  # 只有头、无体
frag_aws()   { printf 'AKIA%s' "$(printf 'B%.0s' $(seq 1 16))"; }
# 复审实测：rules() 九条里 slack / google / jwt / secret_assign **四条零覆盖**
# （把那四行 printf 删掉，夹具自测照样 22 全绿）。这四条恰恰是外泄面最大的形状，
# 每条都得有自己的用例——见下面 T23–T26。
frag_slack()  { printf 'xox%s-%s' "b" "$(printf 'C%.0s' $(seq 1 14))"; }
frag_google() { printf 'AIz%s%s' "a" "$(printf 'E%.0s' $(seq 1 32))"; }
frag_jwt()    { local a; a="$(printf 'G%.0s' $(seq 1 20))"; printf 'eyJ%s.eyJ%s' "${a}" "${a}"; }
frag_pw()     { printf 'password = "%s"' "$(printf 'H%.0s' $(seq 1 24))"; }
# 同一规则、**不同内容**的第二串：用来验"备案按内容钉"（复审 P0）。
frag_pem2()   { printf -- '-----%s %s %s-----' "BEGIN OPENSSH" "PRIVATE" "KEY"; }

# 非 abs 一档**且片段自己不带任何占位词形状**的串：专门用来区分"判整行"与"判片段"。
# 分两段拼：整串写在一个字面量里就等于让本脚本自己成为 openai_style_key 的未备案命中
# （它不带占位词，"一眼假"救不了它——这正是 T18 要测的那种形状）。
frag_openai() { printf 'sk-%s%s' "ZqLkMnBvTxCvBnMz" "AsDfGhJkLqZx"; }
# 非 abs 一档：占位标记必须写在**匹配片段自己身上**。旧写法判整行，于是
# `let fake = "<真凭据>"` 会因为变量名叫 fake 而被放行——这条测试本身就是反例。
frag_fake()  { printf 'sk-%s' "PLACEHOLDER_KEY_0000000000"; }

# 与 release.sh 的 frag_id 同算法：备案表 abs 一档要按**内容指纹**豁免，
# 所以夹具也得算得出同一个值（复审 P0：只按 (scope,file,rule) 备案 = 该文件对该规则永久失明）。
pin()  { printf '%s' "$1" | shasum | cut -c1-12; }

# 外层套一个**能用的**看门狗：`perl -e 'alarm N; exec @ARGV'` 的 alarm 不跨 execve，
# 定时器会被抹掉（本项目的 review README 里就记着这条），所以 fork 之后在父进程里计时。
# 真需要它的地方是 T33/T34：那两条在"闸门被拆掉"的变异副本里会一路走进构建、甚至
# 与回调自测互相递归（实测堆到 42 个进程），没有上界就变成一场事故而不是一条红。
bounded() { # <秒> <命令…>
    perl -e 'my $t=shift; my $p=fork; if(!defined $p){exit 1}
             if($p==0){ exec @ARGV or exit 127 }
             local $SIG{ALRM}=sub{ kill "TERM",$p; sleep 3; kill "KILL",$p };
             alarm $t; waitpid $p,0; my $r=$?; alarm 0;
             exit($r & 127 ? 124 : $r >> 8);' "$@"
}

ok()   { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# mk_repo <名字>：建一个带标准目录骨架的一次性仓库
mk_repo() {
    local d="${WORKROOT}/$1"
    mkdir -p "${d}/Sources" "${d}/docs" "${d}/scripts" "${d}/Resources"
    : > "${d}/Package.swift"; : > "${d}/Package.resolved"
    # 骨架**不提交**：一旦在这里 commit 掉，后面"git add -A && git commit"的种夹具
    # 步骤就变成空提交（nothing to commit），夹具根本没进历史——T6/T7 实测被这样吞掉。
    # T4 需要的"无关提交不许动过被测文件"改由该用例自己限定 pathspec 来保证。
    # README 必须**带内容**：树侧的活性探针扫的是"任何非空行"，全空的骨架会让
    # 每条用例都被判成"扫描器一次都没跑"，探针于是变成假的红。
    ( cd "${d}" && git init -q -b main && git config user.email t@example.com \
        && git config user.name "selftest" && : > Sources/a.swift \
        && printf 'selftest scaffold repo\n' > README.md ) >/dev/null 2>&1
    printf '%s' "${d}"
}

# 备案表：scope<TAB>file<TAB>rule<TAB>reason
write_allowlist() { # <repo> <一行备案>
    printf '%s\n' "# 自测备案表" > "${1}/scripts/secrets-allowlist.txt"
    [ -z "${2:-}" ] || printf '%b\n' "$2" >> "${1}/scripts/secrets-allowlist.txt"
}

# 备案规则有两套代码：树侧（scan_tree）与历史侧（scan_history）。**已提交且仍留在工作区
# 的文件会被两条同时看到**，于是"测历史备案"的用例其实被树侧的未备案命中兜住了——
# 红绿看着都对，测的却不是它声称的那条规则（变异验证实测到三条这种空断言）。
# 所以：测历史侧要把文件从工作区删掉（内容只留在历史里）；测树侧用 --staged 且不提交。
commit_then_vanish() { # <repo> <file>：提交后从工作区删除，只留历史
    ( cd "$1" && git add -A && git commit -qm "plant" >/dev/null \
        && git rm -q "$2" && git commit -qm "vanish" >/dev/null )
}

# expect <die|pass> <说明> <repo> [staged] [拦住它的那一侧必须出现的字样]
# 第 5 参是**归因**：光看退出码非零分不清"谁拦的"。旧写法就吃过这个亏——
# 树侧扫描整体坏掉（bash 3.2 空数组事故）时，16 条夹具**全绿**，因为种在已提交
# 文件里的命中都被历史侧兜住了。只有要求"必须是 tree 侧拦的"，树侧坏掉才会变红。
expect() {
    local want="$1" label="$2" repo="$3" staged="${4:-}" marker="${5:-}" out rc
    # /bin/bash 而不是 PATH 上的 bash：生产是 `./scripts/release.sh`，走 shebang
    # `/bin/bash`；自测若被 brew/zsh 之类换掉解释器，测的就不是发版用的那条路径
    # （本轮的数组事故恰好是 bash 3.2 独有的行为）。
    ( cd "${repo}" && MC_REPO_DIR="${repo}" /bin/bash "${RUNNER}" --scan-only ${staged} ) \
        > "${WORKROOT}/last.log" 2>&1
    rc=$?
    if printf '%s' "${want}" | grep -q '^blocked:'; then
        local pat="${want#blocked:}"
        if [ "${rc}" -ne 0 ] && grep -qE "${pat}" "${WORKROOT}/last.log"; then
            ok "${label}（按预期中止：/${pat}/）"
        elif [ "${rc}" -eq 0 ]; then
            bad "${label}：竟然放行了——这一档必须 fail-closed"
        else
            bad "${label}：非零退出但不是预期的中止（找不到 /${pat}/）"
            grep -E '❌|✖' "${WORKROOT}/last.log" | head -2 | sed 's/^/       /'
        fi
    elif [ "${want}" = die ] && [ "${rc}" -ne 0 ]; then
        # 阴性对照：非零码可能是"扫描器自己执行失败"（pathspec 不匹配、grep 报错、
        # 脚本语法坏了…），那不等于拦住了。只有报出未备案命中才算数。
        if grep -qE "扫描规则执行失败|No such file|未预期" "${WORKROOT}/last.log" \
           || ! grep -qE "✖|不允许用于真发版" "${WORKROOT}/last.log"; then
            bad "${label}：退出码非 0 但不是因为命中——扫描器执行失败会被当成拦住"
            grep -E "扫描规则执行失败|No such file|fatal" "${WORKROOT}/last.log" | head -2 | sed 's/^/       /'
        elif [ -n "${marker}" ] && ! grep -qE "${marker}" "${WORKROOT}/last.log"; then
            bad "${label}：拦住了但不是预期那一侧（找不到 /${marker}/）——另一侧兜底会把这条测成空断言"
        else
            ok "${label}（按预期拦住，exit=${rc}${marker:+，归因 /${marker}/ 已确认}）"
        fi
    elif [ "${want}" = pass ] && [ "${rc}" -eq 0 ]; then
        # 放行也得证明扫描器真的跑过：活性探针没出现 = 它可能一行都没看
        if ! grep -q "扫描器活性" "${WORKROOT}/last.log"; then
            bad "${label}：放行但没看到扫描器活性证据"
        else
            ok "${label}（按预期放行）"
        fi
    else
        bad "${label}：期望 ${want}，实得 exit=${rc}"
        grep -E "✖|✅ 扫描通过|die|失败" "${WORKROOT}/last.log" | head -4 | sed 's/^/       /'
    fi
}

echo "--- 脱敏扫描器夹具自测"

# T1 真凭据与 `test` 同行：旧实现判的是**整行**内容，含 test 就只打印不计数
# 夹具要点：变量名写成 `testToken` —— 它让**整行**命中"一眼假"，而片段本身不命中。
# 上一版写成 `// test 环境`，那既不被整行判据命中、也不被片段判据命中，
# 于是"判整行"与"判片段"行为等价，MU1 变异实测假幸存。
R=$(mk_repo t1); printf 'let testToken = "%s"\n' "$(frag_token)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm "t1") ; expect die "T1 abs 命中：整行含 testToken 也不许走夹具豁免" "${R}" "" "未备案 +tree"

# T1b 片段**自己**含占位词的 abs 命中：只把"判整行"改成"判片段"还不够，
# abs 一档必须连片段里的占位词也不认——真 token 完全可以长得像 `ghp_EXAMPLE…`。
R=$(mk_repo t1b); printf 'let k = "ghp_%s%s"\n' "EXAMPLE" "$(printf 'C%.0s' $(seq 1 24))" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm "t1b") ; expect die "T1b abs 一档不因片段含占位词而豁免" "${R}" "" "未备案 +tree"

# T1c 树侧/staged 侧单独判：文件**只 add 不 commit**，历史里查不到，
# 于是这条只由 `scan_tree` 的"判片段"决定。没有它，把树侧改回"判整行"不会变红
# （历史扫描会替它兜底，变异验证实测到这次假幸存）。
R=$(mk_repo t1c); write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm base >/dev/null)
# 只 add 不 commit：历史里查不到，这条就只由树侧/staged 侧的判据决定
printf 'let testToken = "%s"\n' "$(frag_token)" > "${R}/docs/staged.swift"
(cd "${R}" && git add -- docs)
expect die "T1c staged 单判：整行含 testToken 也不许走夹具豁免" "${R}" "--staged" "未备案 +tree"

# T2 通配备案：旧表里就有一行 `hist * private_key`，等于把私钥规则对全历史关掉
# evidence 给**真实且动过该文件**的提交：这样"证据"那一关是过的，
# 唯一能拦住它的只剩"abs 一档不接受通配 file"这条规则本身（否则它会被
# 后面那条证据判据顺手兜住，两条保护互相掩盖，变异验证就分不出谁在起作用）。
R=$(mk_repo t2); printf '%s\n' "$(frag_pem)" > "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm plant >/dev/null)
C2=$(cd "${R}" && git rev-parse HEAD)
git -C "${R}" rm -q Sources/a.swift && ( cd "${R}" && git commit -qm vanish >/dev/null )
write_allowlist "${R}" "hist\t*\tprivate_key\t自测：通配应当无效 evidence=${C2:0:8}\tmatchsha=$(pin "$(frag_pem)")"
expect die "T2 abs 一档通配 file 不生效（证据本身合法）" "${R}" "" "未备案 +hist"

# T3 缺 evidence：确切文件但没写证据
R=$(mk_repo t3); printf '%s\n' "$(frag_pem)" > "${R}/Sources/a.swift"
write_allowlist "${R}" "hist\tSources/a.swift\tprivate_key\t自测：没有 evidence\tmatchsha=$(pin "$(frag_pem)")"
commit_then_vanish "${R}" Sources/a.swift
expect die "T3 abs 备案缺 evidence 不生效（内容只存在于历史）" "${R}" "" "未备案 +hist"

# T4 evidence 与 commit 对不上
# evidence 用**另一个真实提交**的 sha：①"提交存在"那关是过的，
# 唯一能拦住它的只剩②"那个提交必须真的动过这个文件"。
R=$(mk_repo t4); : > "${R}/docs/other.md"
# 限定 pathspec：只动 docs，别把被测文件一起捎进这个提交
(cd "${R}" && git add docs/other.md && git commit -qm "无关提交" >/dev/null)
OTHER=$(cd "${R}" && git rev-parse HEAD)
printf '%s\n' "$(frag_aws)" > "${R}/Sources/a.swift"
commit_then_vanish "${R}" Sources/a.swift
write_allowlist "${R}" "hist\tSources/a.swift\taws_access_key\t自测 evidence=${OTHER:0:8}\tmatchsha=$(pin "$(frag_aws)")"
expect die "T4 evidence 是真实提交但不是命中的那个 → 不生效" "${R}" "" "未备案 +hist"

# T5 阴性对照：确切文件 + 正确 evidence **必须**放行，否则等于"什么都拦"看着安全
R=$(mk_repo t5); printf '%s\n' "$(frag_pem)" > "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm "t5") ; C=$(cd "${R}" && git rev-parse HEAD)
git -C "${R}" rm -q Sources/a.swift && ( cd "${R}" && git commit -qm vanish >/dev/null )
write_allowlist "${R}" "hist\tSources/a.swift\tprivate_key\t自测：形状即假 evidence=${C:0:8}\tmatchsha=$(pin "$(frag_pem)")"
expect pass "T5 精确备案 + 证据正确仍能放行（证明 T2–T4 不是误伤）" "${R}"

# T6 commit 正文里的凭据：旧实现只扫 `git log -p` 的 diff 行，正文根本没进扫描
R=$(mk_repo t6); : > "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm "顺手记一下 token: $(frag_token)")
write_allowlist "${R}" ""
expect die "T6 commit 正文里的凭据要被抓到" "${R}" "" "未备案 +hist"

# T7 tag 说明里的凭据
R=$(mk_repo t7); : > "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm "t7" && git tag -a v0.1 -m "release key $(frag_aws)")
write_allowlist "${R}" ""
expect die "T7 tag 说明里的凭据要被抓到" "${R}" "" "未备案 +hist"

# T8 细粒度 PAT：旧规则 `gh[pousrIw]_` 一类完全抓不到
R=$(mk_repo t8); printf 'let k = "%s"\n' "$(frag_fine)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm "t8") ; expect die "T8 细粒度 github_pat_ 要被抓到" "${R}" "" "未备案 +tree"

# T9 staged 复扫：凭据只存在于**本轮新增**的文件里，旧顺序（先扫后 add）看不见它
R=$(mk_repo t9); : > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm "t9 base")
printf 'let leaked = "%s"\n' "$(frag_token)" > "${R}/docs/new.swift"
(cd "${R}" && git add -- docs Sources README.md)
expect die "T9 staged 复扫要盖住本轮新增文件" "${R}" "--staged" "未备案 +tree"

# T10 非 abs 的占位串仍按夹具放行：不能为了安全把检测器自己的假凭据全打死。
# ⚠ 它是**纯粹的"别过度阻断"阴性对照**，对"判整行 vs 判片段"零判别力，而且**不可能**有：
#   匹配片段永远是整行的**子串**，所以"片段自证为假 ⇒ 整行也自证为假"，两个判据在这一侧
#   恒等；能区分二者的只有反方向——"行含占位词而片段不含"，那由 T18 守。
#   （今天先写了这条、又补了一条同形状的 T19 当"镜像"，其实是等价重复，已删。）
R=$(mk_repo t10); printf 'let fake = "%s"\n' "$(frag_fake)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm "t10") ; expect pass "T10 非 abs 且片段自证为假的占位串放行" "${R}"

# T10b tree 档的 evidence 也必须指向**真实存在的提交**：以前 tree scope 传空 commit，
# 于是 `evidence=随便写` 就能放行——那是第二个自我豁免面。
R=$(mk_repo t10b); (cd "${R}" && git add -A && git commit -qm base >/dev/null)
printf 'let k = "%s"\n' "$(frag_pem)" > "${R}/Sources/a.swift"
write_allowlist "${R}" "tree\tSources/a.swift\tprivate_key\t自测：假证据 evidence=deadbeef\tmatchsha=$(pin "$(frag_pem)")"
(cd "${R}" && git add -- Sources)
expect die "T10b tree 备案的 evidence 必须是真提交（staged 单判）" "${R}" "--staged" "未备案 +tree"

# T13 扫描范围必须是**全部跟踪文件**：种在根目录一个不在旧点名清单里的文件上，
# 且只用 --staged（不提交），这样历史侧兜不住它，点名清单的漏洞才会暴露。
R=$(mk_repo t13); (cd "${R}" && git add -A && git commit -qm base >/dev/null)
printf 'release notes: %s\n' "$(frag_pem)" > "${R}/CHANGELOG.md"
write_allowlist "${R}" ""
(cd "${R}" && git add CHANGELOG.md)
expect die "T13 根目录新增文件也要被扫到（staged 单判）" "${R}" "--staged" "未备案 +tree"

# T15 凭据**只在未提交的工作区**里：这是树侧唯一独占的场景。
# 前面所有 die 用例的内容都已经提交，历史侧都能兜住——于是本轮真实发生的那次事故
# （macOS bash 3.2 展开空数组报 unbound variable，`git grep` 一次都没执行）让 16 条
# 夹具**全部绿**，门禁安静地扫了 0 个文件却照样打印"✅ 扫描通过"。
# 这条没有历史侧兜底：树侧坏掉它必须立刻变红，同时也才是 assert_scanner_alive
# 那条活性探针存在的意义（两条保护各自独立，MU-TREE 变异分别验证过）。
R=$(mk_repo t15); write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm base >/dev/null)
printf 'let testToken = "%s"\n' "$(frag_token)" > "${R}/Sources/a.swift"
expect die "T15 只在未提交工作区里的凭据也要被抓到（树侧独占，历史兜不住）" "${R}" "" "未备案 +tree"

# T16 发版标题那一档（scan_text）：标题既不在工作区、也不在已入库的历史里，而它是
# **本轮即将写进 commit 正文、annotated tag 说明和 Release 标题**的那个字符串。
# 以前这三处一处都没扫，凭据写进标题就随本轮 tag 直接推出去、下一轮才红。
# MC_SCAN_TEXT 让夹具走同一条代码路径，而不是另写一份判据。
R=$(mk_repo t16); write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm base >/dev/null)
out=$( cd "${R}" && MC_REPO_DIR="${R}" MC_SCAN_TEXT="$(frag_token)" /bin/bash "${RUNNER}" --scan-only 2>&1 ); rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qE "未备案 +text"; then
    ok "T16 标题里的凭据被 text 档抓到（commit 正文/tag 说明/Release 标题共同的来源）"
else
    bad "T16 标题没扫或不是 text 档拦的（exit=${rc}）：凭据会随本轮 tag 推出去"
fi

# T16b 接线判据：T16 只证明 scan_text 这个函数能用，**主流程没人调用它**等于没扫
# （和 T12 同一族：本轮就差点把 run_scan 调用弄丢）。
if awk '/^run_scan\(\) \{/,/^\}/' "${RUNNER}" | grep -qE '^[[:space:]]*scan_text title "\$\{TITLE\}"'; then
    ok "T16b 发版主流程把标题接进了扫描"
else
    bad "T16b 主流程不再扫 TITLE：真实发版路径上的这一档失效"
fi

# T18 非 abs 一档："一眼假"必须只看**匹配片段**，不能看整行。
# T1/T1b 用的是 abs 规则，而 abs 在片段判据**之前**就 return 1 了，所以那两条永远
# 测不到"判整行 vs 判片段"的差别；唯一的非 abs 用例 T10 的占位词又长在片段自己身上，
# 两种判据在它身上行为等价——MU-FRAG 变异第一轮就是这样活下来的（假幸存）。
# 这条把占位词放在**行**上（`let dummy =`）、片段自身干净：只有判片段才会拦。
R=$(mk_repo t18); printf 'let dummy = "%s"\n' "$(frag_openai)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t18) ; expect die "T18 整行含 dummy 但片段自证不了假 → 必须拦（判片段才成立）" "${R}" "" "未备案 +tree"

# T11 `--skip-scan` 真发版必须**立刻中止**：旧行为是 warn 一句然后照常构建、提交、推送。
# 判据是有界的：拦住应当瞬间退出；若没拦住，它会进入构建阶段，25 s 内不会结束。
R=$(mk_repo t11); write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm base)
out=$( cd "${R}" && MC_REPO_DIR="${R}" MC_SCAN_SELFTEST=1 bounded 40 \
        /bin/bash "${RUNNER}" 9.9.9 "自测" --skip-scan 2>&1 ); rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -q "不允许用于真发版"; then
    ok "T11 --skip-scan 用于真发版时立刻中止"
else
    bad "T11 --skip-scan 只 warn 后继续（exit=${rc}）：门禁可以被绕过"
fi

# T12 接线判据：发版流程必须**真的**在 `git add` 之后、`git commit` 之前复扫索引。
# T9 只证明 `--scan-only --staged` 这个入口能用；入口没人调用等于没扫
# （本轮就差点把主流程的 run_scan 调用弄丢，靠 SCAN_RAN 硬闸才拦得住）。
# ⚠ 必须锚在**行首**：第一轮这里只 grep 子串，变异把整行注释掉（`# SCAN_INDEX=1 scan_tree`）
#   之后它照样匹配 → 结构性判据自己也是一条假断言。
# 形状 + **顺序**：复扫必须发生在 `git add` 之后，挪到前面等于没扫本轮新增的文件。
# 上一版只 grep 形状，复审把这两行整体前移到 `git add` 之前，T12 照样绿。
ADD_LN=$(awk '/^step "提交 \+ tag"/,/^# ----.*7 推送/' "${RUNNER}" | grep -nE '^[[:space:]]*git add -- ' | head -1 | cut -d: -f1)
RESCAN_LN=$(awk '/^step "提交 \+ tag"/,/^# ----.*7 推送/' "${RUNNER}" | grep -nE '^[[:space:]]*SCAN_INDEX=1[[:space:]]+scan_tree' | head -1 | cut -d: -f1)
if [ -n "${ADD_LN}" ] && [ -n "${RESCAN_LN}" ] && [ "${RESCAN_LN}" -gt "${ADD_LN}" ]; then
    ok "T12 staged 复扫在 git add 之后（第 ${ADD_LN} 行 add → 第 ${RESCAN_LN} 行复扫）"
else
    bad "T12 staged 复扫缺失或排在 git add 之前（add=${ADD_LN:-无} rescan=${RESCAN_LN:-无}）：新增未跟踪文件将绕过扫描"
fi

# T20 SCAN_RAN 硬闸两端都必须在：run_scan 里置位 + 提交步骤里判死（复审：删掉 die 那行仍全绿）
if grep -qE '^SCAN_RAN=1' "${RUNNER}"    && awk '/^step "提交 \+ tag"/,/^# ----.*7 推送/' "${RUNNER}" | grep -qE '\[ "\$\{SCAN_RAN\}" = 1 \] \|\| die'; then
    ok "T20 SCAN_RAN 硬闸两头齐全"
else
    bad "T20 SCAN_RAN 硬闸缺一头：run_scan 没被调用时提交步骤不再拦住"
fi

# T17 历史侧的"没扫"与"没历史"必须分得开：旧写法把空索引一律读成"无历史可扫"
# 然后 return 0，于是 detached HEAD、git 报错、awk 崩掉都长得像"这个仓库很干净"。
# 这一档**没法做行为夹具**——要它变红得让 `git log --all -p` 单独失败，而仓库里
# 每个提交都有正文，正常仓库永远造不出"有提交但索引为空"的状态。
# 所以这里只做**结构性**判据：阳性对照那一步必须在。别把它当成行为验证。
if awk '/^scan_history\(\) \{/,/^\}/' "${RUNNER}" | grep -qE '^[^#]*git rev-list --count --all' \
   && awk '/^scan_history\(\) \{/,/^\}/' "${RUNNER}" | grep -qE '^[[:space:]]*die "历史扫描：仓库有'; then
    ok "T17 历史侧带提交数阳性对照（结构性判据，非行为验证）"
else
    bad "T17 历史侧丢了阳性对照：扫描器坏掉会伪装成"仓库没有历史""
fi


# ================= 2026-10-01 独立复审（reviewer-r2）逐条补的缺口 =================

# T21 备案必须按**内容**钉：同一个文件、同一条规则，换了另一串内容必须重新判红。
# 复审实测（旧实现）：`Sources/f.swift` 里先种一行合法备案过的 PEM 头，再追加一把
# OPENSSH 私钥 → `rc=0` 打印「✅ 扫描通过」，22 条夹具全绿。
# 备案粒度是 (scope,file,rule) 时，一个文件只要有一条合法行，该文件对这条规则**永久失明**。
R=$(mk_repo t21); printf '%s\n' "$(frag_pem)" > "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm plant >/dev/null)
C21=$(cd "${R}" && git rev-parse HEAD)
printf '%s\n%s\n' "$(frag_pem)" "$(frag_pem2)" >> "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm two >/dev/null)
git -C "${R}" rm -q Sources/a.swift && ( cd "${R}" && git commit -qm vanish >/dev/null )
write_allowlist "${R}" "hist	Sources/a.swift	private_key	只给第一串指纹 evidence=${C21:0:8}	matchsha=$(pin "$(frag_pem)")"
expect die "T21 已备案的那串放行、同文件第二串私钥仍判红（备案按内容钉）" "${R}" "" "未备案 +hist"

# T22 同一行**两处**命中：中间那版只取第一个片段（`head -1`），于是"一个自证假的占位串
# + 一个真 key"只要占位串排在前面，整行就被放行（复审实测 rc=0，标题档同理）。
R=$(mk_repo t22); printf 'let a = "%s"; let b = "%s"\n' "$(frag_fake)" "$(frag_openai)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t22) ; expect die "T22 同行第二处命中也必须过审（不许只看第一个片段）" "${R}" "" "未备案 +tree"

# T23–T26 rules() 九条**每条都得有用例**：这四条以前零覆盖，删掉规则本身夹具毫无反应。
R=$(mk_repo t23); printf 'slack: %s\n' "$(frag_slack)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t23) ; expect die "T23 slack xoxb- 形状要被抓到" "${R}" "" "未备案 +tree"

R=$(mk_repo t24); printf 'google: %s\n' "$(frag_google)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t24) ; expect die "T24 Google API key 形状要被抓到" "${R}" "" "未备案 +tree"

R=$(mk_repo t25); printf 'jwt: %s\n' "$(frag_jwt)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t25) ; expect die "T25 JWT 两段式形状要被抓到" "${R}" "" "未备案 +tree"

R=$(mk_repo t26); printf '%s\n' "$(frag_pw)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t26) ; expect die "T26 secret_assign（password = 长串）要被抓到——外泄面最大的一条" "${R}" "" "未备案 +tree"

# T27 **默认（工作区）档**扫哪些文件以前没人守：给非 --cached 那支加个 `-- Sources`
# 仍然 22 全绿，而且活性探针照样打印"255 个文件搜过"（探针数的是文件，不是范围）。
# T13 那条是 --staged 走的，另一支坏掉它不红。
R=$(mk_repo t27); printf '%s\n' "$(frag_pem)" > "${R}/CHANGELOG.md"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t27) ; expect die "T27 根目录已提交文件在工作区档也要被扫到" "${R}" "" "未备案 +tree"

# T28 `--cached` 的**索引语义**：索引里干净、工作区脏 → staged 档应当放行、工作区档判红。
# 以前四条 --staged 用例的内容同时存在于工作区，把 `--cached` 整个去掉也全绿（复审）。
R=$(mk_repo t28); write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm base >/dev/null)
printf 'let clean = 1\n' > "${R}/Sources/a.swift"; ( cd "${R}" && git add -A && git commit -qm clean >/dev/null)
printf 'let leaked = "%s"\n' "$(frag_token)" > "${R}/Sources/a.swift"   # 只改工作区，不 add
expect pass "T28 索引干净而工作区脏：staged 复扫看的是索引（放行）" "${R}" "--staged"
expect die  "T28b 同一份内容走工作区档必须判红（证明 --cached 真的在读索引）" "${R}" "" "未备案 +tree"

# T29 活性探针的 **die 分支**要能被夹具打到：跟踪文件全是空的时候，
# "0 命中"必须解释成"扫描器没看过任何东西"，而不是"这个仓库很干净"。
R=$(mk_repo t29); : > "${R}/README.md"                                     # 抹掉骨架里那行字
# 这里**不许**用 `git add -A`：那会把未跟踪的备案表一起捎进仓库，而那文件非空，
# 探针于是有东西可搜、这条夹具就永远测不到"全空仓库"这一支。
(cd "${R}" && git add README.md Package.swift Package.resolved Sources/a.swift && git commit -qm empty) >/dev/null
expect "blocked:没有搜到任何内容" "T29 全空仓库里探针必须中止（不许报"扫描通过"）" "${R}"

# T30 命中打印必须**截断**：日志里出现完整凭据 = 门禁自己成了外泄渠道。
R=$(mk_repo t30); printf 'let testToken = "%s"\n' "$(frag_token)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm t30)
(cd "${R}" && MC_REPO_DIR="${R}" /bin/bash "${RUNNER}" --scan-only) > "${WORKROOT}/t30.log" 2>&1 || true
LEAK="$(frag_token)"
if grep -qF "${LEAK}" "${WORKROOT}/t30.log"; then
    bad "T30 扫描日志里出现了完整凭据串——mask 失效，门禁自己会外泄"
elif grep -q '\*\*\*' "${WORKROOT}/t30.log"; then
    ok "T30 命中值只打印前缀 + 掩码（完整串不在日志里）"
else
    bad "T30 既没找到完整串、也没找到掩码标记：判据本身可能坏了"
fi


# T31 出处是 <COMMIT-MSG> 的 abs 命中**结构上不可备案**，这是设计而不是遗漏：
# 它不属于任何文件，给它开一条按出处备案 = 把该规则对全部提交正文关掉。
# 复审指出这等于"没有出路"，所以主流程那段提示必须把第三条件说出来（见 run_scan）。
R=$(mk_repo t31); : > "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm "顺手记一下 token: $(frag_token)")
C31=$(cd "${R}" && git rev-parse HEAD)
write_allowlist "${R}" "hist	<COMMIT-MSG>	github_token	按出处备案应当无效 evidence=${C31:0:8}	matchsha=$(pin "$(frag_token)")"
expect die "T31 提交正文里的 abs 命中不接受备案（只能改历史，不能加表）" "${R}" "" "未备案 +hist"

# T32 本机身份以前**只扫工作区**：带 `/Users/<真实账号>` 的文件提交后再删掉就查无此人
# （复审实测 rc=0）。历史在公开仓库里是永久可查的，所以这一档两边都要扫。
R=$(mk_repo t32); printf 'cd /Users/%s/projects/x && make\n' "$(id -un)" > "${R}/Sources/a.swift"
write_allowlist "${R}" ""
(cd "${R}" && git add -A && git commit -qm plant) >/dev/null
git -C "${R}" rm -q Sources/a.swift && ( cd "${R}" && git commit -qm vanish >/dev/null )
expect die "T32 只存在于历史里的本机绝对路径也要被抓到" "${R}" "" "local_home 未备案 +hist"

# T33 回调标记必须是**成对**的：`MC_SCAN_SELFTEST=1` 单独存在就跳过整套夹具自测，
# 那是 env 级 fail-open（真实发版只要残留这一个变量，门禁的自证就整个不见了）。
R=$(mk_repo t33); (cd "${R}" && git add -A && git commit -qm base >/dev/null)
out=$( cd "${R}" && MC_SCAN_SELFTEST=1 bounded 90 /bin/bash "${RUNNER}" 9.9.9 "自测" --dry-run 2>&1 ); rc=$?
if printf '%s' "${out}" | grep -q 'MC_SCAN_SELFTEST=1 但没有 MC_REPO_DIR'; then
    ok "T33 只带自测标记、不带 MC_REPO_DIR 时直接中止"
else
    bad "T33 单个环境变量就能跳过夹具自测（exit=${rc}）：门禁可以被 env 静默关掉"
fi

# T34 `MC_REPO_DIR` 只许配合 `--scan-only`：它是"把扫描指到别的仓库"的夹具入口，
# 但在本脚本里它改的是**整条发版**的 cwd（构建/提交/tag/推送都跟着走）。
R=$(mk_repo t34); (cd "${R}" && git add -A && git commit -qm base >/dev/null)
out=$( cd "${R}" && MC_REPO_DIR="${R}" bounded 90 /bin/bash "${RUNNER}" 9.9.9 "自测" --dry-run 2>&1 ); rc=$?
if printf '%s' "${out}" | grep -q '只允许配合 --scan-only'; then
    ok "T34 真发版带上 MC_REPO_DIR 时立刻中止（不会把 tag 打进别人的目录）"
else
    bad "T34 MC_REPO_DIR 仍能把整条发版牵走（exit=${rc}）"
fi

# T35 abs 备案**没写 matchsha**：必须判红。没有这条，"把指纹做成可选（写了才认）"
# 这个变异就活不下来也活不下来——说清楚：它在 T21 上是**等价变异**（T21 的行本来就写了
# 指纹），只有"表里不写指纹"这条路径能把它和正确实现分开（复审 P0 的原始形状就是这一条）。
R=$(mk_repo t35); printf '%s\n' "$(frag_pem)" > "${R}/Sources/a.swift"
(cd "${R}" && git add -A && git commit -qm plant >/dev/null)
C35=$(cd "${R}" && git rev-parse HEAD)
git -C "${R}" rm -q Sources/a.swift && ( cd "${R}" && git commit -qm vanish >/dev/null )
write_allowlist "${R}" "hist	Sources/a.swift	private_key	只给证据不给指纹 evidence=${C35:0:8}"
expect die "T35 abs 备案缺 matchsha 不生效（按文件备案 = 该文件对该规则永久失明）" "${R}" "" "未备案 +hist"

echo "--- 结果: ${PASS} 通过 / ${FAIL} 失败"
[ "${FAIL}" -eq 0 ] || exit 1
