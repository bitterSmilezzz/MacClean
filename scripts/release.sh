#!/bin/bash
# MacClean 一键发版：脱敏扫描 → 质量门禁 → 提交 → tag → 推送 → GitHub Release
#
# 用法: scripts/release.sh <X.Y.Z> "<标题>" [--dry-run]
#   --dry-run   只跑扫描与门禁，不写 git、不推送、不发 Release
#   --skip-scan 跳过扫描（**只允许人工排查时用**；据此产出的包不得发布）
#
# 为什么要这个脚本：发版有 12 步，最容易漏的两条是「扫描必须在提交之前」和
# 「push 完 tag 还要 gh release create」。真漏过——GitHub 上停在 v1.71.0，
# 而本地 tag 已经打到 v1.72.12。
#
# ⚠️ bash 陷阱（docs/RELEASE-CHECKLIST.md §0）：`$VAR` 后紧跟中文/全角字符时，
#    C locale 下 bash 会把该字符首字节并进变量名，set -u 直接报 unbound variable。
#    本文件所有变量引用一律写成 ${VAR}。
set -euo pipefail
# 默认扫本仓库；`MC_REPO_DIR` 让夹具自测能把同一套扫描逻辑指向一个临时仓库——
# 门禁自己不可测，就等于没有门禁。
# 工具自身的目录与"被扫的仓库"是两回事：下面 cd 之后，相对路径一律指向被扫仓库
# （备案表、.build 产物都在那儿），而夹具自测属于工具，必须按脚本自己的位置找。
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${MC_REPO_DIR:-$(cd "${TOOL_DIR}/.." && pwd)}"

# 所有中间文件落在**一次性目录**里：以前写死 /tmp/mc-release-* 与 "${GREP_ERR}"，
# 两个会话同时发版就会互相覆盖——A 的失败集拿去和 B 的基线比，门禁于是报出一个假的"一致"。
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macclean-release.XXXXXX")"
GREP_ERR="${RUN_DIR}/grep.err"
HIST_ERR="${RUN_DIR}/hist.err"
HIST_INDEX="${RUN_DIR}/hist.idx"
trap 'rm -rf "${RUN_DIR}"' EXIT

BRANCH="main"
ALLOWLIST="scripts/secrets-allowlist.txt"
OLD_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# 扫描范围 = **全部跟踪文件**，不做点名。以前点名列出五个路径，于是不在名单里的新文件
# （根目录新增一个 .json、一个 fixtures/ 目录）永远不会被扫到；而 `.build`/`dist`
# 本来就被 gitignore 排除、`git grep` 只搜跟踪文件，点名这一层只是风险没有收益。
# 这里**故意不留** `TREE_PATHS=()` 之类的"以后好加排除"的变量：macOS 自带 bash 3.2 在
# `set -u` 下展开空数组会直接报 unbound variable，而那次事故正是这么来的（见 grep_tree）。
STEP=0
STEPS=9
SCAN_HITS=0
ABSOLUTE_HITS=0
# 本轮就踩过：挪动 --scan-only 入口时把主流程的 `run_scan` 调用弄丢了，
# 于是"扫描通过"照打、提交照走，而扫描一次都没跑。检查器有没有被执行
# 不能靠读代码相信，必须留一个只有它自己会置位的闸。
SCAN_RAN=0

die() { echo "❌ $*" >&2; exit 1; }
step() { STEP=$((STEP + 1)); echo ""; echo "==> [${STEP}/${STEPS}] $*"; }
warn() { echo "    ⚠ $*" >&2; }

# 输出脱敏：只回显前 8 个非空白字符，凭据值任何情况下都不完整出现。
mask() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-8 | tr -d '\n\t' | sed 's/$/*** /'; }

# 绝不能让坏掉的扫描器输出"扫描通过"。本仓库踩过：`-----BEGIN` 开头的模式被当成
# 命令行选项，grep 报错退出、什么都没扫，脚本却继续往下走并报 ✅。
# 所以：模式一律用 -e 传，退出码 >1 即判发版失败。
# macOS 没有 coreutils 的 timeout/gtimeout。这里用 perl 自己包一层，
# 并保证超时是**失败**而不是静默通过——发版门禁不能因为"跑太久"就放行。
with_timeout() {
    local secs="$1"; shift
    perl -e '
        my $t = shift @ARGV;
        my $pid = fork();
        if (!defined $pid) { exit 1; }
        if ($pid == 0) { exec @ARGV or exit 127; }
        local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 5; kill "KILL", $pid; };
        alarm $t;
        waitpid($pid, 0);
        my $rc = $?;
        alarm 0;
        if ($rc & 127) { exit 124; }
        exit($rc >> 8);
    ' "${secs}" "$@"
}

# SCAN_INDEX=1 时扫**索引**：`git add` 之后再扫一遍，本轮新增的未跟踪文件才进得了扫描。
# 旧顺序是"先扫跟踪文件 → 再 git add"，新文件恰好落在扫描之后、推送之前。
# ⚠ 这里**不许用数组拼参数**：macOS 自带 bash 3.2 在 `set -u` 下展开空数组
#   `"${cached[@]}"` 会报 unbound variable，于是 git grep 一次都没执行、
#   扫描器安静地扫了 0 个文件却照样打印"✅ 扫描通过"（本轮真实踩过，
#   16 条夹具自测全绿也没发现——因为种在已提交文件里的命中被历史侧兜住了）。
grep_tree() {
    local out="" rc=0
    if [ "${SCAN_INDEX:-0}" = "1" ]; then
        out="$(git grep --cached -nIE -e "$1" 2>"${GREP_ERR}")" || rc=$?
    else
        out="$(git grep -nIE -e "$1" 2>"${GREP_ERR}")" || rc=$?
    fi
    if [ "${rc}" -gt 1 ]; then
        cat "${GREP_ERR}" >&2
        die "扫描规则执行失败（git grep exit ${rc}）: $1"
    fi
    [ -n "${out}" ] && printf '%s\n' "${out}"
    return 0
}

