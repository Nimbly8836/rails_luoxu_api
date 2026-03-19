# API

本文档基于当前代码实现整理，覆盖认证、用户权限、Telegram 会话管理、聊天查询与消息搜索接口。

## 约定

### Base URL

- 本地开发：`http://127.0.0.1:3000`
- Docker / 生产：按你的网关地址替换，例如 `http://127.0.0.1`

### 鉴权

- 除 `POST /api/auth/login` 外，所有接口默认都要求：

```http
Authorization: Bearer <api_token>
```

- 需要管理员权限的接口会额外校验 `current_system_user.admin?`。

### 请求格式

- JSON Body 请求请带上：

```http
Content-Type: application/json
```

- 当前接口参数都接收顶层 JSON 字段，不要求额外包一层对象。

### 通用错误响应

| HTTP 状态码 | 场景 | 响应体 |
|---|---|---|
| `401` | 未登录、Token 无效、用户已停用 | `{ "error": "Unauthorized" }` |
| `403` | 已登录但无管理员权限 | `{ "error": "Forbidden" }` |
| `404` | 资源不存在 | 一般为 `{ "error": "..." }`，少数接口为空响应体 |
| `422` | 参数错误、状态错误、业务校验失败 | `{ "error": "..." }` |

### 常见对象

#### SystemUser Payload

```json
{
  "user_id": 1,
  "username": "admin",
  "admin": true,
  "active": true,
  "chat_ids": [-1001234567890],
  "watched_chats": [
    {
      "td_chat_id": -1001234567890,
      "title": "Test Group",
      "chat_type": "supergroup"
    }
  ]
}
```

- 登录和注册成功时会额外返回 `token` 字段。

#### Telegram Chat Payload

```json
{
  "td_chat_id": -1001234567890,
  "title": "Test Group",
  "chat_type": "supergroup",
  "avatar_small_content_type": "image/jpeg",
  "avatar_small_base64": "BASE64...",
  "source_session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "source_count": 2
}
```

#### Telegram Session Snapshot

```json
{
  "session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "state": "wait_phone_number",
  "me": null,
  "profile": null,
  "error": null,
  "enabled": true,
  "use_test_dc": false,
  "connected_at": null,
  "chat_count": 0,
  "updated_at": "2026-03-16T02:00:00.000Z"
}
```

## Auth

### POST `/api/auth/login`

- 鉴权：否
- 说明：用户名密码登录，返回 API Token

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `username` | string | 是 | 用户名 |
| `password` | string | 是 | 密码 |

示例：

```bash
curl -X POST http://127.0.0.1/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{
    "username": "admin",
    "password": "pass123456"
  }'
```

成功响应示例：

```json
{
  "user_id": 1,
  "username": "admin",
  "admin": true,
  "active": true,
  "chat_ids": [-1001234567890],
  "watched_chats": [
    {
      "td_chat_id": -1001234567890,
      "title": "Test Group",
      "chat_type": "supergroup"
    }
  ],
  "token": "9dd5c0..."
}
```

失败响应：

```json
{ "error": "Invalid username or password" }
```

### POST `/api/auth/register`

- 鉴权：是，且必须管理员
- 说明：创建系统用户，并可选初始化可访问群组

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `username` | string | 是 | 新用户名 |
| `password` | string | 是 | 登录密码 |
| `password_confirmation` | string | 否 | 不传时默认等于 `password` |
| `admin` | boolean | 否 | 是否管理员 |
| `chat_ids` | integer[] | 否 | 用户可访问的群组 ID 列表 |

说明：

- `chat_ids` 里的群必须已经存在于 `telegram_chats`。
- 如果新增了群权限，会自动追加到对应 Telegram 账号的监听关系，并尝试触发历史消息同步。

### GET `/api/auth/users`

- 鉴权：是，且必须管理员
- 说明：返回系统用户列表

成功响应示例：

