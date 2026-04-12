# Telegram 消息历史与投票展示设计

## 1. 背景与目标
当前系统以 `telegram_messages` 存储消息当前态，缺少以下能力：
- 无法追踪消息编辑与删除历史。
- 无法以结构化方式展示投票（poll）结果与账号视角的投票状态。

本设计目标：
- 在不破坏现有消息同步链路的前提下，引入“历史事件日志表”。
- 将 `telegram_messages` 明确为“最新消息状态表”，并支持软删除。
- 新增投票独立表，按 `telegram_account` 维度持久化投票快照，实现类似 TG 客户端的展示行为。

## 2. 范围与非目标
### 范围
- 消息变更事件：`new`、`edited`、`deleted`、`poll_updated`。
- 消息当前态：支持 `deleted_at` 软删除，默认查询过滤已删除消息。
- 投票：展示题目、选项票数、总票数、匿名/多选属性、当前账号是否投票与已选项。
- 存储维度：按 `telegram_account_id` 独立存储每个账号看到的投票状态。

### 非目标
- 不实现“群内每个用户”的投票明细（TDLib 对匿名投票通常不可得）。
- 不实现全量消息版本快照存储（仅事件日志，不做全版本历史表）。

## 3. 方案选型
采用“事件日志 + 投票独立结构化表”方案：
- `telegram_messages`：当前消息最新态。
- `telegram_message_events`：变更事件审计日志。
- `telegram_polls` + `telegram_poll_options`：投票结构化数据。
- `telegram_account_poll_states`：账号维度投票快照（该账号是否投票、投了哪些选项）。

选型原因：
- 相比纯 `jsonb` 事件日志，查询与展示更稳定，后续统计更容易。
- 相比全版本快照，写放大与存储成本更低，满足当前需求。

## 4. 数据模型设计

### 4.1 修改现有表：`telegram_messages`
新增字段：
- `deleted_at: datetime`（软删除标记）
- `edited_at: datetime`（最近编辑时间，可选但建议）

索引：
- `index_telegram_messages_on_deleted_at`
- 保留现有唯一约束（按账号+chat+message 或现有 td_message 约束）。

语义：
- 此表只表示消息“当前最新状态”。

### 4.2 新表：`telegram_message_events`
字段：
- `telegram_account_id: bigint`（FK）
- `td_chat_id: bigint`
- `message_id: bigint`
- `td_message_id: bigint`（可空，兼容历史）
- `event_type: string`（`new|edited|deleted|poll_updated`）
- `event_at: datetime`
- `payload: jsonb`（差异内容、上下文）
- `created_at: datetime`

索引建议：
- `(telegram_account_id, td_chat_id, message_id, event_at)`
- `(event_type, event_at)`

### 4.3 新表：`telegram_polls`
字段：
- `telegram_account_id: bigint`（FK）
- `td_chat_id: bigint`
- `message_id: bigint`
- `poll_id: string`（TDLib poll.id）
- `question: text`
- `is_anonymous: boolean`
- `allows_multiple_answers: boolean`
- `total_voter_count: integer`
- `is_closed: boolean`
- `raw_payload: jsonb`
- `created_at: datetime`
- `updated_at: datetime`

索引建议：
- 唯一键 `(telegram_account_id, td_chat_id, message_id)`
- 普通索引 `poll_id`

### 4.4 新表：`telegram_poll_options`
字段：
- `telegram_poll_id: bigint`（FK -> telegram_polls）
- `option_index: integer`
- `text: text`
- `voter_count: integer`
- `is_chosen: boolean`（账号视角）
- `is_correct: boolean`（未来 quiz 扩展，可空）
- `created_at: datetime`
- `updated_at: datetime`

索引建议：
- 唯一键 `(telegram_poll_id, option_index)`

### 4.5 新表：`telegram_account_poll_states`
字段：
- `telegram_account_id: bigint`（FK）
- `td_chat_id: bigint`
- `message_id: bigint`
- `poll_id: string`
- `chosen_option_indexes: jsonb`（如 `[0,2]`）
- `has_voted: boolean`
- `snapshot_at: datetime`
- `raw_payload: jsonb`
- `created_at: datetime`
- `updated_at: datetime`

