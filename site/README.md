# KVM 课程文档站

基于 [Astro](https://astro.build/) + [Starlight](https://starlight.astro.build/) 的课程文档站点。

- 线上地址：<https://wurenrumian.github.io/kvm/>
- 仓库：<https://github.com/wurenrumian/kvm>

## 内容来源

课程正文以仓库**根目录的 Markdown 为唯一内容源**。构建前由 `scripts/sync-docs.mjs`
自动转换到 `src/content/docs/modules/`（补 frontmatter、去掉重复 H1）。
该目录是生成物，已在 `.gitignore` 中忽略，**不要直接编辑**。

要改内容，改根目录的 `NN-*.md`，然后 `npm run sync`（`dev`/`build` 会自动先跑）。

## 本地开发

```bash
npm install
npm run dev      # http://localhost:4321/kvm/ ，会自动先同步文档
```

## 构建与预览

```bash
npm run build    # 自动 sync + astro build，产物在 dist/
npm run preview  # 本地预览构建产物
```

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `src/content/docs/index.mdx` | 首页（MDX，使用 Starlight 组件） |
| `src/content/docs/modules/` | 由 sync 生成的模块文档（Markdown，已忽略） |
| `scripts/sync-docs.mjs` | 文档同步脚本，含 slug 与摘要清单 |
| `astro.config.mjs` | 站点标题、`site`/`base`、侧边栏配置 |
| `public/` | 静态资源（favicon 等） |

## 构建产物与托管

`npm run build` 生成的 `dist/` 是纯静态文件，可以：

- 本地直接预览：`npm run build && npm run preview`
- 放到任意静态托管（Nginx / Caddy / Cloudflare Pages / Netlify / Vercel 等）

> 若部署到**子路径**（例如 `https://example.com/kvm/`），需在 `astro.config.mjs`
> 里设置 `site` 与 `base`；部署在根路径则无需配置。