```json
[
  {
    "user_id": 1,
    "username": "admin",
    "admin": true,
    "active": true,
    "chat_ids": [-1001234567890],
    "watched_chats": [
      {
        "td_chat_id": -1001234567890,
        "title": "Test Group",
        "chat_type": "supergroup"
      }
    ]
  }
]
```

### PATCH `/api/auth/users/:id/chat_ids`

- 鉴权：是，且必须管理员
- 说明：维护已有用户可访问群组，支持全量覆盖或增删

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `chat_ids` | integer[] | 否 | 全量覆盖用户权限 |
| `add_chat_ids` | integer[] | 否 | 追加权限 |
| `remove_chat_ids` | integer[] | 否 | 移除权限 |

说明：

- `chat_ids` 存在时，按全量覆盖处理。
- 否则按 `add_chat_ids` / `remove_chat_ids` 增删。
- 兼容嵌套参数：`auth.chat_ids`、`auth.add_chat_ids`、`auth.remove_chat_ids`。
- 如果请求里既没有 `chat_ids`，也没有增删参数，会返回 `422`。

示例：

```bash
curl -X PATCH http://127.0.0.1/api/auth/users/2/chat_ids \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "add_chat_ids": [-1001234567890],
    "remove_chat_ids": [-1005555555555]
  }'
```

## Me

### GET `/api/me/chats`

- 鉴权：是
- 说明：返回当前用户有权限访问的群聊列表

成功响应示例：

```json
[
  {
    "td_chat_id": -1001234567890,
    "title": "Test Group",
    "chat_type": "supergroup",
    "avatar_small_content_type": "image/jpeg",
    "avatar_small_base64": "BASE64...",
    "source_session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
    "source_count": 2
  }
]
```

### GET `/api/me/chats/:chat_id`

- 鉴权：是
- 说明：查询单个群详情，仅允许访问当前用户有权限的群

路径参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `chat_id` | integer | 是 | TDLib 群 ID |

注意：

- 无权限时返回 `403`，响应体为空。
- 有权限但数据库里找不到该群时返回 `404`，响应体为空。
- 查询前会尝试触发一次群资料刷新。

### GET `/api/me/chats/:chat_id/members`

- 鉴权：是
- 说明：查询群成员列表，仅允许访问当前用户有权限的群

查询参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `q` | string | 否 | 按 `name/username` 搜索；纯数字时也匹配 `uid` |
| `page` | integer | 否 | 页码，默认 `1` |
| `per_page` | integer | 否 | 每页数量，范围 `1..200`，默认 `20` |
| `limit` | integer | 否 | `per_page` 别名 |

成功响应：

```json
{
  "page": 1,
  "per_page": 20,
  "total": 1,
  "items": [
    {
      "uid": 123456,
      "group_id": -1001234567890,
      "name": "Alice",
      "username": "alice",
      "last_seen": "2026-03-16T01:00:00.000Z",
      "avatar_small_content_type": "image/jpeg",
      "avatar_small_base64": "BASE64..."
    }
  ]
}
```

注意：

- 无权限时返回 `403`，响应体为空。
- 查询前会尝试触发一次群成员同步。

### GET `/api/me/search/messages`

- 鉴权：是
- 说明：在当前用户可见群里搜索消息

查询参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `q` | string | 是 | 搜索关键词 |
| `chat_id` | integer | 否 | 限定某个群 |
| `user_ids` | integer[] | 否 | 发送者过滤，支持 `user_ids[]=1&user_ids[]=2` 或 `user_ids=1,2` |
| `page` | integer | 否 | 页码，默认 `1` |
| `per_page` | integer | 否 | 每页数量，范围 `1..200`，默认 `50` |
| `limit` | integer | 否 | `per_page` 别名 |
| `mode` | string | 否 | `regex` 走 PGroonga 正则；其他值走全文匹配 |

成功响应：