索引建议：
- 唯一键 `(telegram_account_id, td_chat_id, message_id)`

## 5. 事件处理与数据流
核心修改点：`app/services/telegram/td_session.rb` 的更新事件分发。

### 5.1 `updateNewMessage`
- 继续 upsert 到 `telegram_messages`。
- 若消息内容为 poll，同步 upsert 投票主体与选项，并更新账号投票快照。
- 记录 `telegram_message_events(event_type='new')`（可审计完整链路）。

### 5.2 `updateMessageContent`（编辑）
- 更新 `telegram_messages` 当前态字段（`text` 等）并写 `edited_at`。
- 写 `telegram_message_events(event_type='edited')`，payload 至少包含 before/after 关键字段。
- 若内容涉及 poll，触发投票结构化更新。

### 5.3 `updateDeleteMessages`（删除）
- 命中消息执行软删除：`deleted_at = Time.current`。
- 写 `telegram_message_events(event_type='deleted')`，包含消息 id 列表与 `is_permanent` 等上下文。
- 不物理删除 `telegram_messages`。

### 5.4 `updateMessagePoll`（投票更新）
- upsert `telegram_polls` 当前状态。
- upsert `telegram_poll_options`（票数、是否被该账号选中）。
- upsert `telegram_account_poll_states`（该账号是否投票、已选项、快照时间）。
- 写 `telegram_message_events(event_type='poll_updated')`，payload 记录最小变化信息。

## 6. 查询与 API 行为
目标接口：`Api::MeController#search_messages`

- 默认行为：仅返回 `deleted_at IS NULL` 的消息。
- 可选参数：`include_deleted=true` 时包含软删除消息。
- 返回结构新增 `poll` 字段，至少包括：
  - `question`
  - `is_anonymous`
  - `allows_multiple_answers`
  - `total_voter_count`
  - `is_closed`
  - `options[]`（`option_index`, `text`, `voter_count`, `is_chosen`）
  - `account_state`（`has_voted`, `chosen_option_indexes`）

## 7. 一致性与异常处理
- 更新顺序：先写当前态（`telegram_messages` / poll 表），再写事件日志。
- 事件写入失败：记录错误并重试当前批次，避免长期“有当前态无历史”。
- 幂等：使用 upsert 和幂等键（账号+chat+message+事件特征）避免重复消费导致脏数据。
- 删除后收到编辑事件：不清空 `deleted_at`，仅记录事件（已删除消息不复活）。

## 8. 测试策略（TDD）

### 8.1 `test/services/telegram/td_session_test.rb`
新增用例：
- `updateMessageContent`：更新当前消息 + 写 `edited` 事件。
- `updateDeleteMessages`：软删除 + 写 `deleted` 事件。
- `updateMessagePoll`：upsert poll 三表 + 写 `poll_updated` 事件。

### 8.2 API 测试
新增/扩展控制器测试：
- 默认不返回 `deleted_at` 非空消息。
- `include_deleted=true` 时返回软删除消息。
- poll 字段结构完整，且包含账号视角的投票状态。

### 8.3 回归保障
- 现有消息 backfill / 增量同步相关测试保持通过。

## 9. 迁移与上线顺序
1. 增加新表和 `telegram_messages` 新字段迁移。
2. 增加模型与索引。
3. 增加 `TdSession` 事件处理逻辑。
4. 增加 `search_messages` 返回结构扩展。
5. 补齐测试并全量回归。

## 10. 风险与对策
- 风险：TDLib 各类更新 payload 形态存在差异。
  - 对策：解析时统一 hash 化，严格判空与容错，异常落日志。
- 风险：事件重复消费导致日志重复。
  - 对策：事件幂等键 + upsert/去重策略。
- 风险：poll 更新频繁带来写放大。
  - 对策：仅更新变化字段，option 维度 upsert。

## 11. 验收标准
- 能查询到消息编辑/删除历史事件。
- `telegram_messages` 体现最新态，删除后为软删除。
- `search_messages` 可直接展示投票题目、选项票数、总票数、匿名/多选、当前账号投票状态。
- 同一条消息在不同 `telegram_account` 下的投票快照可独立存储与读取。
