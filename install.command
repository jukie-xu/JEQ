#!/bin/bash
# JEQ 一键构建 + 清理旧版本 + 安装 + 重启
# 用法：双击本文件，或在终端执行 ./install.command
#
# 安装策略：整个系统只保留一份 app。
#   1) 编译新版本（build/JEQ.app）
#   2) 退出正在运行的 JEQ / SubEQ
#   3) 安装到 /Applications/JEQ.app（无写权限时 ~/Applications/JEQ.app）
#   4) 删除 /Applications 与 ~/Applications 下的其余 JEQ.app / SubEQ.app 副本
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="JEQ"
OLD_NAME="SubEQ"

echo "▸ 检查编译环境"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "✗ 找不到 swiftc。请先安装 Xcode Command Line Tools：xcode-select --install"
    read -n 1 -s -r -p "按任意键关闭…"
    exit 1
fi

echo "▸ 构建 $APP_NAME"
./build.sh

echo "▸ 退出正在运行的旧版本"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
osascript -e "tell application \"$OLD_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$OLD_NAME" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || pgrep -x "$OLD_NAME" >/dev/null 2>&1 || break
    sleep 0.2
done

remove_app() {
    local victim="$1"
    [ -e "$victim" ] || return 0
    if rm -rf "$victim" 2>/dev/null && [ ! -e "$victim" ]; then
        echo "  已删除 $victim"
        return 0
    fi
    echo "  需要管理员权限：$victim"
    osascript -e "do shell script \"rm -rf '$victim'\" with administrator privileges" >/dev/null 2>&1 || true
    if [ ! -e "$victim" ]; then
        echo "  已删除 $victim"
    else
        echo "  ⚠️ 删除失败，请手动移到废纸篓：$victim"
    fi
}

echo "▸ 选择唯一安装位置"
TARGET_DIR="/Applications"
if [ ! -w "$TARGET_DIR" ]; then
    TARGET_DIR="$HOME/Applications"
    mkdir -p "$TARGET_DIR"
    echo "  /Applications 不可写，改用 $TARGET_DIR"
fi
APP="$TARGET_DIR/$APP_NAME.app"
TMP="$TARGET_DIR/.$APP_NAME.app.installing"

echo "▸ 安装到 $APP"
rm -rf "$TMP"
cp -R "build/$APP_NAME.app" "$TMP"
remove_app "$APP"
mv "$TMP" "$APP"
chmod +x "$APP/Contents/MacOS/JEQ" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

echo "▸ 删除其余副本"
for dir in "/Applications" "$HOME/Applications"; do
    [ -d "$dir" ] || continue
    # 精确名 + Finder 复制产生的「JEQ 2.app / SubEQ 副本.app」这类同名前缀副本
    for victim in "$dir/$APP_NAME.app" "$dir/$APP_NAME "*.app \
                  "$dir/$OLD_NAME.app" "$dir/$OLD_NAME "*.app; do
        [ "$victim" = "$APP" ] && continue
        remove_app "$victim" || true
    done
done

# 清掉旧版可能留下的登录项，避免开机时把已删除的旧 app 拉起来
rm -f "$HOME/Library/LaunchAgents/com.subeq.app.plist" 2>/dev/null || true

# 已启用 LaunchAgent 的话，把启动路径改成刚安装的位置（系统登录项则由系统自己维护）
AGENT="$HOME/Library/LaunchAgents/com.jeq.app.plist"
if [ -f "$AGENT" ]; then
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $APP/Contents/MacOS/JEQ" "$AGENT" 2>/dev/null || true
    echo "  已同步开机启动路径"
fi

# 一次性恢复：把覆盖前的自定义曲线导入回来（见 .restore-custom 里的备份路径）
if [ -f .restore-custom ]; then
    backup="$(cat .restore-custom)"
    if [ -n "$backup" ] && [ -f "$backup" ]; then
        echo "▸ 恢复覆盖前的自定义曲线: $backup"
        defaults import com.jeq.app "$backup" || echo "⚠️ 恢复失败，可手动执行 defaults import"
    else
        echo "⚠️ 找不到恢复备份: $backup"
    fi
    rm -f .restore-custom
fi

echo "▸ 启动"
open -a "$APP"
sleep 1.5
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "  ✓ $APP_NAME 已启动：它是菜单栏应用，没有窗口，图标在屏幕右上角菜单栏。"
else
    echo "  ⚠️ $APP_NAME 没有保持运行。最近 2 分钟的系统日志："
    log show --last 2m --predicate "process == \"$APP_NAME\"" --style compact 2>/dev/null | tail -25 || true
    echo "  也可以手动运行看报错：\"$APP/Contents/MacOS/JEQ\""
fi

echo ""
echo "▸ 核对安装结果"
found=0
for dir in "/Applications" "$HOME/Applications"; do
    [ -d "$dir" ] || continue
    for victim in "$dir/$APP_NAME.app" "$dir/$APP_NAME "*.app \
                  "$dir/$OLD_NAME.app" "$dir/$OLD_NAME "*.app; do
        if [ -e "$victim" ]; then
            echo "  ✓ $victim"
            found=$((found + 1))
        fi
    done
done
if [ "$found" -ne 1 ]; then
    echo "  ⚠️ 预期只保留 1 份 app，实际找到 $found 份，请检查上面的删除提示。"
else
    echo "  ✓ 全系统只保留这一份"
fi

echo ""
echo "✓ 完成。首次启动若弹出「系统音频录制」权限请求，请允许。"
read -n 1 -s -r -p "按任意键关闭这个窗口…" || true
