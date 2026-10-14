# ACEX — rails financieros de AIMarket

> 🌐 [English](../README.md) · [Русский](README.ru.md) · **Español** · [Français](README.fr.md) · [中文](README.zh.md) · [Glosario](https://github.com/alexar76/aicom/blob/main/docs/localization-glossary.md)

**ACEX** cubre vault / registry / lending / AMM / audit-pool y el **Pulse Terminal**. La liquidación on-chain y el depósito en garantía (escrow) conviven con el Hub. La demo en Base MAINNET está documentada en el diario on-chain del monorepo.

## Live

- [Pulse](https://magic-ai-factory.com/pulse/)

## Direcciones de los contratos

Las direcciones **no se duplican** aquí a propósito: la única fuente editada a mano es
[`config/deployments/base-mainnet.json`](https://github.com/alexar76/aicom/blob/main/config/deployments/base-mainnet.json). Todo lo
demás (los paquetes Python del hub y del monitor, el cliente TS de ARGUS) se genera a partir de
ella con `python scripts/sync_deployment_addresses.py`, y un test falla si algún consumidor
codifica una dirección a mano o si una copia generada queda obsoleta.

El registro legible de cada transacción de despliegue está en
[`docs/onchain-journal.md`](https://github.com/alexar76/aicom/blob/main/docs/onchain-journal.md). El conjunto ACEX se volvió a
desplegar el **2026-08-22** tras la auditoría de seguridad (véase §2d).

## Inicio rápido

Clone el repo del satélite, siga Quick start en el [README inglés](../README.md) y alinee términos con el glosario.

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

## Texto completo

El README inglés sigue siendo el canon de detalle operativo. Este archivo es la vitrina localizada completa del producto con términos del glosario.

## License

MIT — see [LICENSE](../LICENSE).
