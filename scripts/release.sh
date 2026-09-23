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
cd "$(dirname "$0")/.."

BRANCH="main"
ALLOWLIST="scripts/secrets-allowlist.txt"
OLD_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
TREE_PATHS=(Sources docs scripts Resources README.md Package.swift Package.resolved)
STEP=0
STEPS=9
SCAN_HITS=0
ABSOLUTE_HITS=0

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

grep_tree() {
    local out="" rc=0
    out="$(git grep -nIE -e "$1" -- "${TREE_PATHS[@]}" 2>/tmp/mc-scan-grep.err)" || rc=$?
    if [ "${rc}" -gt 1 ]; then
        cat /tmp/mc-scan-grep.err >&2
        die "扫描规则执行失败（git grep exit ${rc}）: $1"
    fi
    [ -n "${out}" ] && printf '%s\n' "${out}"
    return 0
}

grep_hist() {
    local out="" rc=0
    out="$(printf '%s\n' "${HIST_BLOB}" | grep -E -e "$1" 2>/tmp/mc-scan-grep.err)" || rc=$?
    if [ "${rc}" -gt 1 ]; then
        cat /tmp/mc-scan-grep.err >&2
        die "扫描规则执行失败（grep exit ${rc}）: $1"
    fi
    [ -n "${out}" ] && printf '%s\n' "${out}"
    return 0
}

VERSION="${1:-}"
TITLE="${2:-}"
DRY_RUN=0
SKIP_SCAN=0
if [ -z "${VERSION}" ] || [ -z "${TITLE}" ]; then
    die "用法: scripts/release.sh <X.Y.Z> \"<标题>\" [--dry-run]"
fi
shift 2
for arg in "$@"; do
    case "${arg}" in
        --dry-run)   DRY_RUN=1 ;;
        --skip-scan) SKIP_SCAN=1 ;;
        *) die "未知参数: ${arg}" ;;
    esac
done
printf '%s' "${VERSION}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "版本号格式应为 X.Y.Z，收到: ${VERSION}"
TAG="v${VERSION}"

