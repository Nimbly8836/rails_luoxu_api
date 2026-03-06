# rails_luoxu_api

基于 Rails + TDLib 的 Telegram 长连接后端（数据库持久化会话，重启自动恢复）。

## 1. 安装依赖

```bash
bundle install
```

## 2. 初始化数据库

```bash
bin/rails db:migrate
```

新增持久化表：
- `telegram_accounts`: TD 会话状态
- `telegram_account_profiles`: 登录账号资料与监听配置（`watched_chat_ids`）
- `telegram_chats`: 每个登录账号同步到的聊天基础信息（id/名称/头像/来源账号）
- `telegram_messages`: 监听到的消息内容（按账号+群+消息ID去重）
- `system_users`: 你的系统用户（认证）
- `system_user_chat_accesses`: 系统用户可见群组授权

## 3. 配置环境变量

```bash
export TELEGRAM_API_ID=123456
export TELEGRAM_API_HASH=your_api_hash
export TDLIB_LOG_LEVEL=1
export TDLIB_DATABASE_ENCRYPTION_KEY=your_db_encryption_key
```

可选：

```bash
export TDLIB_LIB_PATH=/absolute/path/to/lib/dir
export TDLIB_USE_TEST_DC=false
export TDLIB_SYSTEM_LANGUAGE_CODE=en
export TDLIB_DEVICE_MODEL="Rails Luoxu API"
export TDLIB_SYSTEM_VERSION="macOS"
export TDLIB_APP_VERSION="1.0"
```

说明：
- `TDLIB_LIB_PATH` 是目录路径，不是文件路径；目录内应包含 `libtdjson.dylib/.so/.dll`。
- 若不设置 `TDLIB_LIB_PATH`，项目会优先使用 `lib/libtdjson.*` 的目录。

## 4. 启动服务

```bash
bin/rails server
```

启动后会自动恢复数据库里 `enabled=true` 的 Telegram 账号连接。

## 5. API 调用流程

### 查询账号列表

```bash
curl http://127.0.0.1:3000/api/telegram/sessions
```

### 查询聊天列表（按 chat 去重，多个来源默认返回第一个来源）

```bash
curl http://127.0.0.1:3000/api/telegram/chats
```

### 创建会话

```bash
curl -X POST http://127.0.0.1:3000/api/telegram/sessions
```

返回示例：

```json
{
  "session_id": "uuid",
  "state": "wait_phone_number",
  "me": null,
  "error": null,
  "enabled": true,
  "use_test_dc": false
}
```

如需测试环境 DC：

```bash
curl -X POST "http://127.0.0.1:3000/api/telegram/sessions?use_test_dc=true"
```

### 提交手机号

```bash
curl -X POST http://127.0.0.1:3000/api/telegram/sessions/<session_id>/phone \
  -H "Content-Type: application/json" \
  -d '{"phone_number":"+8613800000000"}'
```

### 提交短信验证码

```bash
curl -X POST http://127.0.0.1:3000/api/telegram/sessions/<session_id>/code \
  -H "Content-Type: application/json" \
  -d '{"code":"12345"}'
```

### 提交 2FA 密码（如开启）

```bash
curl -X POST http://127.0.0.1:3000/api/telegram/sessions/<session_id>/password \
  -H "Content-Type: application/json" \
  -d '{"password":"your_2fa_password"}'
```

### 查询状态

```bash
curl http://127.0.0.1:3000/api/telegram/sessions/<session_id>
```

当 `state=ready` 时，`me` 会返回当前账号信息。

### 配置该账号监听的群组列表

```bash
curl -X PATCH http://127.0.0.1:3000/api/telegram/sessions/<session_id>/watch_targets \
  -H "Content-Type: application/json" \
  -d '{"chat_ids":[-1001234567890,-1009999999999]}'
```

配置结果在返回字段 `profile.watched_chat_ids`。  
配置后会立即回填最近消息到 `telegram_messages`，并持续监听新消息入库。

### 手动同步该账号的聊天列表（登录成功后也会自动同步）

```bash
curl -X POST "http://127.0.0.1:3000/api/telegram/sessions/<session_id>/sync_chats?limit=500"
```

返回会包含 `sync` 字段，例如：
- `total_chat_ids`: 本次拿到的 chat id 数量
- `upserted`: 成功写入/更新数量
- `failed`: 失败数量
- `errors`: 失败明细（含 TD 返回信息）
- `from_get_chats` / `from_search_chats` / `from_search_chats_on_server`: 各阶段命中数量
- `from_updates_cache`: 如果 API 阶段全空，更新流已入库的聊天数量