```json
{
  "page": 1,
  "per_page": 50,
  "total": 1,
  "items": [
    {
      "td_chat_id": -1001234567890,
      "td_message_id": 1234567890123,
      "message_id": 1177375,
      "tg_privatepost_channel_id": 1234567890,
      "tg_privatepost_url": "tg://privatepost?channel=1234567890&post=1177375",
      "text": "hello world",
      "sender_id": 123456,
      "sender_name": "Alice",
      "sender_username": "alice",
      "sender_avatar_small_content_type": "image/jpeg",
      "sender_avatar_small_base64": "BASE64...",
      "message_at": "2026-03-16T01:00:00.000Z",
      "highlight": "<span class=\"keyword\">hello</span> world"
    }
  ]
}
```

注意：

- 如果 `chat_id` 不在当前用户权限范围内，当前实现返回的是空数组 `[]`，不是分页对象。
- `highlight` 只有在 `q` 非空时才有值。
- `message_id` 是 Telegram `privatepost` 可用的 `post` 序号，不等于原始 `td_message_id`。

## Telegram Chats

### GET `/api/telegram/chats`

- 鉴权：是，且必须管理员
- 说明：分页查询聊天列表，结果按 `td_chat_id` 去重

查询参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 否 | 按标题模糊匹配 |
| `page` | integer | 否 | 页码，默认 `1` |
| `per_page` | integer | 否 | 每页数量，范围 `1..200`，默认 `20` |
| `limit` | integer | 否 | `per_page` 别名 |

成功响应：

```json
{
  "page": 1,
  "per_page": 20,
  "total": 1,
  "items": [
    {
      "td_chat_id": -1001234567890,
      "title": "Test Group",
      "chat_type": "supergroup",
      "avatar_small_content_type": "image/jpeg",
      "avatar_small_base64": "BASE64...",
      "source_session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
      "source_count": 2,
      "synced_at": "2026-03-16T01:00:00.000Z"
    }
  ]
}
```

## Telegram Sessions

### GET `/api/telegram/sessions`

- 鉴权：是
- 说明：返回最近 100 个 Telegram 会话

### POST `/api/telegram/sessions`

- 鉴权：是
- 说明：创建 Telegram 会话

请求参数：

| 参数名 | 位置 | 类型 | 必填 | 说明 |
|---|---|---|---|---|
| `use_test_dc` | query | boolean | 否 | 是否连接 Telegram Test DC |

示例：

```bash
curl -X POST 'http://127.0.0.1/api/telegram/sessions?use_test_dc=false' \
  -H 'Authorization: Bearer <token>'
```

成功响应：`201 Created`，响应体是 `Telegram Session Snapshot`。

### GET `/api/telegram/sessions/:id`

- 鉴权：是
- 说明：查询单个会话状态

路径参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string(uuid) | 是 | 会话 ID |

说明：

- 如果会话当前在运行，返回运行时快照。
- 如果会话当前不在运行，返回数据库里的持久化快照。

### DELETE `/api/telegram/sessions/:id`

- 鉴权：是
- 说明：禁用并断开会话
- 成功响应：`204 No Content`

### DELETE `/api/telegram/sessions/:id/purge`

- 鉴权：是
- 说明：物理删除会话（删除数据库记录和 tdlib 本地存储）

路径参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string(uuid) | 是 | 会话 ID |

约束：

- 仅允许删除当前状态非 `ready` 的账号。
- 若账号当前为 `ready`，返回 `422 Unprocessable Entity`。

成功响应：

- `204 No Content`

失败响应示例（ready 状态）：

```json
{
  "error": "Cannot purge a ready account. Disable or move it out of ready state first."
}
```

### POST `/api/telegram/sessions/:id/phone`

- 鉴权：是
- 说明：在 `wait_phone_number` 状态下提交手机号

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `phone_number` | string | 是 | 国际格式手机号，如 `+8613800000000` |

成功响应：返回最新会话快照：

```json
{
  "session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "state": "wait_code",
  "me": null,
  "error": null
}
```

### POST `/api/telegram/sessions/:id/code`

- 鉴权：是
- 说明：在 `wait_code` 状态下提交短信验证码

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `code` | string | 是 | 验证码 |

成功响应：返回最新会话快照。

