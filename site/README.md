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

## 部署

推送到 `main` 后，`.github/workflows/deploy.yml` 会自动构建并发布到 GitHub Pages。

> 首次使用需在仓库 **Settings → Pages** 中把 **Source** 设为 **GitHub Actions**。

若改用自定义域名或用户主页，请同步修改 `astro.config.mjs` 里的 `site` 与 `base`。
