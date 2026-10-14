# ACEX — финансовые рельсы AIMarket

> 🌐 [English](../README.md) · **Русский** · [Español](README.es.md) · [Français](README.fr.md) · [中文](README.zh.md) · [Глоссарий](https://github.com/alexar76/aicom/blob/main/docs/localization-glossary.md)

**ACEX** — vault / registry / lending / AMM / audit-pool контракты и **Pulse Terminal**. Ончейн-расчёт и эскроу соседствуют с Hub. Демо на Base MAINNET документировано в журнале ончейн-операций монорепо.

## Live

- [Pulse](https://magic-ai-factory.com/pulse/)

## Адреса контрактов

Адреса **не дублируются** в этом файле специально: единственный источник, правимый руками, —
[`config/deployments/base-mainnet.json`](https://github.com/alexar76/aicom/blob/main/config/deployments/base-mainnet.json). Всё
остальное (Python-пакеты хаба и монитора, TS-клиент ARGUS) генерируется из него командой
`python scripts/sync_deployment_addresses.py`, а тест падает, если какой-то потребитель
захардкодил адрес или сгенерированная копия устарела.

Человекочитаемая запись каждой транзакции деплоя — [`docs/onchain-journal.md`](https://github.com/alexar76/aicom/blob/main/docs/onchain-journal.md).
Набор ACEX переразвёрнут **2026-08-22** после аудита безопасности (см. §2d).

## Быстрый старт

Клонируйте репозиторий сателлита, следуйте секции Quick start в [English README](../README.md), затем сверяйте термины с глоссарием.

```bash
git clone https://github.com/alexar76/acex.git
cd acex
# затем — команды из English README → Quick start
```

## Разделы English README / Sections

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

## Полный текст

Английский README остаётся каноном операторских деталей (таблицы capability, флаги CI, точные команды). Этот файл — полная локализованная витрина продукта с глоссарийными терминами.

## License

MIT — see [LICENSE](../LICENSE).
