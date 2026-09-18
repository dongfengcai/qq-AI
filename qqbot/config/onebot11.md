# NapCat ↔ AstrBot 对接说明

## 好消息：基本不用手动配

官方 Compose 模板给 NapCat 设了 `MODE=astrbot`：

```yaml
environment:
  - MODE=astrbot
```

这个模式会**预置好 OneBot v11 的反向 WebSocket 连接**，指向 compose 网络里的
`astrbot` 服务。所以正常情况下：

```
NapCat ──反向 WS──▶ astrbot:6199/ws
```

**不需要你手填地址或 token。**

## 验证连接是否成功

```bash
# 看 NapCat 日志有没有建立连接
docker compose logs napcat | grep -i -E "websocket|connect|onebot"

# 看 AstrBot 是否报告适配器已连接
docker compose logs astrbot | grep -i -E "aiocqhttp|adapter|connected"
```

AstrBot 日志里出现类似 `aiocqhttp(OneBot v11) 适配器已连接` 就是通了。

## 如果没连上

先确认两个容器在同一个网络里：

```bash
docker compose ps
docker network inspect qqbot --format '{{range .Containers}}{{.Name}} {{end}}'
```

应该能看到 `napcat` 和 `astrbot` 两个名字。

### 手动配置（仅在自动模式失效时）

如果 `MODE=astrbot` 没生效，编辑 `napcat/config/onebot11_<QQ号>.json`：

```json
{
  "network": {
    "websocketClients": [
      {
        "name": "astrbot",
        "enable": true,
        "url": "ws://astrbot:6199/ws",
        "reportSelfMessage": false,
        "messagePostFormat": "array",
        "token": "<与 AstrBot 侧一致的 token>",
        "debug": false,
        "heartInterval": 30000,
        "reconnectInterval": 3000
      }
    ]
  }
}
```

然后在 AstrBot 面板：**机器人 → 创建机器人 → OneBot v11**

| 字段 | 值 |
|---|---|
| 反向 WebSocket 主机 | `0.0.0.0` |
| 反向 WebSocket 端口 | `6199` |
| Token | 与上面 JSON 里的 `token` 完全一致 |

⚠️ 注意 `url` 用的是 **`astrbot`（compose 服务名）**，不是 `127.0.0.1` ——
容器之间要用服务名解析，用 `127.0.0.1` 会指向 NapCat 自己。

## 为什么 6199 不发布到宿主机

`docker-compose.yml` 里**故意没有** `- "6199:6199"`。

OneBot 的反向 WS 是**控制通道**：连上它就能以机器人身份收发消息。
把它发布到公网等于把机器人控制权交出去（如果 token 弱或为空，更是直接沦陷）。

容器间通过 bridge 网络通信，这条路根本不经过宿主机端口。

## 登录 QQ 后要检查的事

1. **会话是否持久化**：`./ntqq` 目录里应该有内容

   ```bash
   ls -la ntqq/
   ```

   如果登录成功但这里为空，说明挂载权限不对（`NAPCAT_UID` 与实际不符），
   重启后会掉登录。

2. **掉线自动重连**：`restart: unless-stopped` 只管进程崩溃，
   QQ 被踢下线属于应用层事件，不会自动恢复 —— 需要重新扫码。

3. **内存占用**：NapCat 跑着完整的 QQ NT 客户端，比较吃内存

   ```bash
   docker stats --no-stream napcat
   ```

   在 2 GB 机器上，如果它长期超过 700 MB，考虑在 AstrBot 里减少消息处理量。
