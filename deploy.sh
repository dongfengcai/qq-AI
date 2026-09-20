#!/usr/bin/env bash
# ============================================================================
#  deploy.sh -- 一键部署 鲸鱼娘聊天AI
#
#  用法：
#      bash deploy.sh                     # 交互式
#      bash deploy.sh --yes               # 全默认，不问任何问题
#      DEEPSEEK_API_KEY=sk-xxx bash deploy.sh --yes
#
#  幂等：可以重复执行。已存在的配置不会被覆盖（除非加 --force-config）。
#
#  本脚本只做「装环境 + 起服务 + 装插件」，不改动 AstrBot 的内部配置。
#  模型、人设、平台这些要在 AstrBot 面板里配 —— 脚本最后会告诉你怎么做。
# ============================================================================
set -euo pipefail

# --- 定位自身目录（从哪运行都行）--------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PLUGIN_SRC="plugins"
DATA_DIR="data"
PLUGIN_DST="$DATA_DIR/plugins"

# --- 输出辅助 ---------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'; C_STEP=$'\033[36m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_OK=""; C_WARN=""; C_ERR=""; C_STEP=""; C_DIM=""
fi

step()  { printf '%s==>%s %s\n' "$C_STEP" "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn()  { printf '%s  !%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
dim()   { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

banner() {
    printf '\n%s' "$C_STEP"
    echo "============================================================"
    echo "  鲸鱼娘聊天AI · 自动部署"
    echo "============================================================"
    printf '%s\n' "$C_RESET"
}

# ============================================================================
#  参数
# ============================================================================
ASSUME_YES=0
FORCE_CONFIG=0
SKIP_SWAP=0
SKIP_DOCKER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)           ASSUME_YES=1 ;;
        --force-config)     FORCE_CONFIG=1 ;;
        --skip-swap)        SKIP_SWAP=1 ;;
        --skip-docker)      SKIP_DOCKER=1 ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "未知参数：$1（用 --help 看用法）" ;;
    esac
    shift
done

banner

# ============================================================================
#  1. 预检
# ============================================================================
step "检查运行环境"

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash deploy.sh"

# --- 发行版识别 -------------------------------------------------------------
DISTRO_ID=""; DISTRO_LIKE=""; DISTRO_NAME="未知"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
fi

if [[ "$DISTRO_ID" == "debian" || "$DISTRO_ID" == "ubuntu" || "$DISTRO_LIKE" == *debian* || "$DISTRO_LIKE" == *ubuntu* ]]; then
    OS_FAMILY="debian"
elif [[ "$DISTRO_ID" == "rhel" || "$DISTRO_ID" == "centos" || "$DISTRO_ID" == "fedora" \
     || "$DISTRO_ID" == "rocky" || "$DISTRO_ID" == "almalinux" || "$DISTRO_LIKE" == *rhel* \
     || "$DISTRO_LIKE" == *fedora* ]]; then
    OS_FAMILY="rhel"
else
    OS_FAMILY="unknown"
fi
ok "系统：$DISTRO_NAME（包管理器族：$OS_FAMILY）"

# --- 依赖命令 ---------------------------------------------------------------
for c in curl tar sed awk grep; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c，请先安装"
done

# --- Python（容器外的辅助用途）----------------------------------------------
HOST_PY=""
for p in python3 python; do
    if command -v "$p" >/dev/null 2>&1; then HOST_PY="$p"; break; fi
done
if [[ -n "$HOST_PY" ]]; then
    ok "Python：$($HOST_PY --version 2>&1)"
else
    warn "没找到 python3 —— 会自动改用容器内的 Python 生成插件配置（不影响使用）"
fi

# --- 内存 -------------------------------------------------------------------
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if (( MEM_MB > 0 && MEM_MB < 1800 )); then
    warn "内存只有 ${MEM_MB}MB，低于建议的 2GB。swap 会很重要（下一步会处理）"
else
    ok "内存：${MEM_MB}MB"
fi

# --- 检查发布包完整性 -------------------------------------------------------
[[ -d "$PLUGIN_SRC" ]] || die "找不到 $PLUGIN_SRC 目录。请在解压后的项目根目录运行本脚本。"
[[ -f docker-compose.yml ]] || die "找不到 docker-compose.yml。请在项目根目录运行本脚本。"

PLUGIN_COUNT=$(find "$PLUGIN_SRC" -mindepth 1 -maxdepth 1 -type d | wc -l)
(( PLUGIN_COUNT > 0 )) || die "$PLUGIN_SRC 里没有插件目录"
ok "发现 $PLUGIN_COUNT 个插件"

