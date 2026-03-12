# API

默认所有 API 都需要 `Authorization: Bearer <token>`，除非该接口明确标注为无需鉴权。

## 全局请求头

| Header | 必填 | 说明 |
|---|---|---|
| `Authorization` | 是（除登录接口外） | 格式：`Bearer <token>` |
| `Content-Type` | JSON Body 时是 | 使用 `application/json` |

## Auth

### POST `/api/auth/login`

- 鉴权：否
- 说明：用户名密码登录，返回 token

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `username` | body | string | 是 | 用户名 | `u1` |
| `password` | body | string | 是 | 密码 | `pass123456` |

- 返回：`{ user_id, username, admin, active, token, chat_ids, watched_chats }`

### POST `/api/auth/register`

- 鉴权：是（管理员）
- 说明：管理员创建系统用户

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `username` | body | string | 是 | 新用户名 | `u2` |
| `password` | body | string | 是 | 新用户密码 | `pass123456` |
| `password_confirmation` | body | string | 否 | 不传时默认等于 `password` | `pass123456` |
| `admin` | body | boolean | 否 | 是否管理员 | `false` |
| `chat_ids` | body | integer[] | 否 | 用户可见群组 ID 列表（必须是已同步到 `telegram_chats` 的群） | `[-1001234567890]` |

- 返回：`{ user_id, username, admin, active, token, chat_ids, watched_chats }`

### GET `/api/auth/users`

- 鉴权：是（管理员）
- 说明：查询系统用户列表，并返回每个用户可访问群组的列表
- 参数：无
- 返回：用户数组（每项包含 `user_id/username/admin/active/chat_ids/watched_chats`）

### PATCH `/api/auth/users/:id/chat_ids`

- 鉴权：是（管理员）
- 说明：维护已有用户可访问群组（支持增删，或全量覆盖）

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | integer | 是 | 用户 ID | `2` |
| `chat_ids` | body | integer[] | 否 | 全量覆盖用户群组权限 | `[-1001234567890]` |
| `add_chat_ids` | body | integer[] | 否 | 追加可访问群组 | `[-1001234567890]` |
| `remove_chat_ids` | body | integer[] | 否 | 移除可访问群组 | `[-1001234567890]` |

- 说明：`chat_ids` 存在时按全量覆盖；否则按 `add_chat_ids/remove_chat_ids` 增删。
- 说明：新增的群组必须是已同步到 `telegram_chats` 的群组。
- 说明：兼容 `auth.chat_ids` / `auth.add_chat_ids` / `auth.remove_chat_ids` 的嵌套参数格式。
- 说明：当用户权限新增群组时，会自动把该群组追加到监听关系表 `telegram_account_watch_targets`（仅追加，不会因为用户权限删除而回删）。
- 说明：当用户权限新增群组时，会自动触发对应 Telegram 账号的历史消息回填（等同执行该账号的消息同步）。
- 说明：应用重启后，会对启用账号自动触发一次监听群组历史消息同步。
- 返回：更新后的用户对象（包含 `chat_ids` 与 `watched_chats` 列表）。

## Me

### GET `/api/me/chats`

- 鉴权：是
- 说明：返回当前用户有权限访问的群聊列表
- 参数：无
- 返回：聊天数组（每项包含 `td_chat_id/title/chat_type/source_session_id/source_count` 等）

### GET `/api/me/chats/:chat_id`

- 鉴权：是
- 说明：查询单个群详情（仅可查询有权限的群）

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `chat_id` | path | integer | 是 | 群 ID | `-1001234567890` |

- 返回：单个聊天对象（字段同 `/api/me/chats`）

### GET `/api/me/chats/:chat_id/members`

- 鉴权：是
- 说明：查询群成员列表（仅可查询有权限的群）

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `chat_id` | path | integer | 是 | 群 ID | `-1001234567890` |
| `q` | query | string | 否 | 按 `name/username` 使用 PGroonga 分词搜索；纯数字同时匹配 `uid` | `alice` |
| `page` | query | integer | 否 | 页码，默认 `1` | `1` |
| `per_page` | query | integer | 否 | 每页数量，范围 `1..200`，默认 `20` | `20` |
| `limit` | query | integer | 否 | `per_page` 别名（未传 `per_page` 时生效） | `20` |

- 返回：`{ page, per_page, total, items }`
- 说明：`items` 为成员数组（每项包含 `uid/name/username/last_seen/avatar_small_base64` 等）

### GET `/api/me/search/messages`

- 鉴权：是
- 说明：在当前用户可见群中搜索消息

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `q` | query | string | 是 | 搜索关键词 | `hello` |
| `chat_id` | query | integer | 否 | 限定某个群 | `-1001234567890` |
| `user_ids` | query | integer[] | 否 | 发送者用户 ID 过滤（支持多个：`user_ids[]=1&user_ids[]=2` 或 `user_ids=1,2`） | `[12345,67890]` |
| `page` | query | integer | 否 | 页码，默认 `1` | `1` |
| `per_page` | query | integer | 否 | 每页数量，范围 `1..200`，默认 `50` | `50` |
| `limit` | query | integer | 否 | `per_page` 别名（未传 `per_page` 时生效） | `50` |
| `mode` | query | string | 否 | `regex` 使用 PGroonga 正则匹配；其他值走全文匹配 | `regex` |

