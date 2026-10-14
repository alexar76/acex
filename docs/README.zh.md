# ACEX — AIMarket 金融轨道

> 🌐 [English](../README.md) · [Русский](README.ru.md) · [Español](README.es.md) · [Français](README.fr.md) · **中文** · [术语表](https://github.com/alexar76/aicom/blob/main/docs/localization-glossary.md)

**ACEX** 覆盖 vault / registry / lending / AMM / audit-pool 与 **Pulse Terminal**。链上结算与托管（escrow）与 Hub 共存。Base MAINNET 演示见单体仓链上日记。

## Live

- [Pulse](https://magic-ai-factory.com/pulse/)

## 合约地址

本文件**故意不重复**地址：唯一需要手工编辑的来源是
[`config/deployments/base-mainnet.json`](https://github.com/alexar76/aicom/blob/main/config/deployments/base-mainnet.json)。其余全部
（hub 与 monitor 的 Python 包、ARGUS 的 TS 客户端）都由
`python scripts/sync_deployment_addresses.py` 从它生成；若某个使用方硬编码了地址，或生成的副本
过期，测试会失败。

每笔部署交易的可读记录见 [`docs/onchain-journal.md`](https://github.com/alexar76/aicom/blob/main/docs/onchain-journal.md)。ACEX 合约集
已于 **2026-08-22** 因安全审计而重新部署（见 §2d）。

## 快速开始

克隆该卫星仓库，按[英文 README](../README.md) 的 Quick start 操作，并用术语表核对用语。

```bash
git clone https://github.com/alexar76/acex.git
cd acex
# затем — команды из English README → Quick start
```

## English README sections

- ## Naming (canonical)
- ## Monorepo map
- ## Ecosystem placement
- ## Phase 2 roadmap
- ## Quick start (contracts)
- ## Documentation index
- ## Demo
- ## Related repos
- ## Community
- ## License

## 全文

英文 README 仍是运维细节的真源。本文件是按术语表写成的完整产品本地化说明。

## License

MIT — see [LICENSE](../LICENSE).
