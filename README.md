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