# 历史扫描的记录格式：commit US 出处 US 内容。用 0x1f 而不是 TAB 分列——
# diff 行本身就常含 TAB，按 TAB 拆会拆出错位的内容。
US=$'\037'

# 给整段历史建一张**带出处**的索引。以前只把 `git log -p` 吐出的行当成一坨文本扫，
# 于是：①命中无法归到文件与 commit，备案表只能写通配 `hist * 规则`（等于对全历史豁免）；
# ②commit 正文与 tag 说明**根本没进扫描**——凭据写进 TITLE 参数就会随 tag 公开出去。
build_hist_index() {
    {
        git log --all -p -U0 --format='MC_COMMIT=%H%n%B%nMC_ENDMSG='
        git for-each-ref --format='MC_TAG=%(refname:short)%09%(contents:subject)' refs/tags
    } 2>"${HIST_ERR}" | awk -v us="${US}" '
        BEGIN { OFS = us }
        /^MC_COMMIT=[0-9a-f]+$/ { c = substr($0, 11); src = "<COMMIT-MSG>"; next }
        /^MC_ENDMSG=$/          { src = "<DIFF>"; next }
        /^MC_TAG=/ {
            t = substr($0, 8); tab = index(t, "\t")
            name = (tab ? substr(t, 1, tab - 1) : t)
            body = (tab ? substr(t, tab + 1) : "")
            gsub(us, " ", body); print name, "<TAG-MSG>", body; next
        }
        src != "<COMMIT-MSG>" && /^diff --git / {
            # 删除的 diff 写成 `a/<path> b/dev/null`：只看最后一个字段会把被删文件的内容
            # 归属到 "dev/null"，于是那条命中**永远没法备案**（自测 T5 实测到）。
            q = $NF; sub(/^b\//, "", q)
            p = $2;  sub(/^a\//, "", p)
            src = (q == "dev/null" ? p : q)
            next
        }
        { line = $0; gsub(us, " ", line); print c, src, line }' > "${HIST_INDEX}"
}

# 只在**内容列**上匹配：文件名或 commit 串里凑出规则形状不算命中。
grep_hist_rule() {
    local out="" rc=0
    out="$(grep -E -e "^[^${US}]*${US}[^${US}]*${US}.*($1)" "${HIST_INDEX}" 2>"${GREP_ERR}")" || rc=$?
    if [ "${rc}" -gt 1 ]; then
        cat "${GREP_ERR}" >&2
        die "历史扫描规则执行失败（grep exit ${rc}）: $1"
    fi
    [ -n "${out}" ] && printf '%s\n' "${out}"
    return 0
}

DRY_RUN=0
SKIP_SCAN=0
SCAN_ONLY=0
SCAN_STAGED=0
# --scan-only [--staged]：只跑脱敏扫描并按结论退出（0=通过，1=有未备案命中）。
# 有了这个入口，扫描器才能被 scripts/scan-selftest.sh 用 planted 夹具反向验证。
if [ "${1:-}" = "--scan-only" ]; then
    SCAN_ONLY=1
    shift
    [ "${1:-}" = "--staged" ] && SCAN_STAGED=1
else
VERSION="${1:-}"
TITLE="${2:-}"
if [ -z "${VERSION}" ] || [ -z "${TITLE}" ]; then
    die "用法: scripts/release.sh <X.Y.Z> \"<标题>\" [--dry-run] | scripts/release.sh --scan-only [--staged]"
fi
shift 2
for arg in "$@"; do
    case "${arg}" in
        --dry-run)   DRY_RUN=1 ;;
        --skip-scan) SKIP_SCAN=1 ;;
        *) die "未知参数: ${arg}" ;;
    esac
done
fi
VERSION="${VERSION:-}"
TITLE="${TITLE:-}"
# `MC_REPO_DIR` 是"把扫描逻辑指到另一个仓库"的夹具入口（scan-selftest.sh 用它种一次性仓库）。
# 但它在本脚本里是**整条发版**的 cwd：构建、自检、提交、tag、推送全跟着走，而 `TOOL_DIR`
# 仍指着真仓库——一个残留的 export 就会把 v1.73.x 打进别人的目录（复审 P2）。
# 所以：只有 `--scan-only`，或带自测标记的回调，才承认它。
if [ -n "${MC_REPO_DIR:-}" ] && [ "${SCAN_ONLY}" != "1" ] && [ "${MC_SCAN_SELFTEST:-0}" != "1" ]; then
    die "MC_REPO_DIR=${MC_REPO_DIR} 只允许配合 --scan-only 或夹具自测使用：真发版不许把构建/提交/tag/推送指向别的目录"
fi
# 同一族、同一个位置：`MC_SCAN_SELFTEST` 是"我在自测里，别再回调自测"的防递归标记，
# 只有配合 `MC_REPO_DIR`（夹具自测必然设置它）才承认。单独一个环境变量就能把整套
# 夹具自测关掉是 env 级 fail-open（复审 P1）；而把它放在 step 1 里，前面那道"现场核查"
# 会先因为"不是 git 仓库"中止，复制目录里跑的夹具于是永远测不到这一条。
if [ "${MC_SCAN_SELFTEST:-0}" = "1" ] && [ -z "${MC_REPO_DIR:-}" ]; then
    die "MC_SCAN_SELFTEST=1 但没有 MC_REPO_DIR：这个标记只允许由 scripts/scan-selftest.sh 设置，真发版不许靠它跳过夹具自测"
fi
TAG=""
if [ "${SCAN_ONLY}" != "1" ]; then
    printf '%s' "${VERSION}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || die "版本号格式应为 X.Y.Z，收到: ${VERSION}"
    TAG="v${VERSION}"
fi

