# unfairplay-bot

英文说明见 [README.md](README.md)。

这是一个私有的 Telegram 机器人和 HTTP 服务。给它一个 App Store 的 `bundle_id` 或 `app_id`，它用 [ipatool](https://github.com/majd/ipatool) 下载商店当前提供的安装包，用 [UnfairPlay](https://github.com/DrWhax/unfairplay) 解密，再返回一个带签名、会过期的下载链接。

只处理这个账号合法获得的应用。解密后的 IPA 和链接都是私有的。

## 工作方式

- **任务。** `POST /v1/tasks` 创建一个任务。同时最多跑 3 个（`UNFAIRPLAY_BOT_CONCURRENCY`），其余按 FIFO 排队，并报告自己的队列位置。解密另有并发限制（`UNFAIRPLAY_BOT_DECRYPT_CONCURRENCY`，默认 1）。
- **进度。** 阶段是 `queued → downloading → patching → waiting_decrypt → decrypting → finalizing → ready`（或 `failed` / `canceled`）。下载过程中会报告已下载字节、总大小、百分比、速度和剩余时间。用 `GET /v1/tasks/{id}/events`（Server-Sent Events）跟踪，或轮询 `GET /v1/tasks/{id}`。
- **只命中当前构建。** 每次请求都先问 App Store 下载接口要最新的 external version ID，不依赖可能滞后的 iTunes lookup API。缓存键是 `trackId:externalVersionId`。商店从 8.0.79 变成 8.0.80 时，下一次请求未命中，并下载 8.0.80。同一个应用用 `bundle_id` 或 `app_id` 请求，共用这份缓存。
- **去重。** 提交一个已经在排队或正在处理的构建，会返回已有的任务。
- **过期。** 产物在最近一次命中后保留 24 小时（`UNFAIRPLAY_BOT_CACHE_TTL`）。命中包括 API 缓存命中，以及不带 `Range` 的完整下载。签名链接在签发时的过期时间之前有效；要新链接就再请求一次这个应用。`UNFAIRPLAY_BOT_MAX_CACHE_BYTES` 可选，用来限制磁盘占用，先淘汰最久没有命中的产物。

## Telegram 机器人

设置 `UNFAIRPLAY_BOT_TELEGRAM_TOKEN` 和 `UNFAIRPLAY_BOT_TELEGRAM_ADMIN_IDS`。机器人使用长轮询，不需要公网 webhook。它只在私聊里回答。

- **先确认。** 发送 App ID、bundle ID 或 App Store 链接。机器人回复名称、开发者、当前版本和发布日期、大小、价格，以及这个构建是否已缓存。用户在 10 分钟内点 **✅** 之后才会入队。
- **搜索。** `/search <名称>` 按这个 Apple ID 的店面列出最多 10 个结果，点一条会打开同样的预览。搜索和预览都不会把应用加进 Apple ID，只有点 **✅** 之后才会。
- **每个任务一条消息。** 确认消息会变成进度：队列位置、带速度和剩余时间的下载条、解密，然后是下载按钮。用户可以取消自己的任务，管理员可以取消任何一个。
- **白名单。** 管理员始终有权限。其他人会收到自己的 Telegram ID 和「无权限」回复，管理员会收到一条访问申请，带 **✅ Allow** / **🚫 Ignore**（同一个人最多每 6 小时一次）。管理员命令：`/allow <id> [备注]`、`/revoke <id>`、`/users`（可一键移除）、`/status`（Apple 账号、队列、缓存、版本、进行中的任务）、`/health`（`ipatool auth info` 的内容、会话和自动登录状态，以及一次实时的 App Store 请求）、`/clear`（确认后删除全部已缓存的 IPA，不论是否到期；已经发出的链接失效，进行中的任务不受影响）。白名单文件在数据目录下的 `telegram-allowlist.json`：Docker 部署是 `./data/telegram-allowlist.json`，systemd 部署是 `/var/lib/unfairplay-bot/data/telegram-allowlist.json`。
- **管理员通知。** 非管理员的每次请求（新任务、加入进行中的任务、缓存命中）以及每次完成、失败或取消，都会发给管理员。通知用 `🔔 Notice · …` 标题和引用块，和回复管理员自己的请求区分开。管理员自己的请求不发通知。Apple 会话失效时见下面的「App Store 健康检查」。
- **`/login`（仅管理员）。** 用配置的（或已保存的）凭据重新登录 App Store。如果 Apple 要求两步验证码，只有发送 `/login` 的那位管理员能在 10 分钟内回复 6 位数字。

## API

所有 `/v1` 接口都要 `Authorization: Bearer $TOKEN`。EventSource 不能设置请求头，可以改用 `?token=`。

```sh
# 创建任务，或复用已有任务。
curl -s -H "Authorization: Bearer $TOKEN" -d '{"bundle_id":"com.example.app"}' \
  https://ipa.example.com/v1/tasks
# 也可以是 {"app_id": 123456789}。

# 实时跟踪进度。
curl -N -H "Authorization: Bearer $TOKEN" https://ipa.example.com/v1/tasks/$ID/events
```

| 响应 | 含义 |
|---|---|
| `200 {"cached": true, "artifact": {...}}` | 当前构建已缓存，`artifact.download_url` 可以直接用 |
| `201 {"cached": false, "task": {...}}` | 新任务已入队 |
| `200 {"cached": false, "task": {...}}` | 同一构建已在处理，返回已有任务 |
| `429 queue_full` | 进行中加排队已达到 `CONCURRENCY + MAX_QUEUE` |
| `503 auth_required` | ipatool 会话不可用，需要重新登录（见下文） |
| `503 draining` | 服务正在停机排空，稍后再试 |
| `403 license_required` | 付费应用尚未被这个账号购买 |
| `403 subscription_required` | 这个应用需要订阅才能下载 |

每条 SSE 事件是 `event: task`，数据是完整的任务 JSON。状态变成 `ready`、`failed` 或 `canceled` 后流结束。等待期间大约每 15 秒有一条 `: ping` 注释。

```json
{"id":"…","status":"downloading","app":{"app_id":123,"bundle_id":"com.example.app","external_version_id":"870123456"},
 "progress":{"bytes":734003200,"total":2147483648,"percent":34.2,"speed_bps":18500000,"eta_seconds":76}}
```

`ready` 的任务带有 `artifact.download_url`。其他接口：`GET /v1/tasks`，`DELETE /v1/tasks/{id}`（取消，返回 `202`），`GET /v1/status`（队列、缓存、依赖版本、健康状态），`GET /healthz`。下载链接（`/d/...`）不需要 token，支持 `Range`。不带 `Range` 的完整下载会计一次缓存命中；`Range` 请求不计。

## 部署（Docker Compose）

`compose.yaml` 同时写了镜像名和本地构建。`ghcr.io/annihilater/unfairplay-bot:latest` 要等这个仓库的 CI 发布之后才能拉取。第一次部署用源码构建。

必填环境变量（写在 `.env`，systemd 则写在 `/etc/unfairplay-bot/env`）：

| 变量 | 要求 |
|---|---|
| `UNFAIRPLAY_BOT_PUBLIC_URL` | 对外的 HTTPS 地址，不要末尾斜杠 |
| `UNFAIRPLAY_BOT_API_TOKEN` | 至少 16 个字符 |
| `UNFAIRPLAY_BOT_SIGNING_KEY` | 至少 32 个字符 |
| `UNFAIRPLAY_BOT_MODEL` | 容器内是 `/secrets/models`，由镜像默认设置 |
| `UNFAIRPLAY_BOT_KEYCHAIN_PASSPHRASE` | ipatool 钥匙串口令 |

开 Telegram 时还要 `UNFAIRPLAY_BOT_TELEGRAM_TOKEN` 和至少一个 `UNFAIRPLAY_BOT_TELEGRAM_ADMIN_IDS`。`UNFAIRPLAY_BOT_APPLE_ID_EMAIL` 和 `UNFAIRPLAY_BOT_APPLE_ID_PASSWORD` 要成对设置，或者都不设。其余项见 `.env.example`，未设置时使用代码里的默认值。

```sh
git clone https://github.com/Annihilater/unfairplay-bot /opt/unfairplay-bot
cd /opt/unfairplay-bot
cp .env.example .env            # 填好上面的值
mkdir -p data ipatool cache secrets/models canary
cp /path/to/your-model.bin secrets/models/
sudo chown -R 10001:10001 data ipatool cache secrets
# UnfairPlay 拒绝组或其他用户可读的模型和模型目录。
sudo chmod 700 secrets/models && sudo chmod 600 secrets/models/*.bin
docker compose up -d --build

# 设置了 UNFAIRPLAY_BOT_APPLE_ID_* 时，服务会自己登录。两步验证账号可以给机器人发 /login，
# 或在容器里登录：
# docker compose exec -it bot ipatool auth login --email you@example.com \
#   --keychain-passphrase "$UNFAIRPLAY_BOT_KEYCHAIN_PASSPHRASE"
```

镜像已经发布到 GHCR 之后，更新由下面的 timer 拉取。只使用镜像、不在本机构建时，在放有 `compose.yaml`、`.env` 和 `deploy/` 的目录执行 `docker compose pull && docker compose up -d --no-build`。

`secrets/models` 是 UnfairPlay 的模型目录，可以放多个 `.bin`，UnfairPlay 按每个 IPA 选择匹配的模型。再复制一个 `.bin` 进去即可，不用重启。

在 `127.0.0.1:8080` 前面放一层带 TLS 的反向代理。SSE 需要关闭响应缓冲（服务对 nginx 会发送 `X-Accel-Buffering: no`）。

compose 文件固定了容器 MAC 地址，因为 ipatool 用它派生 App Store 设备 GUID。登录之后不要再改。

## 凭据

服务需要两份分开的私有凭据：

| | UnfairPlay 模型（`.bin`） | ipatool 会话 |
|---|---|---|
| 用途 | 解密 IPA | 登录 App Store 并下载 |
| 怎么来 | 在已注册的 Mac 上运行 `unfairplay setup` | 服务自己用 `UNFAIRPLAY_BOT_APPLE_ID_EMAIL` / `_PASSWORD` 登录，或执行 `ipatool auth login` |
| 能否拷到另一台机器 | **能。** 安全地复制文件；解密是离线的 | **不能。** 在 macOS 上它在系统钥匙串里；到服务器上要重新登录 |
| 过期 | 不会过期 | App Store token 会过期；服务会自动再登录 |

两份凭据必须属于同一个 Apple ID：模型解密的是这个账号下载的 IPA。

**自动登录**（没有两步验证的账号）：`.env` 里配置了 Apple ID 时，服务在第一次启动，以及会话缺失、作废或过期时登录。自动尝试至少间隔 15 分钟。连续失败达到 `UNFAIRPLAY_BOT_AUTO_LOGIN_MAX_ATTEMPTS`（默认 3）次后，自动登录停止，避免错误密码或 Apple 已不再接受的登录流程把账号锁住。计数保存在数据目录的 `auto-login.json`（Docker 是 `./data/auto-login.json`，systemd 是 `/var/lib/unfairplay-bot/data/auto-login.json`），重启后仍然有效，任何一次成功登录后清零。手动 `/login` 始终允许。

## App Store 健康检查

最可能的故障在 App Store 一侧：会话丢失，或者 Apple 改了 ipatool 依赖的登录或下载 API。把 `UNFAIRPLAY_BOT_HEALTH_APP_ID` 设成这个账号拥有的一个免费应用后，服务每隔 `UNFAIRPLAY_BOT_HEALTH_INTERVAL`（30 分钟）向 App Store 查询它的最新版本。这和下载开始时的请求相同，只是不传文件。任何任务或预览在 App Store 一侧失败，都会立刻再查一次。

检查开始失败时，管理员收到一条通知（含错误，以及该怎么做：会话问题用 `/login`，API 变化则等 ipatool 自动更新）；恢复时再收到一条。`/status` 和 `GET /v1/status` 显示当前状态。

## 部署（systemd，不用 Docker）

有些机器不适合用 Docker（例如不能改 iptables 的路由器）。`deploy/systemd/` 在本机编译并运行。需要 Go（`go.mod` 里的版本或更新）、gcc、git 和 Caddy。

```sh
useradd --system --home-dir /var/lib/unfairplay-bot --shell /usr/sbin/nologin unfairplay
install -d -o unfairplay -g unfairplay -m 700 /var/lib/unfairplay-bot/{,data,models,canary}
install -m 600 your-model.bin /var/lib/unfairplay-bot/models/ && chown unfairplay: /var/lib/unfairplay-bot/models/*
install -d -m 700 /etc/unfairplay-bot     # 把 .env.example 里的配置写到 /etc/unfairplay-bot/env（0600）
git clone https://github.com/Annihilater/unfairplay-bot /opt/unfairplay-bot/src
cp /opt/unfairplay-bot/src/deploy/systemd/*.service /opt/unfairplay-bot/src/deploy/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable unfairplay-bot unfairplay-bot-update.timer
/opt/unfairplay-bot/src/deploy/systemd/update.sh   # 第一次编译并启动
systemctl start unfairplay-bot-update.timer
```

`update.sh` 每小时运行：构建最新的 `main`（含 CI 提交的依赖升级），跑测试，再做和 Docker 更新器相同的两项金丝雀检查，然后切换 `current` 符号链接，并在空闲时重启。用 `deploy/systemd/Caddyfile` 对外提供服务。单元文件把监听固定在 `127.0.0.1:8080`，模型目录固定为 `/var/lib/unfairplay-bot/models`，数据目录固定为 `/var/lib/unfairplay-bot/data`。

## 依赖自动更新

`deps.env` 规定每个依赖怎么跟踪：`main`、`release` 或 `prerelease`。ipatool 的版本钉在 `go.mod`，UnfairPlay 钉在 `deps.env`。

1. `.github/workflows/update-deps.yml` 每 6 小时运行一次。它解析允许范围内的最新版本（`scripts/update-deps.sh`），跑 vet 和 race 测试，构建两个 CLI，提交这次升级，并发布 `ghcr.io/annihilater/unfairplay-bot:latest`。用 `GITHUB_TOKEN` 推送的提交不会触发其他 workflow，所以镜像在这个 workflow 里构建。
2. 服务器上，`deploy/unfairplay-bot-update.timer` 每小时运行 `deploy/update.sh`。它拉取镜像，并用新镜像做两项金丝雀检查，通过后才切换：
   - **App Store：** 在正在运行的容器的网络命名空间里执行 `unfairplay-bot check`，这样 MAC 地址（ipatool 的设备身份）不变。它从不登录。当前版本健康而这次检查失败时，拒绝更新。
   - **UnfairPlay：** 用私有模型对 `./canary` 里的一个 IPA 离线执行 `unfairplay verify`。

   没设置 `UNFAIRPLAY_BOT_HEALTH_APP_ID`，或 `canary/` 里没有 `.ipa` 时，对应的检查只打印警告并跳过，更新继续。当前版本已经不健康时，新版本的 App Store 检查失败也会直接切换。两项都通过（或被跳过）后，更新器等机器人空闲再重启。服务收到 SIGTERM 时也会把排队和正在运行的任务排空。

```sh
sudo cp deploy/unfairplay-bot-update.* /etc/systemd/system/
sudo systemctl enable --now unfairplay-bot-update.timer
```

公开的 CI 不能测试真实下载或解密，因为那需要私有会话和模型。金丝雀检查是这道门。

## 开发

```sh
go vet ./... && go test -race ./...
```

Linux 构建需要 cgo（ipatool 的钥匙串依赖）。在 Linux 上构建，或使用 Dockerfile。不要从 macOS 交叉编译。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。Docker 镜像里还包含 [ipatool](https://github.com/majd/ipatool) 和 [UnfairPlay](https://github.com/DrWhax/unfairplay)，它们仍使用各自的许可证。
