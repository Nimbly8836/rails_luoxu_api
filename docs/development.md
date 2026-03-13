# Development Guide

## 1. 本地开发前提

- Ruby/Bundler 已安装
- PostgreSQL 可用
- 项目根目录执行

## 2. 安装依赖

```bash
bundle install
```

## 3. 准备 credentials

如果本地还没有 `config/credentials.yml.enc`，执行：

```bash
EDITOR=vim bin/rails credentials:edit
```

至少配置：

```yaml
telegram:
  api_id: 123456
  api_hash: your_api_hash
  encryption_key: ""
```

说明：
- `encryption_key` 未启用时可留空。

## 4. 初始化数据库

```bash
bin/rails db:prepare
```

## 5. 启动服务

```bash
bin/rails server
```

## 6. 初始化首个管理员（一次性）

```bash
bin/rails runner "u = SystemUser.find_or_create_by!(username: 'admin') { |x| x.password = 'pass123456'; x.password_confirmation = 'pass123456' }; u.update!(admin: true, active: true); puts u.api_token"
```

## 7. 无本机 Ruby 时生成 credentials（Docker 方式）

```bash
docker build -t rails_luoxu_api .

docker run --rm -it \
  -v "$PWD":/rails \
  -w /rails \
  rails_luoxu_api \
  bash -lc 'EDITOR="ruby -e \"p=ARGV[0]; File.write(p, %q(telegram:\n  api_id: 123456\n  api_hash: your_api_hash\n  encryption_key: \\\"\\\"\n))\"" bin/rails credentials:edit'
```

会在项目内生成（或更新）：
- `config/credentials.yml.enc`
- `config/master.key`