# ---------------------------------------------------------------- 脱敏扫描
# 规则分两档：absolute 一类是"绝对零命中"，命中即真凭据，只能删、不许备案；
# 其余可能是自检夹具（本项目自带凭据检测器，仓库里本来就有假凭据字符串），
# 允许人工复核后写进 ${ALLOWLIST}。
# 格式：规则名<TAB>是否绝对<TAB>ERE
rules() {
    printf 'private_key\tabs\t-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----\n'
    printf 'github_token\tabs\tgh[pousrIw]_[A-Za-z0-9]{20,}\n'
    # 细粒度 PAT 是另一个前缀，旧规则整类抓不到
    printf 'github_fine_grained_pat\tabs\tgithub_pat_[A-Za-z0-9_]{22,}\n'
    printf 'aws_access_key\tabs\tAKIA[0-9A-Z]{16}\n'
    printf 'slack_token\tabs\txox[baprs]-[A-Za-z0-9\\-]{10,}\n'
    printf 'google_api_key\tabs\tAIza[0-9A-Za-z_\\-]{30,}\n'
    printf 'openai_style_key\tno\tsk-[A-Za-z0-9_\\-]{24,}\n'
    printf 'jwt\tno\teyJ[A-Za-z0-9_\\-]{12,}\\.ey[A-Za-z0-9_\\-]{12,}\n'
    printf 'secret_assign\tno\t(api[_\\-]?key|secret|token|passwd|password)[a_\\-]*[[:space:]]*[:=][[:space:]]*["'\''][A-Za-z0-9/+_\\-]{20,}["'\'']\n'
}

# 一眼假：连续数字、EXAMPLE、占位词。命中仍打印，只是不阻断。
fixture_shape() {
    printf '%s' "$1" | grep -qiE 'EXAMPLE|PLACEHOLDER|YOUR_|XXXX|dummy|fake|fixture|test[_-]?(key|token|secret)|1234567890|0123456789|\{[a-z_]+\}'
}

# **逐个**把匹配上规则的片段交给后面的判据。两代写法都错过：
# ① 旧写法判的是整行内容，于是真凭据只要与 `test`/`fake`/一串数字同行就会被放行；
# ② 中间一版只取**第一个**片段（`grep -oE | head -1`），于是同一行里
#   "一个自证假的占位串 + 一个真凭据"只要占位串排在前面，整行就被放行
#   （复审实测 rc=0，标题档同样中招）。
# 现在用 `grep -o` 输出**全部**命中、逐条过审：任何一处不自证为假就记账。
# 顺带这一版不再有 `head -1`，也就没有"head 提前关管道 → grep 收到 SIGPIPE →
# pipefail 让整条管道非零 → 裸赋值在 set -e 下当场终止发版"那一族缓冲时机相关的故障。
matched_fragments() { # <text> <ERE>
    printf '%s' "$1" | grep -oE -e "$2" 2>/dev/null || true
}

# 片段的**内容指纹**（sha1 前 12 位）。备案表用它把"豁免"钉到具体那一串上：
# 只按 `(scope, file, rule)` 备案的话，一个文件只要有一条合法备案行，这个文件对该规则
# 就**永久整体失明**——后来在该文件里贴一把真私钥照样放行（复审 P0，实测 rc=0）。
# 表里存指纹而不是原文：这张表自己也在扫描范围内，抄原文等于让备案表成为新的未备案命中。
frag_id() { printf '%s' "$1" | shasum | cut -c1-12; }

# abs 一档永不走"一眼假"：豁免面比检测面更容易出事，这里宁可多拦一次。
fixture_exempt() { # abs frag
    [ "$1" = "abs" ] && return 1
    [ -n "$2" ] || return 1
    fixture_shape "$2"
}

# 备案表：scope<TAB>file-or-*<TAB>rule<TAB>reason
# abs 一档**不接受通配 file**，且 reason 里必须同时带：
#   `evidence=<commit 前缀>`  —— 哪个提交证明这行是假数据（由 abs_evidence_ok 校验它真实
#                                存在且**确实动过这个文件**）；
#   `matchsha=<12 位指纹>`    —— 豁免只适用于**这一串内容**（frag_id 算出来的 sha1 前 12 位）。
# 为什么要两道：只按 (scope,file,rule) 备案 = 该文件对该规则永久失明，后来在同一文件里
# 贴一把真私钥照样绿灯通过（复审 P0，实测到）；而旧表里那行 `hist<TAB>*<TAB>private_key`
# 更是把私钥规则对**全部 git 历史**关掉——"abs 不许备案"当时只写在注释里，机器不认。
# 非 abs 一档：写了 matchsha= 就按内容钉（推荐），没写则退回按文件备案（保持既有行可用）。
# 命中时把备案行的 reason 原样打到 stdout（调用方还要拿它校验 evidence）。
allowlisted() { # scope file commit rule abs fraghash
    local h="${6:-}"
    [ -f "${ALLOWLIST}" ] || return 1
    awk -F'\t' -v s="$1" -v f="$2" -v r="$4" -v a="$5" -v h="${h}" '
        $1 != s || $3 != r { next }
        {
            # matchsha 允许写在**这一行的任何一栏**（用 TAB 或空格分隔都行），所以从整行取；
            # 上一版只从 $4（reason 栏）取，把 matchsha 单独放一栏时**所有 abs 备案同时失效**。
            sha = ""
            if (index($0, "matchsha=") > 0) { sha = $0; sub(/.*matchsha=/, "", sha); sub(/[[:space:]].*/, "", sha) }
            if (a == "abs") {
                if ($2 == "*" || $2 != f) next
                if (index($0, "evidence=") == 0) next
                ev = $0; sub(/.*evidence=/, "", ev); sub(/[[:space:]].*/, "", ev)
                if (ev == "") next
                # 证据**是否有效**（提交真实存在、且真的动过这个文件）由 abs_evidence_ok 一处
                # 决定；这里再比一次"命中提交 == evidence"是重复的严格：同一份内容会在"加入"
                # 与"删除"两个提交里各命中一次，按提交精确匹配永远差一个。
                if (sha == "" || sha != h) next
            } else {
                if ($2 != "*" && $2 != f) next
                if (sha != "" && sha != h) next
            }
            print($0); found = 1; exit
        }
        END { exit !found }' "${ALLOWLIST}"
}

