# ACEX — rails financiers d’AIMarket

> 🌐 [English](../README.md) · [Русский](README.ru.md) · [Español](README.es.md) · **Français** · [中文](README.zh.md) · [Glossaire](https://github.com/alexar76/aicom/blob/main/docs/localization-glossary.md)

**ACEX** couvre vault / registry / lending / AMM / audit-pool et le **Pulse Terminal**. Le règlement on-chain et le séquestre (escrow) cohabitent avec le Hub. La démo Base MAINNET est documentée dans le journal on-chain du monorepo.

## Live

- [Pulse](https://magic-ai-factory.com/pulse/)

## Adresses des contrats

Les adresses ne sont **pas dupliquées** ici, volontairement : la seule source modifiée à la main
est [`config/deployments/base-mainnet.json`](https://github.com/alexar76/aicom/blob/main/config/deployments/base-mainnet.json). Tout le
reste (les paquets Python du hub et du moniteur, le client TS d'ARGUS) en est généré via
`python scripts/sync_deployment_addresses.py`, et un test échoue si un consommateur code une
adresse en dur ou si une copie générée est périmée.

Le relevé lisible de chaque transaction de déploiement se trouve dans
[`docs/onchain-journal.md`](https://github.com/alexar76/aicom/blob/main/docs/onchain-journal.md). L'ensemble ACEX a été redéployé le
**2026-08-22** après l'audit de sécurité (voir §2d).

## Démarrage rapide

Clonez le dépôt du satellite, suivez Quick start dans le [README anglais](../README.md), puis alignez les termes sur le glossaire.

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

## Texte complet

Le README anglais reste le canon des détails opérationnels. Ce fichier est la vitrine localisée complète du produit avec les termes du glossaire.

## License

MIT — see [LICENSE](../LICENSE).