# ---------------------------------------------------------------- 脱敏扫描
# 规则分两档：absolute 一类是"绝对零命中"，命中即真凭据，只能删、不许备案；
# 其余可能是自检夹具（本项目自带凭据检测器，仓库里本来就有假凭据字符串），
# 允许人工复核后写进 ${ALLOWLIST}。
# 格式：规则名<TAB>是否绝对<TAB>ERE
rules() {
    printf 'private_key\tabs\t-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----\n'
    printf 'github_token\tabs\tgh[pousrIw]_[A-Za-z0-9]{20,}\n'
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

# 备案表：scope<TAB>file-or-*<TAB>rule<TAB>reason
allowlisted() {
    [ -f "${ALLOWLIST}" ] || return 1
    awk -F'\t' -v s="$1" -v f="$2" -v r="$3" \
        '$1==s && ($2=="*"||$2==f) && $3==r { found=1 } END { exit !found }' "${ALLOWLIST}"
}

report_hit() { # scope file rule line
    if allowlisted "$1" "$2" "$3"; then
        echo "    ~ ${3} 已备案 ${1}:${2}"
        return
    fi
    echo "    ✖ ${3} 未备案  ${1} ${4}" >&2
    echo "      值: $(mask "${5:-}")" >&2
    SCAN_HITS=$((SCAN_HITS + 1))
    if [ "${6:-no}" = "abs" ]; then ABSOLUTE_HITS=$((ABSOLUTE_HITS + 1)); fi
}

scan_tree() {
    local rule abs pat line f rest ln v
    while IFS=$'\t' read -r rule abs pat; do
        [ -n "${rule}" ] || continue
        # -I 跳过二进制；pathspec 保证只扫入库内容，不碰 .build/dist
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            f="${line%%:*}"
            rest="${line#*:}"
            ln="${rest%%:*}"
            v="${rest#*:}"
            if fixture_shape "${v}"; then
                echo "    ~ ${rule} 夹具形状 ${f}:${ln} $(mask "${v}")"
            else
                report_hit tree "${f}" "${rule}" "${f}:${ln}" "${v}" "${abs}"
            fi
        done < <(grep_tree "${pat}")
    done < <(rules)
}

scan_history() {
    local rule abs pat line
    HIST_BLOB="$(git log --all -p -U0 --format='' 2>/dev/null || true)"
    if [ -z "${HIST_BLOB}" ]; then
        echo "    （无历史可扫）"
        return
    fi
    while IFS=$'\t' read -r rule abs pat; do
        [ -n "${rule}" ] || continue
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            if fixture_shape "${line}"; then
                continue
            elif allowlisted hist "*" "${rule}"; then
                echo "    ~ ${rule} 已备案（历史）"
            else
                report_hit hist "*" "${rule}" "历史 diff" "${line#+}" "${abs}"
            fi
        done < <(grep_hist "${pat}")
    done < <(rules)
    echo "    （历史扫描完成）"
}

# 本机身份：仓库里 LICENSE 的账号名是已确认可公开的，但 /Users/<account> 形式的
# 绝对路径不算——那会把本机用户名、目录结构一起带到公开仓库。
scan_identity() {
    local user hits
    user="$(id -un)"
    hits="$(grep_tree "/Users/${user}")"
    if [ -n "${hits}" ]; then
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            report_hit tree "${line%%:*}" local_home "含本机绝对路径" "" no
        done <<< "${hits}"
    fi
    echo "    （身份标识扫描完成：账号名本身不算命中，/Users/<账号名> 算）"
}

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
if [ "${SKIP_SCAN}" = 1 ]; then
    warn "--skip-scan：跳过脱敏扫描。据此产出的包不得发布"
else
    scan_tree
    scan_identity
    scan_history
    if [ "${SCAN_HITS}" -gt 0 ]; then
        echo "" >&2
        echo "  未备案命中 ${SCAN_HITS} 处。两条路，没有第三条:" >&2
        echo "    ① 删掉真实值，改走环境变量或系统钥匙串；" >&2
        echo "    ② 确认是假数据后，往 ${ALLOWLIST} 加一行「scope<TAB>file<TAB>rule<TAB>reason」。" >&2
        [ "${ABSOLUTE_HITS}" -gt 0 ] && \
            echo "  其中 ${ABSOLUTE_HITS} 条属绝对零命中类（私钥/GitHub/AWS/Slack/Google），不许备案，只能删。" >&2
        die "脱敏扫描未通过"
    fi
    echo "    ✅ 扫描通过"
fi

# ---------------------------------------------------------------- 2 构建
step "开发构建（含自检）"
[ -d "${OLD_SDK}" ] && [ ! -d /Applications/Xcode.app ] && export SDKROOT="${SDKROOT:-${OLD_SDK}}"
if ! swift build 2>/tmp/mc-release-build.err >/tmp/mc-release-build.out; then
    tail -30 /tmp/mc-release-build.err >&2
    die "swift build 失败"
fi
grep -E "warning:.*\.swift" /tmp/mc-release-build.err >/tmp/mc-release-warn.txt 2>/dev/null || true
if [ -s /tmp/mc-release-warn.txt ]; then
    warn "有 $(wc -l < /tmp/mc-release-warn.txt) 条 Swift 源码告警（门槛要求 0 条）:"
    head -5 /tmp/mc-release-warn.txt >&2
fi
tail -2 /tmp/mc-release-build.out

# ---------------------------------------------------------------- 3 自检
step "全量自检"
set +e
.build/debug/MacClean --selftest >/tmp/mc-release-selftest.log 2>&1
ST_RC=$?
set -e
tail -4 /tmp/mc-release-selftest.log
[ "${ST_RC}" = 0 ] || die "自检未通过（exit ${ST_RC}）——修完再发，不带红灯发版"

# ---------------------------------------------------------------- 4 冒烟
step "无头扫描冒烟"
set +e
( with_timeout 600 .build/debug/MacClean --scan >/tmp/mc-release-scan.log 2>&1 )
SCAN_RC=$?
set -e
[ "${SCAN_RC}" = 0 ] || { tail -15 /tmp/mc-release-scan.log >&2; die "--scan 冒烟失败（exit ${SCAN_RC}）"; }
echo "    ✅ --scan 正常（输出 $(wc -l < /tmp/mc-release-scan.log) 行）"

# ---------------------------------------------------------------- 5 打包
step "打包 release 产物"
PREV_VERSION="$(sed -nE 's/^VERSION="([0-9.]+)"/\1/p' scripts/build-app.sh | head -1)"
sed -i '' -E "s/^VERSION=\"[0-9.]+\"/VERSION=\"${VERSION}\"/" scripts/build-app.sh
grep -q "^VERSION=\"${VERSION}\"" scripts/build-app.sh || die "VERSION 没写进 build-app.sh"
if ! ./scripts/build-app.sh >/tmp/mc-release-app.log 2>&1; then
    tail -25 /tmp/mc-release-app.log >&2
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
git add -- Sources docs scripts README.md Package.swift Package.resolved 2>/dev/null || true
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
脱敏扫描（工作区 + 全部 git 对象）→ 开发构建 0 error → \`--selftest\` 全绿 →
\`--scan\` 无头冒烟 → release 包剔出自检 → 打包 zip。
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
