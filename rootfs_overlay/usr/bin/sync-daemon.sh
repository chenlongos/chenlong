#!/bin/ash
# ============================================================
# sync-daemon.sh —— 独立周期性 sync 守护脚本
# 内核无周期 sync 功能，本脚本作为单独常驻进程，每隔固定秒数
# 执行一次 sync，把脏页刷回存储，等效补上"周期性 sync"。
#
# 用法：
#   直接前台运行：   ./sync-daemon.sh
#   指定间隔(秒)：   ./sync-daemon.sh 30
#   后台脱离运行：   setsid nohup /bin/ash ./sync-daemon.sh 10 >/dev/null 2>&1 </dev/null &
#
# 设计要点：本脚本只跑循环，不做任何其它业务，方便单独管理、
# 单独停止（kill 其 pid 即可），不会拖住任何调用方脚本。
#
# 断电(拔电关机)安全性说明：
#   拔电是硬断电，进程来不及收到信号，trap 不会执行，pidfile
#   无法被正常清理。因此本脚本不再把"清理 pidfile"押在 trap 上，
#   而是每次启动都做【活性 + 身份】双重校验：只要 pidfile 指向的
#   进程不是"真正的本守护进程"，就当作上次异常断电的残留，自动
#   清理并接管。这样无论上一次是正常退出还是被拔电，下次开机都能
#   自愈启动，绝不会因残留 pidfile 而静默拒绝运行。
# ============================================================

# sync 间隔（秒），可被第 1 个命令行参数覆盖，默认 10
SYNC_INTERVAL="${1:-10}"

# 单实例保护：用 pidfile 避免重复启动多个守护循环。
# 务必把 pidfile 放在断电即清空的 tmpfs 目录（/run 或 /tmp 在多数
# busybox 系统上是 tmpfs/ramfs，重启后自动为空）。若本设备 /run 并非
# tmpfs，请把它改成 /tmp/sync-daemon.pid，从根源上避免跨重启残留。
PIDFILE="/run/sync-daemon.pid"

# 用于身份比对的进程名关键字（与本脚本文件名保持一致）
DAEMON_NAME="sync-daemon"

# 判断某 PID 是否确实是"本守护进程"在运行：
#   1) kill -0  进程必须存活；
#   2) /proc/PID/cmdline 必须含本脚本名，避免旧 PID 被其它进程复用造成误判。
# 若系统没有 procfs，则降级为仅用 kill -0 判断（此时强烈依赖 tmpfs pidfile）。
is_running() {
    _pid="$1"
    [ -z "$_pid" ] && return 1
    kill -0 "$_pid" 2>/dev/null || return 1
    if [ -r "/proc/$_pid/cmdline" ]; then
        # cmdline 以 NUL 分隔，转成可读串后比对脚本名
        if tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q "$DAEMON_NAME"; then
            return 0
        fi
        return 1
    fi
    # 无 procfs：仅凭存活判断
    return 0
}

# 启动时校验 pidfile
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if is_running "$OLD_PID"; then
        # 确认本守护已在运行，退出，不重复启动
        exit 0
    fi
    # 走到这里：进程不存活，或 PID 被复用成了别的进程，
    # 判定为上次异常断电 / 崩溃遗留的无效 pidfile，自动清理接管。
    rm -f "$PIDFILE" 2>/dev/null
fi

# 记录自身 pid（写入失败不致命，单实例保护会降级为尽力而为）
echo "$$" > "$PIDFILE" 2>/dev/null

# 退出时清理 pidfile（正常退出 / 手动 kill 走这里；拔电走不到，
# 由下次启动的双重校验兜底清理）
trap 'rm -f "$PIDFILE" 2>/dev/null' EXIT INT TERM

# 周期性 sync 主循环
while :; do
    sleep "$SYNC_INTERVAL"
    sync
done
