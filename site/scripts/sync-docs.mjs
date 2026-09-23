#!/usr/bin/env node
/**
 * sync-docs.mjs —— 把仓库根目录的课程 Markdown 同步为 Starlight 文档
 *
 * 内容源：仓库根目录的 *.md（唯一真相）
 * 输出：  site/src/content/docs/modules/*.md（生成物，已 gitignore）
 *
 * 做三件事：
 *   1. 从正文第一个 H1 提取 title，写进 frontmatter
 *   2. 从 MANIFEST 补上 description 与 URL slug
 *   3. 去掉正文里的 H1（Starlight 用 frontmatter.title 渲染页面标题，避免重复）
 *
 * 在 site/ 目录下运行： node scripts/sync-docs.mjs（或 npm run sync）
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SITE_DIR = resolve(__dirname, '..');
const REPO_DIR = resolve(SITE_DIR, '..');
const OUT_DIR = join(SITE_DIR, 'src/content/docs/modules');

/** 文档清单：源文件 → slug + 摘要 */
const MANIFEST = [
  { src: '01-虚拟化基础与KVM定位.md', slug: '01-basics', description: '虚拟化的分类、KVM 在技术栈中的位置，以及与容器的边界。' },
  { src: '02-环境搭建与第一台虚拟机.md', slug: '02-first-vm', description: '安装 QEMU/libvirt，用裸命令与 libvirt 两种方式跑通第一台虚拟机。' },
  { src: '03-KVM架构与工作原理.md', slug: '03-architecture', description: 'CPU、内存、I/O 三类虚拟化的原理，VM-Exit、EPT、virtio 的来龙去脉。' },
  { src: '04-libvirt与虚拟机生命周期管理.md', slug: '04-libvirt', description: 'libvirt 域 XML、virsh 生命周期管理、快照、克隆与备份。' },
  { src: '05-存储虚拟化.md', slug: '05-storage', description: 'qcow2/raw/LVM/Ceph、cache 模式、后备链、精简置备与空间回收。' },
  { src: '06-网络虚拟化.md', slug: '06-network', description: 'NAT/桥接/macvtap/OVS/SR-IOV，以及 vhost-net 与多队列。' },
  { src: '07-设备直通与IO虚拟化.md', slug: '07-passthrough', description: 'virtio、vhost、VFIO 设备直通、IOMMU 分组与 GPU 虚拟化。' },
  { src: '08-性能调优.md', slug: '08-performance', description: 'vCPU 绑核、NUMA、HugePages、io_uring 与压测方法。' },
  { src: '09-迁移与高可用.md', slug: '09-migration', description: '热迁移流程、pre/post-copy、共享存储与高可用方案。' },
  { src: '10-安全与隔离.md', slug: '10-security', description: 'sVirt/SELinux、Secure Boot、vTPM、侧信道与机密计算。' },
  { src: '11-监控与排障.md', slug: '11-monitoring', description: 'kvm_stat、perf kvm、domstats 与分层排障方法论。' },
  { src: '12-高级主题与生态.md', slug: '12-advanced', description: '嵌套虚拟化、SEV/TDX、KubeVirt、Firecracker 与生态地图。' },
  { src: '附录-命令速查表.md', slug: 'appendix-cheatsheet', description: '常用命令一页纸速查：环境、QEMU、virsh、存储、网络、迁移、排障。' },
];

/** 转义 YAML 字符串值 */
function yamlString(value) {
  return JSON.stringify(value);
}

if (existsSync(OUT_DIR)) rmSync(OUT_DIR, { recursive: true, force: true });
mkdirSync(OUT_DIR, { recursive: true });

let count = 0;
const missing = [];

for (const item of MANIFEST) {
  const srcPath = join(REPO_DIR, item.src);
  if (!existsSync(srcPath)) {
    missing.push(item.src);
    continue;
  }
  const raw = readFileSync(srcPath, 'utf8');

  // 提取第一个 H1 作为标题
  const h1 = raw.match(/^#\s+(.+?)\s*$/m);
  const title = h1 ? h1[1] : item.slug;

  // 去掉正文里的第一个 H1（含其后紧跟的空行）
  let body = raw;
  if (h1) {
    body = raw.replace(/^#\s+.+?\s*\n+/, '');
  }

  const frontmatter = [
    '---',
    `title: ${yamlString(title)}`,
    `description: ${yamlString(item.description)}`,
    '---',
    '',
  ].join('\n');

  writeFileSync(join(OUT_DIR, `${item.slug}.md`), frontmatter + body);
  count += 1;
}

console.log(`[sync-docs] 已同步 ${count} 篇文档 → src/content/docs/modules/`);
if (missing.length > 0) {
  console.warn(`[sync-docs] 未找到以下源文件：\n  - ${missing.join('\n  - ')}`);
  process.exitCode = 1;
}