# 校验每个插件的必备文件
for p in "$PLUGIN_SRC"/*/; do
    name=$(basename "$p")
    for f in main.py metadata.yaml; do
        [[ -f "$p/$f" ]] || die "$name 缺少 $f，发布包不完整"
    done
done
ok "插件文件完整"

# ============================================================================
#  2. 收集配置
# ============================================================================
echo
step "配置"

# 已有 .env 就不重复问
ENV_FILE=".env"
EXISTING_KEY=""

ask() {
    # ask <变量名> <提示> <默认值>
    local var="$1" prompt="$2" default="${3:-}" answer=""
    if (( ASSUME_YES )); then
        printf -v "$var" '%s' "$default"
        return
    fi
    if [[ -n "$default" ]]; then
        read -r -p "  $prompt [$default]: " answer || true
    else
        read -r -p "  $prompt: " answer || true
    fi
    printf -v "$var" '%s' "${answer:-$default}"
}

if [[ -f "$ENV_FILE" ]]; then
    ok "已有 .env，沿用其中的设置"
    # shellcheck disable=SC1091
    set -a; . "./$ENV_FILE"; set +a
    DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
    ADMIN_QQ="${ADMIN_QQ:-}"
else
    DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
    ADMIN_QQ="${ADMIN_QQ:-}"
fi

# --- API Key ---------------------------------------------------------------
if [[ -z "$DEEPSEEK_API_KEY" ]]; then
    echo
    dim "DeepSeek API Key 用于查余额和自动打标签。"
    dim "获取：https://platform.deepseek.com/api_keys"
    dim "（现在不填也行，装完在 AstrBot 插件面板里补）"
    ask DEEPSEEK_API_KEY "DeepSeek API Key" ""
fi

# --- 管理员 QQ --------------------------------------------------------------
if [[ -z "$ADMIN_QQ" ]]; then
    echo
    dim "管理员 QQ 用来接收告警、执行恢复指令（如 /表情、余额恢复）。"
    ask ADMIN_QQ "你的 QQ 号" ""
fi

# --- 收集来源群 -------------------------------------------------------------
COLLECT_GROUPS="${COLLECT_GROUPS:-}"
if [[ -z "$COLLECT_GROUPS" && $ASSUME_YES -eq 0 ]]; then
    echo
    dim "表情收集只在这些群里生效。留空 = 所有群都收。"
    dim "多个群号用逗号分隔。"
    ask COLLECT_GROUPS "允许收集表情的群号" ""
fi

# --- 时区 -------------------------------------------------------------------
TZ_VALUE="${TZ:-Asia/Shanghai}"

# --- NapCat UID/GID ---------------------------------------------------------
NAPCAT_UID="${NAPCAT_UID:-$(stat -c '%u' .)}"
NAPCAT_GID="${NAPCAT_GID:-$(stat -c '%g' .)}"

# --- 落盘 -------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" || $FORCE_CONFIG -eq 1 ]]; then
    cat > "$ENV_FILE" <<ENVEOF
# 由 deploy.sh 生成。可以手改，改完重跑 deploy.sh 或 docker compose up -d。
#
# NapCat 写文件用的 UID/GID。默认取本目录所有者。
NAPCAT_UID=$NAPCAT_UID
NAPCAT_GID=$NAPCAT_GID

# 时区。影响日志时间与 DeepSeek 峰谷价判断。
TZ=$TZ_VALUE

# --- 下面两项会被 deploy.sh 写进插件配置，改完重跑脚本即可生效 ---
DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY
ADMIN_QQ=$ADMIN_QQ
COLLECT_GROUPS=$COLLECT_GROUPS
ENVEOF
    chmod 600 "$ENV_FILE"
    ok "已写入 .env（权限 600）"
else
    # 已有 .env，但这次可能补了值 —— 更新对应行
    for kv in "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" "ADMIN_QQ=$ADMIN_QQ" "COLLECT_GROUPS=$COLLECT_GROUPS"; do
        k="${kv%%=*}"
        if grep -q "^${k}=" "$ENV_FILE"; then
            # 用 | 作分隔符，避免 key 里可能的 / 引起问题
            sed -i "s|^${k}=.*|${kv}|" "$ENV_FILE"
        else
            echo "$kv" >> "$ENV_FILE"
        fi
    done
    ok "已更新 .env"
fi

if [[ -z "$DEEPSEEK_API_KEY" ]]; then
    warn "未填 API Key —— 余额查询和自动打标签需要它"
    dim "装完后在 AstrBot 面板 → 插件 → 余额守护 里补填"
fi

# ============================================================================
#  3. Docker
# ============================================================================
echo
step "Docker"

install_docker() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
            curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
                -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
        fi
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO_ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        # CentOS Stream 10 等自带 podman，先移除避免冲突
        dnf -y remove podman buildah docker docker-client docker-common \
            docker-latest docker-logrotate docker-engine 2>/dev/null || true
        dnf -y install dnf-plugins-core
        # RHEL 系统一用 centos 仓库路径
        dnf config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo
        dnf -y install docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    else
        die "不认识的发行版，无法自动装 Docker。请手动安装后加 --skip-docker 重跑。"
    fi
}

if (( SKIP_DOCKER )); then
    warn "按要求跳过 Docker 安装"
elif command -v docker >/dev/null 2>&1; then
    ok "Docker 已安装：$(docker --version)"
else
    dim "未检测到 Docker，开始安装（首次约 1-3 分钟）..."
    install_docker
    ok "Docker 安装完成"
fi

systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die "Docker 守护进程没起来。试试：systemctl start docker"
ok "Docker 守护进程正常"

if ! docker compose version >/dev/null 2>&1; then
    die "docker compose 插件不可用。请安装 docker-compose-plugin 后重试。"
fi
ok "Compose：$(docker compose version --short 2>/dev/null || echo 可用)"

# --- 日志轮转（避免长期运行把磁盘写满）--------------------------------------
mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'JSONEOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "max-concurrent-downloads": 10
}
JSONEOF
    systemctl restart docker
    ok "已配置 Docker 日志轮转（每个容器最多 30MB）"
else
    warn "/etc/docker/daemon.json 已存在，未改动"
    dim "若其中没有 log-opts max-size，长期运行可能撑满磁盘"
fi

# ============================================================================
#  4. swap
# ============================================================================
echo
step "swap"

if (( SKIP_SWAP )); then
    warn "按要求跳过 swap"
elif swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
    ok "swap 已启用：$(free -h | awk '/Swap/ {print $2}')"
else
    SWAP_SIZE="${SWAP_SIZE:-2}"
    dim "2GB 内存上 swap 是刚需 —— 没它的话内存尖峰会被 OOM 杀掉进程且无提示。"
    dim "创建 ${SWAP_SIZE}G swap..."
    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l "${SWAP_SIZE}G" /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE * 1024)) status=none
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
    fi
    if swapon /swapfile 2>/dev/null; then
        if ! grep -qsF '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        mkdir -p /etc/sysctl.d
        cat > /etc/sysctl.d/99-dsh-swap.conf <<'CONF'
vm.swappiness = 20
vm.vfs_cache_pressure = 50
CONF
        sysctl --system >/dev/null 2>&1 || true
        ok "swap 已启用（${SWAP_SIZE}G，swappiness=20）"
    else
        warn "swapon 失败 —— 某些文件系统不支持 swap 文件。"
        dim "服务仍可运行，但内存吃紧时可能被 OOM 杀掉"
    fi
fi

# ============================================================================
#  5. 准备目录
# ============================================================================
echo
step "准备数据目录"

mkdir -p napcat/config ntqq "$DATA_DIR"
chown -R "$NAPCAT_UID:$NAPCAT_GID" napcat ntqq "$DATA_DIR" 2>/dev/null || true
ok "napcat/ ntqq/ data/ 就绪（属主 $NAPCAT_UID:$NAPCAT_GID）"

# ============================================================================
#  6. 启动容器
# ============================================================================
echo
step "启动容器"

# compose 文件里的 TZ 由 .env 提供
if ! docker compose up -d 2>&1 | tail -20; then
    echo
    err "容器启动失败。常见原因："
    dim "· 拉不到镜像（国内网络）—— 给 Docker 配镜像加速后重试"
    dim "  参考 README 的「拉不到镜像怎么办」一节"
    exit 1
fi
ok "容器已启动"

dim "等待 AstrBot 就绪（首次启动要初始化数据库，最多 90 秒）..."
READY=0
for _ in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:6185/ 2>/dev/null; then
        READY=1; break
    fi
    sleep 2
done
if (( READY )); then
    ok "AstrBot 已就绪"
else
    warn "90 秒内 AstrBot 未响应，继续装插件（可能只是启动慢）"
    dim "排查：docker compose logs --tail 50 astrbot"
fi

# ============================================================================
#  7. 安装插件
# ============================================================================
echo
step "安装插件"

mkdir -p "$PLUGIN_DST"
for p in "$PLUGIN_SRC"/*/; do
    name=$(basename "$p")
    rm -rf "${PLUGIN_DST:?}/$name"
    cp -r "$p" "$PLUGIN_DST/$name"
    rm -rf "$PLUGIN_DST/$name/__pycache__"
