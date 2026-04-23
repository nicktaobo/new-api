# DEVELOP.md

本文面向新加入的开发者，帮助快速理解 new-api 的工程脉络、核心模块边界，以及本地开发/联调/构建的推荐方式。

## 1. 项目脉络（你在改什么）

GateLink 是一个基于 Go 的 AI API 网关/代理与管理系统：对外提供统一的 API 与 Web 管理后台；对内聚合多个上游模型供应商（OpenAI/Claude/Gemini/Azure/AWS Bedrock 等）的适配与转发，同时包含用户/令牌/计费/限流/统计等系统能力。

从进程角度看，核心由一个 Gin HTTP Server 组成：

- 启动入口：main.go（初始化环境变量、DB/Redis、缓存与后台任务，然后启动 Gin）
- 路由聚合：router/（按业务域拆分，最终统一挂到 gin.Engine）
- 分层结构：Router -> Controller -> Service -> Model（推荐沿用此边界做功能扩展）
- 前端资源：web/（React + Vite 构建产物会被 Go embed 进二进制，默认由后端直接提供静态站点）

## 2. 目录结构（按职责找代码）

建议从下列目录入手理解：

- router/：注册路由与分发（API、relay、dashboard、web 等）
- controller/：HTTP handler（参数解析、鉴权/权限检查、返回结构）
- service/：业务逻辑（计费、任务、上游调用封装、复杂流程编排）
- model/：GORM 数据模型与数据库访问（SQLite/MySQL/PostgreSQL 兼容）
- relay/：上游适配与转发（不同 provider 的协议转换、SSE/流式处理、重试等）
  - relay/channel/：按供应商拆分的适配实现
- middleware/：鉴权、限流、日志、CORS、RequestId、i18n 等中间件
- common/：通用工具（配置、日志、Redis、加密、JSON 包装、监控等）
- setting/：系统/比例/性能等配置项的加载与热更新逻辑
- i18n/：后端国际化（go-i18n）
- oauth/：OAuth/OIDC 等第三方登录
- web/：前端（React 18 + Vite + Semi UI，含 i18n 工具链）

补充：后端默认会将 web/dist 作为 embed 资源打进二进制（见 main.go 的 `//go:embed web/dist`）。

## 3. 运行时链路（一次请求怎么走）

以“外部调用模型”为例，典型链路是：

1. router/ 命中对应 API 路由
2. middleware/ 完成鉴权、限流、日志、语言等通用能力
3. controller/ 解析请求、做基础校验与权限判断，调用 service/
4. service/ 进行路由/计费/重试策略等业务编排，进入 relay/ 转发上游
5. relay/ 选择具体 provider 的协议转换（relay/channel/），处理流式（SSE）/非流式响应并回写客户端
6. model/ 写入请求日志、配额、统计等（依具体业务）

## 4. 本地开发（推荐流程）

### 4.1 环境准备

- Go：以 go.mod 为准（本仓库当前为 go 1.25.1）
- Bun：用于前端依赖与构建
- 数据库：开发期可用 SQLite（最省事）；也支持 MySQL/PostgreSQL
- Redis：可选（不开 Redis 会退化到内存缓存；某些能力会受限，建议联调时启用）

### 4.2 后端启动

后端会尝试读取根目录的 `.env`（如果不存在会忽略），再加载环境变量并初始化 DB/Redis。

最简单的启动方式：

```bash
go run .
```

常用参数/环境变量：

- 端口：`PORT=3000` 或命令行 `--port 3000`
- 日志目录：命令行 `--log-dir ./logs`（Docker Compose 也会使用该参数）
- 调试模式：`DEBUG=true`（会输出更多系统日志）
- pprof：`ENABLE_PPROF=true`（开启后监听 `0.0.0.0:8005`）

### 4.3 前端启动（开发模式）

```bash
cd web
bun install
bun run dev
```

前端开发服务器默认会请求后端 API（package.json 里配置了 proxy 指向 `http://localhost:3000`）。

如果你希望“后端不提供静态页面”，而是把所有非 API 路由跳转到一个独立的前端地址，可以设置：

- `FRONTEND_BASE_URL=http://localhost:5173`

此时后端对未命中路由的请求会 301 重定向到该地址（见 router/main.go）。

### 4.4 前后端联调（最省事的组合）

- 后端：`go run .`（默认 3000）
- 前端：`bun run dev`（默认 5173，API 走 proxy）

这种方式无需在后端生成 web/dist，也不会影响后端二进制的 embed 逻辑。

## 5. 配置与环境变量（从哪里看、改哪里）

配置入口：

- `.env`：开发机本地配置（不会提交）
- `.env.example`：环境变量示例与说明
- `docker-compose.yml`：容器化部署的示例配置

最常用的几类配置：

- 数据库：
  - `SQL_DSN`：MySQL/PostgreSQL 连接串
  - `SQLITE_PATH`：SQLite 文件路径（默认会在数据目录下）
- Redis：
  - `REDIS_CONN_STRING`：Redis 连接串（如 `redis://user:pass@host:6379/0`）
- 多机/集群：
  - `SESSION_SECRET`：多机部署必须设置为随机字符串（默认值会触发强制退出）
  - `NODE_TYPE`：`master`/`slave`（默认非 slave 即 master）
- 性能/行为：
  - `SYNC_FREQUENCY`、`BATCH_UPDATE_ENABLED`、`BATCH_UPDATE_INTERVAL`、`STREAMING_TIMEOUT` 等

完整列表请直接查看 `.env.example` 与 `common/init.go` 的 InitEnv。

## 6. 构建与打包（本仓库默认怎么产物化）

### 6.1 前端构建产物

前端产物输出到 `web/dist`，后端会将其 embed 到二进制中（用于一体化部署）。

```bash
cd web
bun install
bun run build
```

### 6.2 后端编译

```bash
go build -o new-api .
./new-api --help
```

### 6.3 Docker 打包（与生产一致）

Dockerfile 是多阶段构建：

1. 用 Bun 构建 web/dist
2. 用 Go 编译后端并将 web/dist 拷入（用于 embed）
3. 运行时使用精简镜像启动二进制（工作目录 `/data`，对外端口 3000）

```bash
docker build -t new-api:local .
docker run --rm -p 3000:3000 new-api:local --version
```

## 7. 开发规范（避免踩坑的硬规则）

### 7.1 JSON 统一封装

业务代码里不要直接用 `encoding/json` 做 marshal/unmarshal；统一使用 `common/json.go` 的包装函数（便于后续替换/优化）。

### 7.2 数据库三端兼容

所有数据库相关改动必须同时兼容 SQLite、MySQL、PostgreSQL：

- 优先使用 GORM API
- 必要的 raw SQL 需要考虑不同数据库的差异（列引用、布尔值、函数等）
- 迁移在 SQLite 上不要使用不支持的 `ALTER COLUMN` 模式

### 7.3 Relay/上游适配扩展

新增或改动某个上游 provider，通常涉及：

- relay/channel/：实现协议转换与请求/响应适配
- constant/、types/、dto/：补充枚举、类型定义与请求结构

如果该 provider 支持 StreamOptions，需要把它加入 `streamSupportedChannels`（用于能力开关与一致性处理）。

### 7.4 前端 i18n

前端 i18n 使用 i18next（key 通常是中文源字符串），工具链脚本在 web/package.json：

- `bun run i18n:extract`
- `bun run i18n:sync`
- `bun run i18n:lint`

## 8. 常用命令速查

后端：

```bash
go test ./...
go run . --port 3000 --log-dir ./logs
```

前端：

```bash
cd web
bun install
bun run dev
bun run build
bun run lint
bun run eslint
```

