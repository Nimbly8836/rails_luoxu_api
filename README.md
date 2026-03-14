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

### Step 2) 准备环境变量

创建 `.env`（供 docker compose 使用）：

```bash
cat > .env <<'ENV'
RAILS_MASTER_KEY=replace_with_your_master_key
DATABASE_URL=postgres://rails_luoxu_api:replace_with_db_password@postgres:5432/rails_luoxu_api_production
POSTGRES_DB=rails_luoxu_api_production
POSTGRES_USER=rails_luoxu_api
POSTGRES_PASSWORD=replace_with_db_password
# 可选：compose 默认使用 PGroonga 镜像；如需固定版本可覆盖
# POSTGRES_IMAGE=pgroonga/pgroonga:your-tag
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

容器启动时会自动执行 `bin/rails db:prepare`。

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
- `DATABASE_URL`：生产数据库连接（当前项目 production 配置优先使用它）。
- `TDLIB_DATABASE_ENCRYPTION_KEY`：可选。只有你启用 TDLib 数据库加密时才需要。
- TDLib 动态库（Docker/Linux）：
  - 需要在项目 `lib/` 目录提供 Linux 的 `libtdjson` 文件。
  - 优先按架构读取：
    - `lib/libtdjson-amd64_linux.so*`（x86_64）
    - `lib/libtdjson-aarch64_linux.so*`（arm64）
  - 若找不到架构文件，则回退 `lib/libtdjson.so*`。
  - 构建时会复制为标准文件名 `lib/libtdjson.so`（`tdlib-ruby` 固定加载这个名字）。
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