done
chmod -R a+rX "$PLUGIN_DST"
ok "已安装 $PLUGIN_COUNT 个插件到 $PLUGIN_DST"

# --- 校验目录名与 metadata 一致（不一致 AstrBot 会拒绝加载）-----------------
MISMATCH=0
for d in "$PLUGIN_DST"/*/; do
    [[ -d "$d" ]] || continue
    n=$(basename "$d")
    m=$(sed -n 's/^name:[[:space:]]*//p' "$d/metadata.yaml" 2>/dev/null | head -1 | tr -d '\r' | xargs || true)
    if [[ "$n" != "$m" ]]; then
        err "$n 的 metadata name 是 '$m'，与目录名不一致"
        MISMATCH=1
    fi
done
(( MISMATCH == 0 )) && ok "插件目录名与 metadata 一致"
(( MISMATCH == 0 )) || die "插件元数据有问题，AstrBot 会拒绝加载"

# ============================================================================
#  8. 生成插件配置
# ============================================================================
echo
step "生成插件配置"

# 从 _conf_schema.json 里读 default，加上用户填的值，写成插件配置。
# 这样插件新增配置项时，本脚本不用跟着改。
generate_plugin_config() {
    local plugin="$1" overrides_json="$2"
    local schema="$PLUGIN_DST/$plugin/_conf_schema.json"
    local outdir="$DATA_DIR/config"
    local out="$outdir/${plugin}_config.json"

    [[ -f "$schema" ]] || return 0
    mkdir -p "$outdir"

    if [[ -f "$out" && $FORCE_CONFIG -eq 0 ]]; then
        dim "$plugin：配置已存在，跳过（用 --force-config 覆盖）"
        return 0
    fi

    local py=""
    if [[ -n "$HOST_PY" ]]; then
        py="$HOST_PY"
    elif docker compose exec -T astrbot python --version >/dev/null 2>&1; then
        # 用容器里的 Python，把宿主机路径映射进容器
        docker compose exec -T astrbot python -c "
import json, sys, os
schema = json.load(open('/AstrBot/data/plugins/$plugin/_conf_schema.json', encoding='utf-8'))
over = json.loads('''$overrides_json''')
cfg = {}
for k, spec in schema.items():
    if isinstance(spec, dict) and 'default' in spec:
        cfg[k] = spec['default']
cfg.update(over)
os.makedirs('/AstrBot/data/config', exist_ok=True)
json.dump(cfg, open('/AstrBot/data/config/${plugin}_config.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
" && ok "$plugin：配置已生成" || warn "$plugin：配置生成失败，请手动在面板里填"
        return 0
    else
        warn "$plugin：没有可用的 Python，跳过配置生成（在面板里手动填即可）"
        return 0
    fi

    "$py" - "$schema" "$out" "$overrides_json" <<'PYEOF'
import json, sys
schema_path, out_path, overrides = sys.argv[1], sys.argv[2], sys.argv[3]
with open(schema_path, encoding='utf-8') as f:
    schema = json.load(f)
with open(out_path, 'w', encoding='utf-8') as f:
    cfg = {}
    for k, spec in schema.items():
        if isinstance(spec, dict) and 'default' in spec:
            cfg[k] = spec['default']
    if overrides:
        cfg.update(json.loads(overrides))
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PYEOF
    ok "$plugin：配置已生成"
}

# 从 .env 里取当前值
API_KEY_JSON=$(printf '%s' "$DEEPSEEK_API_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')
ADMIN_JSON=$(printf '%s' "$ADMIN_QQ" | sed 's/\\/\\\\/g; s/"/\\"/g')

# 余额守护：填 key 和管理员
generate_plugin_config "astrbot_plugin_balance_guard" \
    "{\"api_key\": \"$API_KEY_JSON\", \"admin_qq\": \"$ADMIN_JSON\"}"

# 表情插件：填管理员；（收集群列表涉及数组，留给面板更省事）
generate_plugin_config "astrbot_plugin_meme" \
    "{\"admin_qq\": \"$ADMIN_JSON\"}"

# 其余插件用默认值
for p in "$PLUGIN_SRC"/*/; do
    name=$(basename "$p")
    case "$name" in
        astrbot_plugin_balance_guard|astrbot_plugin_meme) continue ;;
    esac
    generate_plugin_config "$name" "{}"
done

# ============================================================================
#  9. 重启让插件生效
# ============================================================================
echo
step "重启 AstrBot 让插件生效"

dim "新增插件目录必须重启容器才会被扫描到（面板里的「重载插件」不够）"
docker compose restart astrbot >/dev/null 2>&1 || true

sleep 8
LOADED=$(docker compose logs --tail 200 astrbot 2>/dev/null | grep -c "Loading plugin astrbot_plugin_" || true)
if (( LOADED >= PLUGIN_COUNT )); then
    ok "已加载 $LOADED 个插件"
else
    warn "日志里只看到 $LOADED 个插件被加载（期望 $PLUGIN_COUNT 个）"
    dim "排查：docker compose logs astrbot | grep -iE 'Loading plugin|skipping|Failed to import'"
fi

# ============================================================================
#  10. 完成
# ============================================================================
SERVER_IP=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null \
         || hostname -I 2>/dev/null | awk '{print $1}' || echo "<服务器IP>")

cat <<EOF

$C_STEP============================================================$C_RESET
$C_OK  部署完成$C_RESET
$C_STEP============================================================$C_RESET

你的服务器 IP：$SERVER_IP

$C_STEP 第一步：开 SSH 隧道$C_RESET
  在你自己的电脑上运行（不是服务器上），保持窗口不关：

      ssh -N -L 6099:127.0.0.1:6099 -L 6185:127.0.0.1:6185 root@$SERVER_IP

  说明：所有面板端口都只绑在服务器本机，公网打不到（这是刻意的安全设计）。
  想更省事，可以用项目自带的 scripts/tunnel.cmd（Windows，自动重连）。

$C_STEP 第二步：扫码登录 QQ$C_RESET
  1. 取 NapCat 登录密钥：
         docker compose logs napcat | grep -i token
  2. 浏览器打开 http://127.0.0.1:6099/webui ，填入密钥
  3. 用手机 QQ 扫码

  ⚠️ 强烈建议用小号。非官方协议端有封号风险。
  ⚠️ 登录后确认会话已持久化：ls -la ntqq/  （空的说明重启会掉登录）

$C_STEP 第三步：配置 AstrBot$C_RESET
  取初始密码：
      docker compose logs astrbot | grep -i password

  浏览器打开 http://127.0.0.1:6185 ，用 astrbot / 那个密码登录，然后：

  1. 【立刻改密码】
  2. 模型提供商 → 对话 → 新增 → DeepSeek
       API Key：填你的 key
       API Base URL：https://api.deepseek.com/v1
     保存并获取模型
  3. AI 配置 → 模型 → 对话模型 → 选 deepseek-flash
       ⚠️ 必须是 deepseek-flash —— 它是唯一支持图片的 DeepSeek 模型
  4. 机器人 / 平台管理 → 创建机器人 → OneBot v11
       反向 WebSocket 主机：0.0.0.0
       反向 WebSocket 端口：6199
       Token：留空
     ⚠️ 保存后必须重启容器，否则 6199 不会开始监听：
         docker compose restart astrbot
  5. 人格设置 → 粘贴 persona-whale-girl.md 里的提示词
  6. 模型提供商 → 关闭「流式输出」
       开着的话表情标记会外露在文本里

$C_STEP 第四步：验证$C_RESET
  QQ 私聊机器人发「你好」—— 应该有回复。

  看插件日志：
      docker compose logs -f astrbot | grep -iE "balance_guard|identity|meme|poke|arbiter"

$C_STEP 常用命令$C_RESET
  cd $SCRIPT_DIR
  docker compose ps                 # 状态
  docker compose logs -f astrbot    # 跟日志
  docker compose restart astrbot    # 重启机器人
  docker stats --no-stream          # 看内存占用
  free -h                           # 内存 + swap

$C_STEP 安全提醒$C_RESET
  去云控制台的安全组，确认只放行了 22（SSH）。
  6099 / 6185 / 6199 都不该对公网开放。

  详细说明见 README.md。

$C_DIM 项目地址：https://github.com/dongfengcai/whale-girl-chat-ai$C_RESET
$C_DIM 遇到问题请开 issue，附上相关日志。$C_RESET

EOF