### 手动回填该账号监听群组的消息到 `telegram_messages`

不传 `chat_ids` 时，默认使用该账号的 `profile.watched_chat_ids`。

```bash
curl -X POST http://127.0.0.1:3000/api/telegram/sessions/<session_id>/sync_messages \
  -H "Content-Type: application/json" \
  -d '{"wait_seconds":0.2}'
```

说明：
- `chat_id` 是按群逐个拉取（每次请求一个群），接口会对每个群循环分页直到拉完。
- `message_limit` 不传时表示尽量拉全量；传了就按每群上限截断。

## 6. 系统用户认证与搜索

### 管理员创建系统用户（仅管理员可调用）

```bash
curl -X POST http://127.0.0.1:3000/api/auth/register \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <admin_token>" \
  -d '{"username":"u1","password":"pass123456","admin":false,"chat_ids":[-1001234567890]}'
```

说明：
- `chat_ids` 只能填写“已监听群组”，即所有 `telegram_account_profiles.watched_chat_ids` 的并集。
- 普通用户无法自行注册或修改自己的群组权限。

### 登录获取 token

```bash
curl -X POST http://127.0.0.1:3000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"u1","password":"pass123456"}'
```

### 查看当前用户可见群组（需要 Bearer Token）

```bash
curl http://127.0.0.1:3000/api/me/chats \
  -H "Authorization: Bearer <token>"
```

### 搜索消息（需要 Bearer Token）

```bash
curl "http://127.0.0.1:3000/api/me/search/messages?q=hello&chat_id=-1001234567890&limit=50" \
  -H "Authorization: Bearer <token>"
```

### 初始化首个管理员（一次性）

```bash
bin/rails runner "u = SystemUser.find_or_create_by!(username: 'admin') { |x| x.password = 'pass123456'; x.password_confirmation = 'pass123456' }; u.update!(admin: true); puts u.api_token"
```

### 销毁会话

```bash
curl -X DELETE http://127.0.0.1:3000/api/telegram/sessions/<session_id>
```

销毁后会把账号置为 `enabled=false`，并断开 TD 客户端。

## 当前版本推荐 TD.configure

`tdlib-ruby 3.1.0` 推荐配置（已在 `config/initializers/td.rb` 实现）：

```ruby
TD.configure do |config|
  config.lib_path = ENV.fetch("TDLIB_LIB_PATH", Rails.root.join("lib").to_s)
  config.encryption_key = ENV["TDLIB_ENCRYPTION_KEY"] # gem 当前版本不会自动注入 setTdlibParameters

  config.client.api_id = ENV.fetch("TELEGRAM_API_ID").to_i
  config.client.api_hash = ENV.fetch("TELEGRAM_API_HASH")
  config.client.use_test_dc = ActiveModel::Type::Boolean.new.cast(ENV.fetch("TDLIB_USE_TEST_DC", "false"))

  # 全局默认目录；多账号会在运行时覆写为 storage/tdlib/<uuid>/db 和 files
  config.client.database_directory = Rails.root.join("storage", "tdlib", "default", "db").to_s
  config.client.files_directory = Rails.root.join("storage", "tdlib", "default", "files").to_s

  config.client.use_file_database = true
  config.client.use_chat_info_database = true
  config.client.use_secret_chats = true
  config.client.use_message_database = true
  config.client.system_language_code = ENV.fetch("TDLIB_SYSTEM_LANGUAGE_CODE", "en")
  config.client.device_model = ENV.fetch("TDLIB_DEVICE_MODEL", "Rails Luoxu API")
  config.client.system_version = ENV.fetch("TDLIB_SYSTEM_VERSION", RUBY_PLATFORM)
  config.client.application_version = ENV.fetch("TDLIB_APP_VERSION", "1.0")
end
```

注意：
- `database_encryption_key` 需要通过 `TD::Client.new(database_encryption_key: ...)` 传入，本项目通过 `TDLIB_DATABASE_ENCRYPTION_KEY` 在运行时注入。
- 你给出的 `enable_storage_optimizer` / `ignore_file_names` 在 `tdlib-ruby 3.1.0` 的 `TD.configure` 客户端设置里不可用。
