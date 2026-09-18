# QQ 聊天机器人 · 部署方案

把 AI 接入 QQ 做**被动聊天**机器人，长期运行在 CentOS Stream 10 云服务器上
（2 核 / 2 GB / 3 Mbps）。

```
┌─ CentOS Stream 10 (2C2G) ────────────────────────────────┐
│                                                          │
│  ┌──────────────┐   OneBot   ┌───────────────────────┐  │
│  │  NapCat      │◀──(内部)──▶│  AstrBot              │  │
│  │  协议端       │            │  网关 + 插件           │  │
│  │  :6099 WebUI │            │  :6185 面板            │  │
│  └──────────────┘            └───────────┬───────────┘  │
│        仅回环绑定                    仅回环绑定          │
│                                          │              │
└──────────────────────────────────────────┼──────────────┘
                                           ▼
                          https://api.deepseek.com  (deepseek-flash)
```

## ⚠️ 开始之前必读

1. **用小号。** NapCat 是非官方 QQ 协议端，违反腾讯服务条款，**封号风险真实存在**。
2. **面板不对公网开放。** 所有端口绑 `127.0.0.1`，通过 SSH 隧道访问。
3. **API key 不要提交到任何仓库。** 它是通过 AstrBot 面板填写的，不落在这个目录里。
4. **2 GB 内存必须配 swap**，否则内存尖峰时机器人会被 OOM Killer 杀掉且不自知。

## 文件清单

| 文件 | 作用 |
|---|---|
| `docker-compose.yml` | NapCat + AstrBot，含内存上限与回环绑定 |
| `.env.example` | UID/GID 等部署变量（复制成 `.env`） |
| `DEPLOY.md` | **逐步部署清单，照着手动执行** |
| `config/onebot11.md` | NapCat 与 AstrBot 的对接说明 |
| `plugins/astrbot_plugin_balance_guard/` | **需求 1** + 每群每日 token 上限 |
| `plugins/astrbot_plugin_media_pacer/` | **需求 4/5**：图片识别限流 + 非文字图片跳过 |
| `plugins/astrbot_plugin_reply_arbiter/` | **需求 6/7**：多人 @ 时的回应仲裁 |

## 部署顺序

所有命令都在 `DEPLOY.md` 里，逐步复制执行即可。三步概览：

```bash
# ① 装 Docker（CentOS Stream 10 默认是 podman，需要装 docker-ce）
dnf -y install dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# ② 配 2G swap（2GB 内存上这是必做项，不是可选）
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ③ 起服务
cp .env.example .env
mkdir -p napcat/config ntqq data
docker compose up -d
```

完整步骤（含每步的验证方法）见 `DEPLOY.md`。

然后在**你自己的电脑**上开 SSH 隧道，保持这个终端不关：

```bash
ssh -N -L 6099:127.0.0.1:6099 -L 6185:127.0.0.1:6185 root@<服务器IP>
```

之后浏览器访问：

| 服务 | 本地地址 | 用途 |
|---|---|---|
| NapCat WebUI | http://127.0.0.1:6099/webui | 扫码登录 QQ |
| AstrBot 面板 | http://127.0.0.1:6185 | 配模型、插件、人设 |

### 初始凭据在哪

```bash
# NapCat 登录 token
docker compose logs napcat | grep -i token

# AstrBot 初始密码
docker compose logs astrbot | grep -i password
```

**首次登录后立刻改掉 AstrBot 密码。**

---

## 需求映射

| # | 需求 | 由谁实现 | 位置 |
|---|---|---|---|
| 1 | 余额检测 + 红线 + 触发后停止 | **`balance_guard` 插件** | 本目录 |
| 2 | 自由设计人设 | AstrBot 内置 | 面板 → 人格设置 |
| 3 | 防网络攻击 | **架构**（回环绑定 + SSH 隧道） | `docker-compose.yml` |
| 4 | 图片识别 + 间隔限流 | **`media_pacer` 插件** | 本目录 |
| 5 | 非文字/图片直接跳过 | **`media_pacer` 插件** | 本目录 |
| 6 | 被动聊天：群聊 @ / 私聊免 @ | AstrBot 内置 + 插件兜底 | 面板 → 群聊设置 |
| 7 | 多人 @ 时按上下文仲裁 | **`reply_arbiter` 插件** | 本目录 |

### 需求 2：人设（用面板改）

AstrBot 面板里有专门的人格配置，写自然语言描述即可，例如：

```
你叫小鲸，是一个住在群里的普通网友。
说话简短随意，像在手机上打字，不用书面语，不列清单，不说"作为一个AI"。
偶尔用表情，但不要每句都加。不懂的就说不懂，别硬答。
对熟人可以开玩笑，对陌生人客气一点。
```

写人设的要点：
- **说清楚"不要什么"** 比只说"要什么"更有效（比如禁止说"作为AI助手"）
- 描述**身份和关系**，不要写形容词堆砌
- 长人设会占用每轮 token，控制在几百字内

### 需求 3：关于"SQL 注入"

**这套架构里 SQL 注入几乎不是真实威胁** —— AstrBot 用 ORM，你不写 SQL。
真正会打穿服务器的是端口暴露和弱密码，所以防护做在架构层：

| 措施 | 已实施位置 |
|---|---|
| 所有端口绑 `127.0.0.1` | `docker-compose.yml` 的 `ports` |
| 6199（OneBot 控制通道）**完全不发布** | Compose 注释说明 |
| 访问走 SSH 隧道 | `DEPLOY.md` |
| 容器内存/CPU 上限 | `docker-compose.yml` |
| Docker 日志轮转（防磁盘满） | `DEPLOY.md` 的 Docker 安装步骤 |
| 插件不拼接 SQL、不外泄用户输入 | 三个插件的实现 |

**你还需要在阿里云控制台做一件事**：安全组里**只放行 SSH（22）**，
不要放行 6099 / 6185 / 6199。

---

## 运维速查

```bash
docker compose ps                       # 状态
docker compose logs -f astrbot          # 跟日志
docker compose restart astrbot          # 重启机器人
docker stats --no-stream                # 看内存占用（2G 机器要常看）
docker compose down && docker compose up -d   # 整体重启

free -h                                 # 内存 + swap 使用
```

**余额触红线后如何恢复**（需求 1 采用方案 B：停止回复但保留进程）：

1. 去 platform.deepseek.com 充值
2. 在 AstrBot 面板或 QQ 里发管理指令解除熔断
3. 具体指令见 `plugins/balance_guard/README.md`

---

## 已知风险与限制

| 项 | 说明 |
|---|---|
| 封号 | 非官方协议端，用小号，做好随时失效的准备 |
| 掉线需重扫码 | QQ 协议更新或风控后，`./ntqq` 里的会话可能失效，需重新扫码 |
| 视觉仅 flash | `deepseek-v4-pro` **不支持图片**，换模型会让识图失效 |
| 内存紧张 | 2 GB 属于刚好够，重启后建议 `docker stats` 看一眼 |
| 带宽 | 3 Mbps 够纯文字；群内大量图片会排队，`media_pacer` 有节流 |