# abs 一档的 `evidence=<commit>` 不能是随手写的字符串，必须同时满足两条：
#   ① 它是本仓库里一个**真实存在**的提交；
#   ② 那个提交**真的动过这个文件**（`git log --all -- <file>` 里能找到它）。
# 为什么不是"必须等于命中所在的那个提交"：同一份内容会在"加入"与"删除"两个提交里
# 各产生一次命中，按提交精确匹配会永远差一个，逼人为同一行夹具备案两次（实测踩到）。
# 而"动过这个文件"既拦得住随手挑个无关提交充数，也拦得住 `evidence=deadbeef`。
abs_evidence_ok() { # reason file
    local reason="$1" file="$2" ev
    ev="${reason##*evidence=}"
    ev="${ev%%[[:space:]]*}"
    # 不再单独校验"ev 是不是十六进制"：`git cat-file -e "${ev}^{commit}"` 只接受
    # 合法的十六进制前缀，非十六进制的 `a.cafe`、`.` 在那一步就失败了（自测 T14 实测），
    # 加一道永远轮不到的检查只会多一处没人守的分支。
    git cat-file -e "${ev}^{commit}" 2>/dev/null || return 1
    git log --all --format='%H' -- "${file}" 2>/dev/null | grep -q -- "^${ev}"
}

report_hit() { # scope file rule where value abs
    echo "    ✖ ${3} 未备案  ${1} ${4}" >&2
    # 值一律截断显示；空值（身份档那种"整条路径都是敏感信息"的命中）连前缀都不打。
    if [ -n "${5:-}" ]; then
        echo "      值: $(mask "${5}")  备案需 matchsha=$(frag_id "${5}")" >&2
    fi
    SCAN_HITS=$((SCAN_HITS + 1))
    if [ "${6:-no}" = "abs" ]; then ABSOLUTE_HITS=$((ABSOLUTE_HITS + 1)); fi
}

# 三处扫描（工作区/索引、历史、发版标题）共用这一条判定链，顺序也是唯一的豁免顺序：
# ①abs 一律不走"一眼假" ②非 abs 且**片段自己**长得像占位串 → 只打印 ③备案（按内容钉）
# ④否则记账。以前三个调用点各自复制这四步，改一处就会漏另一处（标题档就是这么漏掉了
#   "只取第一个片段"这个 bug 的修复）。
audit_line() { # scope file commit rule abs where text pattern
    local scope="$1" file="$2" commit="$3" rule="$4" abs="$5" where="$6" text="$7" pat="$8"
    local frag reason
    while IFS= read -r frag; do
        [ -n "${frag}" ] || continue
        if fixture_exempt "${abs}" "${frag}"; then
            echo "    ~ ${rule} 夹具形状 ${where} $(mask "${frag}")"
        elif reason="$(allowlisted "${scope}" "${file}" "${commit}" "${rule}" "${abs}" "$(frag_id "${frag}")")" \
             && { [ "${abs}" != "abs" ] || abs_evidence_ok "${reason}" "${file}"; }; then
            echo "    ~ ${rule} 已备案 ${scope}:${file}"
        else
            report_hit "${scope}" "${file}" "${rule}" "${where}" "${frag}" "${abs}"
        fi
    done < <(matched_fragments "${text}" "${pat}")
    return 0
}

# 活性证据：扫描器必须先真的搜到点**任何**东西，才有资格说"什么都没找到"。
# 没有这一条，上面那个空数组事故会让整轮扫描变成"0 个文件被看过 → 干净"。
# 探针用的是 `[[:print:]]`（任何非空行都命中）而不是某个具体符号：
# ①它对被扫仓库没有内容要求，夹具用的临时仓库（只有 README 一行字）也能跑；
# ②它走的是**与凭据规则完全相同的那条命令**（同一个 grep_tree、同一套 argv 构造、
#   同一档退出码判定，连 `--cached` 分支都一起跟着走），所以数组事故、pathspec 写错、
#   grep 选项被当成模式这类"命令根本没执行成功"的故障，都会在这里当场暴露，
#   而不是伪装成 0 命中。
# ⚠ 探针只证明**命令跑过**，不证明每条 ERE 都能匹配：模式写错成永不命中就是 rc=1=干净。
#    那一层只能靠夹具（rules() 里九条规则现在每条都有用例，动一行就判红）。
assert_scanner_alive() {
    local probe hits
    probe="$(grep_tree '[[:print:]]' || true)"
    if [ -z "${probe}" ]; then
        [ -s "${GREP_ERR}" ] && cat "${GREP_ERR}" >&2
        # 嵌在双引号里的双引号会被 bash 吞掉（复审 P3），一律改用「」。
        die "脱敏扫描器没有搜到任何内容（连「任何非空行」这种必然命中的模式都抓不到）——
它可能一次都没执行成功，不能把「0 命中」当成「干净」（scope=${1}）"
    fi
    hits="$(printf '%s\n' "${probe}" | sed 's/:[0-9]*:.*$//' | sort -u | wc -l | tr -d ' ')"
    echo "    （扫描器活性：${hits} 个文件含非空行，$( [ "${SCAN_INDEX:-0}" = "1" ] && printf '索引' || printf '工作区' )侧确实搜过）"
}

scan_tree() {
    local rule abs pat line f rest ln v
    assert_scanner_alive tree
    while IFS=$'\t' read -r rule abs pat; do
        [ -n "${rule}" ] || continue
        # -I 跳过二进制；不写 pathspec —— 扫描范围就是**全部跟踪文件**，
        # 而 .build/dist 本来就被 gitignore 排除、`git grep` 只搜跟踪文件。
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            f="${line%%:*}"
            rest="${line#*:}"
            ln="${rest%%:*}"
            v="${rest#*:}"
            audit_line tree "${f}" "" "${rule}" "${abs}" "${f}:${ln}" "${v}" "${pat}"
        done < <(grep_tree "${pat}")
    done < <(rules)
}

