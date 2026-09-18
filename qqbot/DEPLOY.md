# 部署清单（纯手动命令）

全部在服务器上操作，逐步复制执行。每步都给了验证方法。

---

## 0. 传文件

在**你的 Windows 电脑**上：

```powershell
scp -r D:\Deespeek\qqbot root@<服务器IP>:/root/qqbot
```

或用你习惯的 SFTP / 阿里云 Workbench 上传。

验证：

```bash
ls /root/qqbot
# 应看到 docker-compose.yml、.env.example、DEPLOY.md、config/、plugins/
```

---

## 1. 装 Docker

CentOS Stream 10 默认带的是 **podman 不是 docker**，所以要装 docker-ce。

```bash
# 移除冲突包（podman/buildah 若存在）
dnf -y remove podman buildah 2>/dev/null || true

dnf -y install dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
```

**配日志轮转**（长期运行不配会把磁盘写满）：

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
systemctl restart docker
```

验证：

```bash
docker --version
docker compose version
docker info | head -5
```

---

## 2. 配 swap（2GB 内存上不要跳过）

不加 swap 的话，内存尖峰时内核的 OOM Killer 会杀掉机器人进程，而且是静默的。
swap 不会让性能变快，它把"硬崩溃"变成"变慢" —— 这正是长期无人值守需要的。

```bash
fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# 持久化，重启后仍生效
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 调低 swappiness：优先用内存，swap 只当安全阀
cat > /etc/sysctl.d/99-dsh-swap.conf <<'CONF'
vm.swappiness = 20
vm.vfs_cache_pressure = 50
CONF
sysctl --system
```

验证：

```bash
free -h
# Swap 一行应为 2.0Gi

swapon --show
# 应列出 /swapfile

cat /proc/sys/vm/swappiness
# 应为 20
```

> 某些文件系统不接受 `fallocate` 生成的 swap 文件，`swapon` 会报 `Invalid argument`。
> 这时删掉重来，改用上面 `|| dd ...` 那条。

---

## 3. 起服务

```bash
cd /root/qqbot

cp .env.example .env

# 把 UID/GID 设成当前目录所有者，否则 NapCat 写不了 QQ 登录态
sed -i "s/^NAPCAT_UID=.*/NAPCAT_UID=$(stat -c '%u' .)/" .env
sed -i "s/^NAPCAT_GID=.*/NAPCAT_GID=$(stat -c '%g' .)/" .env

# 建挂载目录并设好属主（让 Docker 建的话会是 root，NapCat 以非 root 跑就写不进去）
mkdir -p napcat/config ntqq data
chown -R "$(id -u):$(id -g)" napcat ntqq data

docker compose up -d
```

验证：

```bash
docker compose ps
# napcat 和 astrbot 都应是 Up

# 等 AstrBot 起来（首次拉镜像要几分钟）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:6185/
# 期望 200 或 302

# 看资源占用 —— 2GB 机器要常看这个
docker stats --no-stream
```

---

## 4. 开 SSH 隧道

所有端口都绑在服务器的 `127.0.0.1` 上，**公网打不到**。这是刻意的安全设计。

在**你自己的电脑**上新开一个终端，**保持不关**：

```bash
ssh -N -L 6099:127.0.0.1:6099 -L 6185:127.0.0.1:6185 root@<服务器IP>
```

之后浏览器访问：

| 服务 | 本地地址 | 用途 |
|---|---|---|
| NapCat WebUI | http://127.0.0.1:6099/webui | 扫码登录 QQ |
| AstrBot 面板 | http://127.0.0.1:6185 | 配模型、插件、人设 |

---

## 5. 登录 QQ

```bash
cd /root/qqbot

# 取 NapCat 登录 token
docker compose logs napcat | grep -i token
```

浏览器打开 `http://127.0.0.1:6099/webui`，填 token，扫码登录。

**用你的小号，不要用主号。**

验证登录态已持久化：

```bash
ls -la ntqq/
# 应该有内容。空的说明挂载权限不对，重启会掉登录
```

---

## 6. 配置 AstrBot

```bash
# 取初始密码
docker compose logs astrbot | grep -i password
```

浏览器打开 `http://127.0.0.1:6185`：

1. 用初始密码登录，**立刻改密码**
2. **模型提供商 → 对话 → 新增 → DeepSeek**
   - API Key：粘贴你自己的 key
   - API Base URL：`https://api.deepseek.com/v1`
   - 保存并获取模型
3. **AI 配置 → 模型 → 对话模型**：选 **`deepseek-flash`**

   ⚠️ **必须是 `deepseek-flash`** —— 它是唯一支持图片的 DeepSeek 模型。
   换成 `deepseek-v4-pro` 会让图片识别失效。

4. **人格设置**：写你设计的人设

---

## 7. 安装三个插件

