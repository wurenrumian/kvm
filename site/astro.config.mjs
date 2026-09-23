// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages 项目站点地址：https://wurenrumian.github.io/kvm/
// 若改用自定义域名或用户主页，请同步修改 site / base
export default defineConfig({
	site: 'https://wurenrumian.github.io',
	base: '/kvm',
	integrations: [
		starlight({
			title: 'KVM 虚拟化课程',
			description: '从原理到实战，系统掌握 QEMU/KVM 虚拟化',
			locales: {
				root: { label: '简体中文', lang: 'zh-CN' },
			},
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/wurenrumian/kvm' },
			],
			sidebar: [
				{
					label: '基础',
					items: [
						{ label: '01 · 虚拟化基础与 KVM 定位', slug: 'modules/01-basics' },
						{ label: '02 · 环境搭建与第一台虚拟机', slug: 'modules/02-first-vm' },
						{ label: '03 · KVM 架构与工作原理', slug: 'modules/03-architecture' },
					],
				},
				{
					label: '管理与运维',
					items: [
						{ label: '04 · libvirt 与生命周期管理', slug: 'modules/04-libvirt' },
						{ label: '05 · 存储虚拟化', slug: 'modules/05-storage' },
						{ label: '06 · 网络虚拟化', slug: 'modules/06-network' },
						{ label: '07 · 设备直通与 I/O 虚拟化', slug: 'modules/07-passthrough' },
					],
				},
				{
					label: '进阶',
					items: [
						{ label: '08 · 性能调优', slug: 'modules/08-performance' },
						{ label: '09 · 迁移与高可用', slug: 'modules/09-migration' },
						{ label: '10 · 安全与隔离', slug: 'modules/10-security' },
						{ label: '11 · 监控与排障', slug: 'modules/11-monitoring' },
						{ label: '12 · 高级主题与生态', slug: 'modules/12-advanced' },
					],
				},
				{
					label: '附录',
					items: [
						{ label: '命令速查表', slug: 'modules/appendix-cheatsheet' },
					],
				},
			],
		}),
	],
});