- 返回：`{ page, per_page, total, items }`  
- 说明：`q` 非空时，`items[].highlight` 会有高亮片段
- 说明：`items[].td_message_id` 是 TDLib 原始消息 ID；`items[].message_id` 是可用于 Telegram 链接的消息序号（`post`）。
- 说明：`items[].tg_privatepost_channel_id` 与 `items[].tg_privatepost_url` 可直接用于 `tg://privatepost?channel=<channel>&post=<post>`。

## Telegram Chats

### GET `/api/telegram/chats`

- 鉴权：是（管理员）
- 说明：分页查询聊天列表（按 `td_chat_id` 去重）

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `name` | query | string | 否 | 按标题模糊匹配 | `test` |
| `page` | query | integer | 否 | 页码，默认 `1` | `1` |
| `per_page` | query | integer | 否 | 每页数量，范围 `1..200`，默认 `20` | `20` |
| `limit` | query | integer | 否 | `per_page` 别名（未传 `per_page` 时生效） | `20` |

- 返回：`{ page, per_page, total, items }`

## Telegram Sessions

### GET `/api/telegram/sessions`

- 鉴权：是
- 说明：查询会话列表
- 参数：无
- 返回：会话数组（每项包含 `session_id/state/me/profile/enabled/chat_count` 等）

### POST `/api/telegram/sessions`

- 鉴权：是
- 说明：创建 Telegram 会话

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `use_test_dc` | query | boolean | 否 | 是否使用测试 DC | `false` |

- 返回：创建后的会话快照

### GET `/api/telegram/sessions/:id`

- 鉴权：是
- 说明：查询单个会话状态

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |

- 返回：会话快照（运行中返回实时状态，不在运行中返回持久化状态）

### DELETE `/api/telegram/sessions/:id`

- 鉴权：是
- 说明：禁用并断开会话

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |

- 返回：`204 No Content`

### POST `/api/telegram/sessions/:id/phone`

- 鉴权：是
- 说明：提交手机号

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |
| `phone_number` | body | string | 是 | 手机号（国际区号） | `+8613800000000` |

### POST `/api/telegram/sessions/:id/code`

- 鉴权：是
- 说明：提交短信验证码

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |
| `code` | body | string | 是 | 短信验证码 | `12345` |

### POST `/api/telegram/sessions/:id/password`

- 鉴权：是
- 说明：提交 2FA 密码

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |
| `password` | body | string | 是 | 2FA 密码 | `your_2fa_password` |

### PATCH `/api/telegram/sessions/:id/watch_targets`

- 鉴权：是
- 说明：设置监听群组并触发消息同步

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |
| `chat_ids` | body | integer[] | 是 | 监听群 ID 列表 | `[-1001234567890]` |
| `full_sync` | body | boolean | 否 | `true` 时不限制每群拉取条数 | `true` |
| `message_limit` | body | integer | 否 | 每群消息拉取上限（`full_sync=true` 时忽略） | `1000` |
| `wait_seconds` | body | number | 否 | 每次拉取间隔秒数 | `0.2` |

- 返回：`{ session_id, watched_chat_ids, message_sync }`

### POST `/api/telegram/sessions/:id/sync_chats`

- 鉴权：是
- 说明：手动同步聊天列表

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |
| `limit` | query | integer | 否 | 单次同步拉取上限 | `500` |

- 返回：`{ session_id, sync }`

### POST `/api/telegram/sessions/:id/sync_messages`

- 鉴权：是
- 说明：手动同步消息（不传 `chat_ids` 时用该会话已配置 `watched_chat_ids`）

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |
| `chat_ids` | body | integer[] | 否 | 需要同步的群 ID 列表 | `[-1001234567890]` |
| `message_limit` | body | integer | 否 | 每群消息拉取上限 | `1000` |
| `wait_seconds` | body | number | 否 | 每次拉取间隔秒数 | `0.2` |

- 返回：`{ session_id, chat_ids, message_sync }`

### POST `/api/telegram/sessions/:id/sync_group_members`

- 鉴权：是
- 说明：手动同步群成员（不传 `chat_ids` 时用该会话已配置 `watched_chat_ids`）

| 参数名 | 位置 | 类型 | 必填 | 说明 | 示例 |
|---|---|---|---|---|---|
| `id` | path | string(uuid) | 是 | 会话 ID | `9fc1...` |
| `chat_ids` | body | integer[] | 否 | 需要同步成员的群 ID 列表 | `[-1001234567890]` |

- 返回：`{ session_id, chat_ids, group_member_sync }`
