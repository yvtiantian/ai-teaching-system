# 强制要求

## 全局
1. 所有的设计，必须是渐进式的，不允许过度设计
2. 不允许留下技术债，不需要做旧代码兼容的设计
3. 第一性原理进行设计和编码
4. 对我的方案总是进行深入的思考，不合适的时候，提出质疑
5. 优先思考，是否有现成的开源库能够使用，而不是自己再造一次
6. 无用的文件一定要及时删除

## 技术栈约束
- 后端：Python 3.12+，FastAPI + Uvicorn，Agno Agent 框架
- 前端：Next.js 15 (App Router) + Ant Design 5 + TypeScript + Tailwind CSS
- 数据库：Supabase (PostgreSQL + Auth + Realtime + Storage)
- Agent 通信：AG-UI 流式协议 (SSE)
- 模型推理：Ollama 本地部署，OpenAI 兼容 API
- 包管理：后端用 uv，前端用 pnpm
- 容器化：Docker + Docker Compose + Traefik

## 后端规范s
- 薄路由层：路由只做参数校验和转发，业务逻辑放在 services 层
- 不使用 ORM：所有数据库操作通过 Supabase Client + RPC
- SQL 为源：数据库 schema 以 `supabase/sql/` 目录下的 SQL 文件为唯一源
- 类型严格：使用 Python 3.12+ 类型语法，Pydantic 校验
- 配置管理：Pydantic Settings，通过环境变量注入，不硬编码密码

## supabases
1. 当涉及到 supabase 的定义调整的时候，直接调整 sql 文件夹中对应的 sql,而不是做 migrate,调整完毕后，在 supabase 的migrations文件夹中添加本次修改的，能够让我直接贴到 Supabase 控制台中执行升级的 sql 文件

## 前端规范
- TypeScript 严格模式，禁止使用 `any`
- 使用 App Router，不使用 Pages Router
- 组件以 `.tsx` 为后缀，工具函数以 `.ts` 为后缀
- 使用 React Context 管理全局状态，不引入额外状态库
- 样式使用 Tailwind CSS + Ant Design 组件，不写独立 CSS 文件

## 数据库规范
- 主键使用 UUID (`gen_random_uuid()`)
- 时间字段使用 `TIMESTAMPTZ`
- 所有表添加 `created_at` 和 `updated_at` 审计字段
- 启用 RLS (Row Level Security) 策略
- 外键约束必须定义