scan_history() {
    local rule abs pat c src content frag reason commits
    # 阳性对照：历史里**有提交**却没建出索引 = 建索引那步失败了，不是"没历史"。
    # 旧写法把空文件一律读成"无历史可扫"然后 return 0，于是 detached HEAD、
    # git 报错、awk 崩掉都长得像"这个仓库很干净"（`2>/dev/null` 把线索也吞了）。
    commits="$(git rev-list --count --all 2>/dev/null || echo '')"
    build_hist_index
    if [ -z "${commits}" ] || [ "${commits}" = "0" ]; then
        if [ -s "${HIST_INDEX}" ]; then
            die "历史扫描：rev-list 说没有提交，索引却有内容——判据自相矛盾，不能猜哪边对"
        fi
        echo "    （仓库无提交，历史侧无内容可扫）"
        return
    fi
    if [ ! -s "${HIST_INDEX}" ]; then
        [ -s "${HIST_ERR}" ] && { cat "${HIST_ERR}" >&2; echo "      —— git 侧报错见上" >&2; }
        die "历史扫描：仓库有 ${commits} 个提交，却一行都没索引出来。这是扫描器坏了，不是历史干净"
    fi
    echo "    （历史索引 $(wc -l < "${HIST_INDEX}" | tr -d ' ') 行 / ${commits} 个提交，含 commit 正文与 tag 说明）"
    while IFS=$'\t' read -r rule abs pat; do
        [ -n "${rule}" ] || continue
        while IFS="${US}" read -r c src content; do
            [ -n "${c}" ] || continue
            audit_line hist "${src}" "${c}" "${rule}" "${abs}" "${src}" "${content}" "${pat}"
        done < <(grep_hist_rule "${pat}")
    done < <(rules)
    echo "    （历史扫描完成）"
}

# 本机身份：仓库里 LICENSE 的账号名是已确认可公开的，但 /Users/<account> 形式的
# 绝对路径不算——那会把本机用户名、目录结构一起带到公开仓库。
# **树侧与历史侧都要扫**：以前只扫工作区，于是"把带真实主目录路径的文件提交进去再删掉"
# 就查无此人（复审实测 rc=0），而公开仓库的历史是永久可查的。
# 这一档**不走备案表**：它不是"某行必须长得像凭据的夹具"，而是本机身份，唯一出路是改写内容。
scan_identity() {
    local user pat line c src content
    user="$(id -un)"
    pat="/Users/${user}"
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        report_hit tree "${line%%:*}" local_home "${line%%:*}" "" no
    done <<< "$(grep_tree "${pat}")"
    if [ -s "${HIST_INDEX}" ]; then
        while IFS="${US}" read -r c src content; do
            [ -n "${c}" ] || continue
            printf '%s' "${content}" | grep -qE -e "${pat}" 2>/dev/null || continue
            report_hit hist "${src}" local_home "${src}" "" no
        done < <(grep_hist_rule "${pat}")
    fi
    echo "    （身份标识扫描完成：账号名本身不算命中，/Users/<账号名> 算；树侧与历史侧都查过）"
}

# 第三档扫描对象：**本轮即将写进 commit 正文、tag 说明和 Release 标题的那个字符串**。
# 树侧与历史侧都看不到它——历史侧只覆盖已入库的内容，而发版流程里最后一次扫描发生在
# `git commit`/`git tag` 之前，凭据写进 TITLE 就会随这一轮的 annotated tag 直接推出去，
# 本轮扫不到、下一轮才红（独立复审 P1）。
# 备案表在这一档**不适用**：那套证据的立论是"仓库里有一行必须长得像真凭据的夹具，
# 由某个提交证明它是假数据"；发版标题不是文件，没有任何证据能为它开脱，只能改标题。
# ⚠ 与 audit_line 的区别就是这一条：这里**不查备案表**，其余判据顺序一致
#   （abs 不走"一眼假"、逐个片段过审）。所以它不能直接复用 audit_line。
# `MC_SCAN_TEXT` 给夹具自测一个入口，让它能走同一条代码路径，而不是另写一份判据。
scan_text() { # <label> <text>
    local label="$1" text="$2" rule abs pat frag
    [ -n "${text}" ] || return 0
    while IFS=$'\t' read -r rule abs pat; do
        [ -n "${rule}" ] || continue
        while IFS= read -r frag; do
            [ -n "${frag}" ] || continue
            if fixture_exempt "${abs}" "${frag}"; then
                echo "    ~ ${rule} 夹具形状 text:${label} $(mask "${frag}")"
            else
                report_hit text "${label}" "${rule}" "text:${label}" "${frag}" "${abs}"
            fi
        done < <(matched_fragments "${text}" "${pat}")
    done < <(rules)
}