### POST `/api/telegram/sessions/:id/password`

- 鉴权：是
- 说明：在 `wait_password` 状态下提交 Telegram 二次验证密码

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `password` | string | 是 | Telegram 2FA 密码 |

成功响应：返回最新会话快照。

说明：

- 如果当前状态不允许该操作，会返回 `422`。

### PATCH `/api/telegram/sessions/:id/watch_targets`

- 鉴权：是
- 说明：设置监听群组，并立即触发消息同步

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `chat_ids` | integer[] | 是 | 监听群 ID 列表 |
| `full_sync` | boolean | 否 | `true` 时不限制每群拉取条数 |
| `message_limit` | integer | 否 | 每群消息拉取上限，`full_sync=true` 时忽略 |
| `wait_seconds` | number | 否 | 每次请求之间的延迟；消息拉取超时后的重试也使用这个间隔 |

成功响应示例：

```json
{
  "session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "watched_chat_ids": [-1001234567890],
  "message_sync": {
    "chats": 1,
    "upserted": 120,
    "failed": 0,
    "errors": [],
    "details": []
  }
}
```

### GET `/api/telegram/sessions/:id/watch_targets`

- 鉴权：是
- 说明：查询指定 Telegram 会话当前配置的监听群组列表

路径参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string(uuid) | 是 | 会话 ID |

成功响应：

```json
{
  "session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "watched_chat_ids": [-1001234567890],
  "watched_chats": [
    {
      "td_chat_id": -1001234567890,
      "title": "Test Group",
      "chat_type": "supergroup",
      "synced_at": "2026-03-16T01:00:00.000Z"
    }
  ]
}
```

说明：

- `watched_chat_ids` 是当前会话实际保存的监听群 ID 列表。
- `watched_chats` 是附带的群资料快照；如果某个群 ID 还没同步到 `telegram_chats`，对应项的 `title/chat_type/synced_at` 会是 `null`。

### POST `/api/telegram/sessions/:id/sync_chats`

- 鉴权：是
- 说明：立即同步聊天列表

查询参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `limit` | integer | 否 | 单次聊天同步数量上限 |

成功响应：

```json
{
  "session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "sync": {
    "requested_limit": 500,
    "loaded": true,
    "from_get_chats": 300,
    "from_search_chats": 0,
    "from_search_chats_on_server": 0,
    "from_updates_cache": 0,
    "total_chat_ids": 300,
    "upserted": 300,
    "failed": 0,
    "errors": []
  }
}
```

### POST `/api/telegram/sessions/:id/sync_messages`

- 鉴权：是
- 说明：手动同步消息；不传 `chat_ids` 时，使用该会话当前 `watched_chat_ids`

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `chat_ids` | integer[] | 否 | 要同步的群 ID 列表 |
| `message_limit` | integer | 否 | 每群拉取消息数上限 |
| `wait_seconds` | number | 否 | 每次请求之间的延迟；消息拉取超时后的重试也使用这个间隔 |

成功响应：

```json
{
  "session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "chat_ids": [-1001234567890],
  "message_sync": {
    "chats": 1,
    "upserted": 120,
    "failed": 0,
    "errors": [],
    "details": [
      {
        "chat_id": -1001234567890,
        "upserted": 120
      }
    ]
  }
}
```

### POST `/api/telegram/sessions/:id/sync_group_members`

- 鉴权：是
- 说明：手动同步群成员；不传 `chat_ids` 时，使用该会话当前 `watched_chat_ids`

请求体：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `chat_ids` | integer[] | 否 | 要同步的群 ID 列表 |

成功响应：

```json
{
  "session_id": "2dbd1e1e-6e0f-4a3b-a963-04cb5b5f2f95",
  "chat_ids": [-1001234567890],
  "group_member_sync": {
    "chats": 1,
    "upserted": 88,
    "failed": 0,
    "errors": [],
    "details": [
      {
        "chat_id": -1001234567890,
        "upserted": 88
      }
    ]
  }
}
```
