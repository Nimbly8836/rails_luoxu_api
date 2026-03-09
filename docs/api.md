# API

All API endpoints require `Authorization: Bearer <token>` unless explicitly noted.

## Auth

`POST /api/auth/register` (admin only)
- Body: `username`, `password`, `password_confirmation` (optional), `admin` (optional), `chat_ids` (optional)
- Returns: `user_id`, `username`, `admin`, `token`, `chat_ids`

`POST /api/auth/login`
- Body: `username`, `password`
- Returns: `user_id`, `username`, `admin`, `token`, `chat_ids`

## Me

`GET /api/me/chats`
- Returns: list of chats the current user can access.

`GET /api/me/search/messages`
- Query: `q`, `chat_id` (optional), `page` (default 1), `per_page`/`limit` (default 100), `mode` (`regex` to use PGroonga regex)
- Returns: `{ page, per_page, total, items: [...] }`
- Each item includes `highlight` when `q` is present.

## Telegram Sessions

`GET /api/telegram/sessions`
- Returns: list of sessions.

`POST /api/telegram/sessions`
- Query: `use_test_dc` (optional)
- Returns: created session snapshot.

`GET /api/telegram/sessions/:id`
- Returns: session snapshot.

`DELETE /api/telegram/sessions/:id`
- Disables a session.

`POST /api/telegram/sessions/:id/phone`
- Body: `phone_number`

`POST /api/telegram/sessions/:id/code`
- Body: `code`

`POST /api/telegram/sessions/:id/password`
- Body: `password`

`PATCH /api/telegram/sessions/:id/watch_targets`
- Body: `chat_ids` (required), `full_sync` (optional), `message_limit` (optional), `wait_seconds` (optional)
- When `full_sync=true`, all history is fetched for those chats.

`POST /api/telegram/sessions/:id/sync_chats`
- Query: `limit` (optional), `force_full` (optional)
- Note: only manual sync is performed.

`POST /api/telegram/sessions/:id/sync_messages`
- Body: `chat_ids` (optional, defaults to watched chats), `message_limit` (optional), `wait_seconds` (optional)

## Telegram Chats

`GET /api/telegram/chats`
- Returns: list of chats (deduped by chat_id).