run_scan() {
SCAN_RAN=1
if [ "${SKIP_SCAN}" = 1 ]; then
    # 旧行为是 warn 一句然后照常 commit / push / release——"据此产出的包不得发布"
    # 全靠人记得这句话，而脚本自己就是那条流水线的执行者。跳过即中止；
    # 真要人工排查就用 --dry-run（它本来就不写 git）。
    [ "${DRY_RUN}" = 1 ] || die "--skip-scan 不允许用于真发版：脱敏扫描必须在提交之前。人工排查请用 --dry-run"
    warn "--skip-scan（dry-run）：跳过脱敏扫描"
else
    scan_tree
    # 顺序有依赖：scan_identity 现在要读历史索引，所以必须排在 scan_history 之后。
    scan_history
    scan_identity
    scan_text title "${TITLE}"
    scan_text selftest "${MC_SCAN_TEXT:-}"
    if [ "${SCAN_HITS}" -gt 0 ]; then
        echo "" >&2
        echo "  未备案命中 ${SCAN_HITS} 处。三条路，按这个顺序判:" >&2
        echo "    ① 是真实凭据 → 删掉它，改走环境变量或系统钥匙串（这是唯一正解）；" >&2
        echo "    ② 确认是**假数据夹具** → 往 ${ALLOWLIST} 加一行「scope<TAB>file<TAB>rule<TAB>reason」；" >&2
        echo "       abs 一档的 reason 必须同时带 `evidence=<提交>` 与命中处打印的 `matchsha=<指纹>`——" >&2
        echo "       按内容钉，否则这个文件对该规则就永久失明（复审 P0）；" >&2
        echo "    ③ 出处是 <COMMIT-MSG>/<TAG-MSG>（提交正文、tag 说明）→ **不可备案**：它不属于任何文件，" >&2
        echo "       而通配备案等于把该规则对全部历史关掉。尚未推送只能重写本地提交（--amend / 重建分支），" >&2
        echo "       已推送就是**凭据外泄事件**、按事故处理，而不是「往表里加一行」。" >&2
        [ "${ABSOLUTE_HITS}" -gt 0 ] && \
            echo "  其中 ${ABSOLUTE_HITS} 条属绝对零命中类（私钥/GitHub/AWS/Slack/Google），不许备案，只能删。" >&2
        die "脱敏扫描未通过"
    fi
    echo "    ✅ 扫描通过"
fi
}

if [ "${SCAN_ONLY}" = 1 ]; then
    # 自测入口：不查分支、不构建、不写 git，只回答"这份内容能不能进公开仓库"
    if [ "${SCAN_STAGED}" = 1 ]; then
        SCAN_INDEX=1
        echo "==> staged 复扫"
        scan_tree
        # 标题档在真发版里由 step 1 覆盖；这里补上是为了让**人工**跑
        # `--scan-only --staged` 时得到的结论与真发版同口径（复审 Q3c：以前这一档
        # 走过的工作区/staged 分支都不含标题，接错一处就 38 条夹具一条不红）。
        scan_text title "${TITLE}"
        scan_text selftest "${MC_SCAN_TEXT:-}"
        # 历史索引这一步没建（--staged 只看索引内容），scan_identity 用 `[ -s ]` 自行跳过
        scan_identity
        if [ "${SCAN_HITS}" -gt 0 ]; then
            echo "  staged 命中 ${SCAN_HITS} 处（绝对零命中 ${ABSOLUTE_HITS} 处）" >&2
            die "staged 里有未备案命中"
        fi
        echo "    ✅ staged 复扫通过"
        exit 0
    fi
    echo "==> 脱敏扫描（${PWD}）"
    run_scan
    exit 0
fi

echo "================================================"
echo " MacClean ${TAG} —— ${TITLE}"
[ "${DRY_RUN}" = 1 ] && echo " （--dry-run：不提交、不推送、不发 Release）"
echo "================================================"

# ---------------------------------------------------------------- 0 现场核查
step "现场核查"
git rev-parse --git-dir >/dev/null 2>&1 || die "不是 git 仓库"
[ "$(git rev-parse --abbrev-ref HEAD)" = "${BRANCH}" ] || die "当前分支不是 ${BRANCH}"
git fetch --quiet origin 2>/dev/null || warn "fetch 失败，按离线状态继续"
if [ "$(git rev-list --count "HEAD..origin/${BRANCH}" 2>/dev/null || echo 0)" -gt 0 ]; then
    die "origin/${BRANCH} 领先本地——可能有别人的工作，先人工处理，不要 rebase/reset 硬合"
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    die "${TAG} 已存在。已发布的 tag 不得重打、移动或删除"
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "    工作区改动（将随本次发版入库，先自查有无不该入库的东西）:"
    git status --short | head -30
fi

# ---------------------------------------------------------------- 1 扫描
step "脱敏扫描（提交之前——进了历史就删不回来了）"
# 扫描器自己先过一遍夹具：38 条"该拦 / 该放 / 该中止"的形状，逐条带归因，断言结论与预期一致。
# 与仓库内容无关，所以 --skip-scan 的 dry-run 也照跑——不能自证的检查器，
# 它的绿灯本身就是说谎。
# ⚠ 自测里有一条会反过来驱动本脚本（验证 --skip-scan 真的会中止），
#   所以必须带标记，否则两者互相调用、无限递归——本轮真递归出 363 个临时仓库。
if [ "${MC_SCAN_SELFTEST:-0}" = "1" ]; then
    # 成对判据已经在参数解析处守过了（那里 die），这里只承认它、并消费掉，
    # 免得后面任何一步再被同一个标记悄悄跳过。
    warn "跳过夹具自测（回调标记：MC_REPO_DIR=${MC_REPO_DIR}）"
    unset MC_SCAN_SELFTEST
elif ! "${TOOL_DIR}/scan-selftest.sh"; then
    die "脱敏扫描器的夹具自测没过：门禁已失效，不能靠它放行任何一次发版"
fi
run_scan

# ---------------------------------------------------------------- 2 构建
step "开发构建（含自检）"
[ -d "${OLD_SDK}" ] && [ ! -d /Applications/Xcode.app ] && export SDKROOT="${SDKROOT:-${OLD_SDK}}"
if ! swift build 2>"${RUN_DIR}/build.err" >"${RUN_DIR}/build.out"; then
    tail -30 "${RUN_DIR}/build.err" >&2
    die "swift build 失败"
fi
grep -E "warning:.*\.swift" "${RUN_DIR}/build.err" >"${RUN_DIR}/warn.txt" 2>/dev/null || true
if [ -s "${RUN_DIR}/warn.txt" ]; then
    warn "有 $(wc -l < "${RUN_DIR}/warn.txt") 条 Swift 源码告警（门槛要求 0 条）:"
    head -5 "${RUN_DIR}/warn.txt" >&2
