# rails_luoxu_api

基于 Rails + TDLib 的 Telegram 长连接后端。

## 1. 从零开始运行（Docker / Production）

前提：
- 已安装 Docker 和 Docker Compose
- 项目根目录有 `Dockerfile`

### Step 1) 准备 Rails credentials（只做一次）

如果仓库里还没有 `config/credentials.yml.enc`，先创建。

方式 A（本机已装 Ruby/Bundler）：

```bash
EDITOR=vim bin/rails credentials:edit
```

方式 B（本机没有 Ruby，纯 Docker）：

```bash
docker build -t rails_luoxu_api .

docker run --rm -it \
  -v "$PWD":/rails \
  -w /rails \
  rails_luoxu_api \
  bash -lc 'EDITOR="ruby -e \"p=ARGV[0]; File.write(p, %q(telegram:\n  api_id: 123456\n  api_hash: your_api_hash\n  encryption_key: \\\"\\\"\n))\"" bin/rails credentials:edit'
```

会自动生成：
- `config/credentials.yml.enc`
- `config/master.key`

在 credentials 里至少写入 Telegram 参数（示例）：

```yaml
telegram:
  api_id: 123456
  api_hash: your_api_hash
  encryption_key: ""
```

说明：
- 你如果没有启用 TDLib 加密，`encryption_key` 可以留空字符串。
- 生产数据库连接请走 `DATABASE_URL`（见下一步），不要依赖 `credentials.db`。
- 如果 credentials 里没有 `secret_key_base`，需要通过 `SECRET_KEY_BASE` 环境变量提供。

### Step 2) 准备环境变量

创建 `.env`（供 docker compose 使用）：

```bash
cat > .env <<'ENV'
RAILS_MASTER_KEY=replace_with_your_master_key
SECRET_KEY_BASE=replace_with_generated_secret_key_base
DATABASE_URL=postgresql://rails_luoxu_api:replace_with_db_password@postgres:5432/rails_luoxu_api_production
POSTGRES_DB=rails_luoxu_api_production
POSTGRES_USER=rails_luoxu_api
POSTGRES_PASSWORD=replace_with_db_password
# 可选：compose 默认使用 PGroonga 镜像；如需固定版本可覆盖
# POSTGRES_IMAGE=groonga/pgroonga:your-tag
# 本地目录挂载（bind mount）
POSTGRES_DATA_DIR=./.docker/postgres
RAILS_STORAGE_DIR=./.docker/storage
# 可选：如果不放在 credentials，也可以直接用环境变量传 Telegram 参数
# TELEGRAM_API_ID=123456
# TELEGRAM_API_HASH=your_api_hash
# 可选：未启用加密时可不填
# TDLIB_DATABASE_ENCRYPTION_KEY=
ENV
```

如果你还没有 `SECRET_KEY_BASE`，可先生成一个：

```bash
openssl rand -hex 64
```

创建本地挂载目录：

```bash
mkdir -p ./.docker/postgres ./.docker/storage
```

如果你使用外部 PostgreSQL（不使用 compose 里的 `postgres` 服务）：
- 在 `docker-compose.yml.example` 里注释掉 `postgres` 服务。
- 同时删除 `app` 下的 `depends_on`。
- `DATABASE_URL` 指向你已有的数据库。

### Step 3) 启动

```bash
docker compose -f docker-compose.yml.example up -d
```

容器启动时会自动执行 `bin/rails db:prepare`，并通过 `Procfile.prod` 拉起 Web；Solid Queue 会以内嵌 async 模式运行在 Puma 进程内，不再单独起 `jobs` 进程。

### Step 4) 初始化首个管理员（一次性）

```bash
docker compose -f docker-compose.yml.example exec app \
  bin/rails runner "u = SystemUser.find_or_create_by!(username: 'admin') { |x| x.password = 'pass123456'; x.password_confirmation = 'pass123456' }; u.update!(admin: true, active: true); puts u.api_token"
```

执行后会输出 `api_token`。

### Step 5) 验证服务

```bash
curl http://127.0.0.1/up
```

## 2. 运行细节

- `RAILS_MASTER_KEY`：用于解密 `config/credentials.yml.enc`。
- `SECRET_KEY_BASE`：如果没有放进 credentials，生产环境必须显式提供。
- `DATABASE_URL`：生产数据库连接（当前项目 production 配置优先使用它）。
- `TDLIB_DATABASE_ENCRYPTION_KEY`：可选。只有你启用 TDLib 数据库加密时才需要。
- TDLib 动态库（Docker/Linux）：
  - Docker 构建阶段会从 TDLib 源码自动编译 `libtdjson.so` 并打包进镜像。
  - 默认使用 TD commit `9b6ff5863`，可用 `--build-arg TDLIB_COMMIT=<commit>` 覆盖。
- 本地目录挂载（默认）：
  - `POSTGRES_DATA_DIR` -> `/var/lib/postgresql/data`
  - `RAILS_STORAGE_DIR` -> `/rails/storage`

常用命令：

```bash
# 查看日志
docker compose -f docker-compose.yml.example logs -f app

# 停止
docker compose -f docker-compose.yml.example down

# 停止并清理（含数据库卷）
docker compose -f docker-compose.yml.example down -v
```

## 3. 文档

- API 文档：`docs/api.md`
- 路由文档：`docs/api_routes.md`
- 开发文档：`docs/development.md`
