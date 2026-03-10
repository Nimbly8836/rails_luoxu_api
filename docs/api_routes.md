# API Routes

Generated at: 2026-03-09T02:17:36Z

| Method | Path | Action |
|---|---|---|
| `POST` | `/api/auth/login(.:format)` | `api/auth#login` |
| `POST` | `/api/auth/register(.:format)` | `api/auth#register` |
| `GET` | `/api/me/chats(.:format)` | `api/me#chats` |
| `GET` | `/api/me/search/messages(.:format)` | `api/me#search_messages` |
| `GET` | `/api/telegram/chats(.:format)` | `api/telegram/chats#index` |
| `GET` | `/api/telegram/sessions(.:format)` | `api/telegram/sessions#index` |
| `POST` | `/api/telegram/sessions(.:format)` | `api/telegram/sessions#create` |
| `DELETE` | `/api/telegram/sessions/:id(.:format)` | `api/telegram/sessions#destroy` |
| `GET` | `/api/telegram/sessions/:id(.:format)` | `api/telegram/sessions#show` |
| `POST` | `/api/telegram/sessions/:id/code(.:format)` | `api/telegram/sessions#code` |
| `POST` | `/api/telegram/sessions/:id/password(.:format)` | `api/telegram/sessions#password` |
| `POST` | `/api/telegram/sessions/:id/phone(.:format)` | `api/telegram/sessions#phone` |
| `POST` | `/api/telegram/sessions/:id/sync_chats(.:format)` | `api/telegram/sessions#sync_chats` |
| `POST` | `/api/telegram/sessions/:id/sync_messages(.:format)` | `api/telegram/sessions#sync_messages` |
| `PATCH` | `/api/telegram/sessions/:id/watch_targets(.:format)` | `api/telegram/sessions#watch_targets` |