fi
tail -2 "${RUN_DIR}/build.out"

# ---------------------------------------------------------------- 3 自检
step "全量自检"
set +e
.build/debug/MacClean --selftest >"${RUN_DIR}/selftest.log" 2>&1
ST_RC=$?
set -e
tail -4 "${RUN_DIR}/selftest.log"
# 自检二进制**根本没跑起来**时不要把它当成"产品红灯"去比名集——那只会报一句误导人的
# "自检红灯不等于 §0.2 环境基线"。实测成因：`SDKROOT` 钉在 CLT 的 26.5 SDK，而编译器来自
# `xcode-select` 选中的 Xcode，两边不同源；产出的 .build/debug/MacClean 里
# `@rpath/libXCTestSwiftSupport.dylib` 被指到 Toolchains/.../swift-6.2/macosx（那儿没有这个
# dylib，它在 MacOSX.platform/Developer/usr/lib），dyld 直接以 134 终止。
# 平时看不出来，因为增量构建复用了旧产物；`swift package clean` 之后必现。
if grep -q "libXCTestSwiftSupport.dylib" "${RUN_DIR}/selftest.log" 2>/dev/null \
   || [ "${ST_RC}" = 134 ] || [ "${ST_RC}" = 133 ]; then
    die "自检二进制没能加载（缺 XCTest 运行库）。SDKROOT 与编译器必须同源：
      export DEVELOPER_DIR=/Library/Developer/CommandLineTools
      export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    然后重新 swift build（当前 xcode-select -p = $(xcode-select -p 2>/dev/null)）"