原理：Compose 把 `./data` 挂到了容器的 `/AstrBot/data`，AstrBot 从
`data/plugins/<目录名>/` 加载插件。所以把目录拷进去、容器里立刻可见，
**不用重建镜像，也不用重启容器**。

```bash
cd /root/qqbot

mkdir -p data/plugins
cp -r plugins/astrbot_plugin_balance_guard \
      plugins/astrbot_plugin_media_pacer \
      plugins/astrbot_plugin_reply_arbiter \
      data/plugins/

# 清掉可能带过来的旧字节码
rm -rf data/plugins/*/__pycache__

ls -1 data/plugins/
```

**关键校验** —— `metadata.yaml` 里的 `name` 必须与目录名完全一致，
否则 AstrBot 会拒绝加载：

```bash
for d in data/plugins/*/; do
  n=$(basename "$d")
  m=$(sed -n 's/^name:[[:space:]]*//p' "$d/metadata.yaml" | head -1 | tr -d '\r' | xargs)
  [ "$n" = "$m" ] && echo "OK   $n" || echo "FAIL $n (metadata name=$m)"
done
# 三行都应是 OK
```

确认容器内可见：

```bash
docker compose exec astrbot ls -1 /AstrBot/data/plugins
```

### 在面板里启用

打开 `http://127.0.0.1:6185` → **插件管理** → 点「重载插件」。

应该看到三个：

| 插件 | 显示名 |
|---|---|
| `astrbot_plugin_balance_guard` | 余额守护 |
| `astrbot_plugin_media_pacer` | 媒体节流 |
| `astrbot_plugin_reply_arbiter` | 回应仲裁 |

点进**余额守护**确认配置：

| 项 | 说明 |
|---|---|
| `api_key` | 已预填，需要就改 |
| `admin_qq` | 已预填，**必须与你的管理员 QQ 一致** |
| `red_line` | 余额红线，默认 `5.0` |
| `group_daily_token_limit` | 每群每日 token 上限，默认 `200000`（`0` = 不限） |

另两个插件默认值即可。

---

## 8. 验证

```bash
docker compose logs -f astrbot | grep -E "balance_guard|media_pacer|reply_arbiter"
```

应看到：

```
[balance_guard] 启动：红线 5.0 CNY，间隔 10 分钟
[media_pacer] 启动：图片桶容量 3 张，每 20 秒恢复 1 个
[reply_arbiter] 启动：合并窗口 2000ms，上下文回看 300s
```

在 QQ 里测试：

| 测试 | 预期 |
|---|---|
| 私聊说「你好」 | 直接回复（不需要 @） |
| 群里 @ 机器人 | 回复 |
| 群里不 @ 直接说话 | **完全不理** |
| 群里发语音 | 静默忽略 |
| 群里发视频 | 静默忽略 |
| 发一张图 | 识别并回复 |
| 连发 5 张图 | 前 3 张识别，后 2 张被忽略但**文字照常回复** |
| 两人同时 @ | 只有一个人得到回复 |

---

## 9. 余额红线测试（可选但推荐）

想确认熔断真的生效，临时把红线调到超过当前余额：

1. 面板 → 插件 → 余额守护 → `red_line` 改成 `99999`
2. 等一次轮询（或重载插件）
3. 发消息 → 应被拦住并收到告警
4. 改回正常值 → 发「余额恢复」→ 恢复

---

## 安全组检查（重要）

去**阿里云控制台 → 安全组**：

| 端口 | 应该 |
|---|---|
| 22 (SSH) | ✅ 放行 |
| 6099 (NapCat WebUI) | ❌ **不放行** |
| 6185 (AstrBot 面板) | ❌ **不放行** |
| 6199 (OneBot 通道) | ❌ **不放行**（本来就没发布） |

即使端口只绑了 `127.0.0.1`，安全组也不该放行 —— 双重保险。

---

## 日常运维

```bash
cd /root/qqbot

docker compose ps                        # 状态
docker compose logs -f astrbot           # 跟日志
docker compose restart astrbot           # 重启机器人
docker stats --no-stream                 # 看内存（2G 机器要常看）
free -h                                  # 内存 + swap
docker compose down && docker compose up -d   # 整体重启
```

### 更新插件

改完插件代码后重新拷贝并重载：

```bash
cp -r plugins/astrbot_plugin_xxx data/plugins/
rm -rf data/plugins/astrbot_plugin_xxx/__pycache__
# 然后在面板点「重载插件」
```

### 掉线了

QQ 被踢下线**不会自动恢复**，需要重新扫码：

```bash
docker compose restart napcat
# 然后重新走第 5 步
```

### 内存吃紧

如果 `docker stats` 显示某个容器长期贴着 900m 上限：

```bash
docker compose logs astrbot | tail -50    # 看有没有异常
docker compose restart astrbot
```

持续吃紧说明 2GB 确实不够，考虑升到 4GB。