fi
# 门槛不是"退出码 0"，而是"失败集与环境基线逐条相同"。
# 本机 macOS 27 上 ViewInspector 0.10.3 猜的 SwiftUI 内存布局变了：`Button`/`Toggle` 枚举整体
# 失效，另有两处进程级终止 → RELEASE-CHECKLIST §0.2 记录 34 条失败 + 7 个套件不可执行，
# 且把已发的 HEAD 单独克隆重编重跑，失败集一模一样（与产品改动无关）。
# 因此**只放这一种红过去，而且必须一字不差**：多一条 = 新增红灯（照旧拦），
# 少一条 = 基线过期，环境或代码变了（同样拦，要求人工重新确认再刷新基线）。
# 这不是 --skip-scan 那种绕过：比对的是具体用例名，不是"别看输出"。
ENV_BASELINE="docs/KNOWN-ENV-SELFTEST-FAILURES-MACOS27.md"
if [ "${ST_RC}" != 0 ]; then
    [ -f "${ENV_BASELINE}" ] || die "自检未通过（exit ${ST_RC}），又没有 ${ENV_BASELINE} 可比——修完再发，不带红灯发版"
    awk '/^## 失败用例名/{sec="N";next} /^## 未执行套件名/{sec="S";next}
         /^```/{infence=!infence;next} infence&&sec{print sec"\t"$0}' "${ENV_BASELINE}" | sort -u \
        > "${RUN_DIR}/env-baseline.txt"
    { grep '^  ❌ ' "${RUN_DIR}/selftest.log" | sed 's/^  ❌ //; s/（.*//; s/[[:space:]]*$//' \
        | sed 's/^/N\t/' | sort -u
      grep -oE '⚠️ [A-Za-z0-9]+：子进程异常终止' "${RUN_DIR}/selftest.log" \
        | sed 's/⚠️ //; s/：子进程异常终止//; s/^/S\t/' | sort -u; } > "${RUN_DIR}/env-actual.txt"
    if [ ! -s "${RUN_DIR}/env-baseline.txt" ]; then
        die "${ENV_BASELINE} 解析出来是空的（N/S 计数 $(wc -l < "${RUN_DIR}/env-baseline.txt")）——比对口径坏了，不发了"
    fi
    if ! diff -u "${RUN_DIR}/env-baseline.txt" "${RUN_DIR}/env-actual.txt" > "${RUN_DIR}/env-diff.txt"; then
        echo "    与基线不一致（N=失败用例名，S=未执行套件名）：" >&2
        head -30 "${RUN_DIR}/env-diff.txt" >&2
        die "自检红灯不等于 §0.2 环境基线：要么多了新失败，要么基线该人工复核刷新——不发了"
    fi
    warn "失败集与 ${ENV_BASELINE} 逐条相同（$(wc -l < "${RUN_DIR}/env-baseline.txt" | tr -d ' ') 条），无新增红灯"
fi

# ---------------------------------------------------------------- 4 冒烟
step "无头扫描冒烟"
set +e
( with_timeout 600 .build/debug/MacClean --scan >"${RUN_DIR}/smoke-scan.log" 2>&1 )
SCAN_RC=$?
set -e
[ "${SCAN_RC}" = 0 ] || { tail -15 "${RUN_DIR}/smoke-scan.log" >&2; die "--scan 冒烟失败（exit ${SCAN_RC}）"; }
echo "    ✅ --scan 正常（输出 $(wc -l < "${RUN_DIR}/smoke-scan.log") 行）"

# ---------------------------------------------------------------- 5 打包
step "打包 release 产物"
PREV_VERSION="$(sed -nE 's/^VERSION="([0-9.]+)"/\1/p' scripts/build-app.sh | head -1)"
sed -i '' -E "s/^VERSION=\"[0-9.]+\"/VERSION=\"${VERSION}\"/" scripts/build-app.sh
grep -q "^VERSION=\"${VERSION}\"" scripts/build-app.sh || die "VERSION 没写进 build-app.sh"
echo "    （打包日志：${RUN_DIR}/app-build.log）"
if ! ./scripts/build-app.sh >"${RUN_DIR}/app-build.log" 2>&1; then
    tail -25 "${RUN_DIR}/app-build.log" >&2
    die "打包失败"
fi
# 发布产物不含自检代码，所以在 .app 里跑 --selftest 必须**明确报错**。
# 静默"通过"才是严重问题：说明剔除没生效，或判据本身坏了。
if dist/MacClean.app/Contents/MacOS/MacClean --selftest >/dev/null 2>&1; then
    die "release 包里 --selftest 竟然通过——MACCLEAN_NO_SELFTEST 未生效，自检代码漏进了发布产物"
fi
echo "    ✅ release 包已按预期剔出自检代码"
ZIP="dist/MacClean-${TAG}.zip"
rm -f "${ZIP}"
ditto -c -k --keepParent dist/MacClean.app "${ZIP}"
echo "    ✅ ${ZIP}（$(du -h "${ZIP}" | cut -f1 | tr -d ' ')）"

if [ "${DRY_RUN}" = 1 ]; then
    # 打包这步会真改 build-app.sh 里的 VERSION；dry-run 不该留下脏工作区，
    # 否则下一轮自动化会被自己的"工作区必须干净"挡下来。
    sed -i '' -E "s/^VERSION=\"[0-9.]+\"/VERSION=\"${PREV_VERSION}\"/" scripts/build-app.sh
    echo ""
    echo "==> dry-run 结束：扫描、构建、自检、冒烟、打包全部通过。未写 git，VERSION 已还原为 ${PREV_VERSION}。"
    exit 0
fi

# ---------------------------------------------------------------- 6 提交
step "提交 + tag"
[ "${SCAN_RAN}" = 1 ] || die "扫描器一次都没跑过（SCAN_RAN=0）——不提交"
# 入库名单逐项先确认存在：`git add` 遇到不存在的路径会以非零退出，而这里开着 `set -e`，
# 于是发版死在一个**与改动无关**的路径上，报的还是 git 的英文错误（复审 P2）。
# 少一个路径通常意味着目录被挪了——那正好是"扫描范围与入库范围不再同一份名单"的时候，
# 必须停下来人工确认，不能让 git 静默跳过（旧版 `2>/dev/null || true` 就是这么把 Resources
# 从入库名单里悄悄弄丢的）。
ADD_PATHS="Sources docs scripts Resources README.md Package.swift Package.resolved"
for p in ${ADD_PATHS}; do
    [ -e "${p}" ] || die "入库名单里的 ${p} 不存在：目录被挪走了？先人工确认再发版（不许静默跳过）"
done
git add -- ${ADD_PATHS}
# 扫描范围与入库范围必须是同一份 pathspec：以前扫 `Resources` 但不 add 它，
# 新图标会进 zip 却不进仓库（产物不可复现）；反过来"先扫后 add"则让本轮新增的
# 未跟踪文件完全没被扫过——而它正是最可能带进私钥的那一批。
SCAN_INDEX=1 scan_tree
SCAN_INDEX=1 scan_identity
if [ "${SCAN_HITS}" -gt 0 ]; then
    echo "  staged 复扫命中 ${SCAN_HITS} 处（其中绝对零命中 ${ABSOLUTE_HITS} 处）" >&2
    die "已 add 的内容里检出未备案命中——不能带着它提交"
fi
echo "    ✅ staged 复扫通过"
# 只补本次真正改过的文件，不做 git add -A：dist/ 与 .build/ 虽已 gitignored，
# 但 -A 会把未跟踪的临时产物一起卷进来。
git diff --cached --quiet && die "没有已跟踪文件的改动，无事可发——不要造空提交凑版本号"
echo "    入库文件:"
git diff --cached --name-only | head -30 | sed 's/^/      /'
git commit -q -m "feat: ${TITLE} (${TAG})"
git tag -a "${TAG}" -m "${TITLE}"
echo "    ✅ $(git rev-parse --short HEAD) + ${TAG}（annotated）"

# ---------------------------------------------------------------- 7 推送
step "推送分支与 tag"
git push origin "${BRANCH}"
git push origin "${TAG}"

# ---------------------------------------------------------------- 8 Release
step "GitHub Release"
gh release create "${TAG}" "${ZIP}" \
    --title "MacClean ${TAG} —— ${TITLE}" \
    --notes "$(cat <<NOTES
${TITLE}

**版本** ${TAG}　**提交** $(git rev-parse --short HEAD)

### 安装与首次打开
- 未公证（ad-hoc 签名），首次打开需：\`xattr -cr MacClean.app\`
- 扫描涉及他人数据的位置时由 macOS TCC 弹窗授权；拒绝后该分类只报告不清理
- 所有删除先进废纸篓，可在「清理历史」里撤销

### 从源码构建
无 Xcode 的纯 CommandLineTools 环境需固定 SDK（CLT 不含 \`SwiftUIMacros\` 宏插件）：
\`\`\`bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
.build/debug/MacClean --selftest   # 开发构建才含自检
./scripts/build-app.sh             # 发布产物不含自检代码
\`\`\`

### 本次发版过的门槛
脱敏扫描（工作区 + 全部 git 对象）→ 开发构建 0 error / 0 Swift 源码 warning →
\`--selftest\` 全绿，或失败集与 \`docs/KNOWN-ENV-SELFTEST-FAILURES-MACOS27.md\` **逐条相同**
（本机 macOS 27 上 ViewInspector 枚举不到 SwiftUI 按钮/勾选框那一批，见 RELEASE-CHECKLIST §0.2；
多一条少一条都拦下来，不是跳过自检）→ \`--scan\` 无头冒烟 → release 包剔出自检 → 打包 zip。
明细见 docs/RELEASE-CHECKLIST.md 与 README。
NOTES
)"
gh release view "${TAG}" --json name,isDraft,assets \
    --jq '"    ✅ Release \(.name)  draft=\(.isDraft)  资产: \([.assets[].name] | join(", "))"'

echo ""
echo "================================================"
echo " ✅ ${TAG} 已发布"
echo "    $(gh release view "${TAG}" --json url --jq .url)"
echo "    别忘了：README 的功能/限制章节、docs/CLEANUP-RULES.md 若受影响要同步"
echo "================================================"
