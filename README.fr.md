# Siphon

[🇬🇧 English](README.md) · **🇫🇷 Français**

> Un fork de [spotify/portal-ai-plugins](https://github.com/spotify/portal-ai-plugins),
> **adapté pour fonctionner sans Spotify Portal**. Même principe, mêmes prompts, mêmes
> résultats, mais il parle directement à l'API Google AI Studio (Gemini), donc une
> simple clé API suffit.

L'essentiel du travail d'un agent de code n'est pas de la réflexion, c'est de
l'entrée-sortie. Siphon intercepte la partie coûteuse et l'envoie à un modèle
d'exécution bon marché :

- **bulk-reader** : lire beaucoup de fichiers, ou de gros fichiers, et répondre à une question
- **code-writer** : générer du code répétitif calqué sur vos fichiers existants

Mesuré sur les fixtures du dépôt : un fichier de 602 lignes coûte **12 006 tokens** à
lire directement, contre **137 tokens** pour la réponse qui revient : **98 % de contexte
en moins**, en 2 secondes environ et pour un demi-centime.

Fonctionne sur **Claude Code**, et embarque les manifestes **Codex** et **Cursor**.

## Démarrage rapide

```bash
# 1. Récupérez une clé sur https://aistudio.google.com/apikey, puis :
export GEMINI_API_KEY="votre-clé"

# 2. Installez
claude plugin marketplace add BenjaminPolge/siphon
claude plugin install siphon@siphon-plugins
```

Ouvrez une nouvelle session et lancez :

```text
/siphon:setup
```

C'est tout. Dès lors, toute tentative de lire un fichier de plus de 350 lignes est
bloquée et redirigée vers Gemini automatiquement.

Un souci ? Lancez `/siphon:doctor` : il est en lecture seule et ne consomme aucun token.

## Ce qui change par rapport à l'original

L'original exigeait une instance Spotify Portal et son CLI, le modèle d'exécution étant
choisi côté serveur. Ce fork supprime entièrement cette dépendance.

| | Original | Siphon |
|---|---|---|
| Transport | `portal-cli actions aika:invoke-chat` | HTTPS direct vers `generativelanguage.googleapis.com` |
| Prérequis | une instance Portal + authentification | une clé API Gemini |
| Prompts d'exécution | « modes AiKA » côté serveur | fichiers texte dans `prompts/`, modifiables |
| Modèle | imposé par l'instance | `SIPHON_MODEL`, par défaut `gemini-2.5-flash` |
| Taille de requête | 120 Ko (le prompt passait par `argv`) | ~1 M de tokens |
| Hôtes | Claude Code | Claude Code, Codex, Cursor |
| Workflows catalogue Portal | `search`, `service`, `actions`, `feedback` | supprimés : ils interrogent un catalogue Backstage qu'aucune API ne remplace |

L'architecture en trois couches, les deux prompts d'exécution (repris mot pour mot),
l'interface en ligne de commande et la règle « un appel = un coup » sont inchangés.
C'est un changement de tuyauterie, pas de conception.

Au passage, trois bugs hérités de l'original sont corrigés : les benchmarks affichaient
une économie parfaite de 100 % quand le transport échouait ; le garde-fou shell
**laissait passer** sur tout chemin contenant une espace ; et `grep` le contournait
purement et simplement.

## Fonctionnement

Trois couches, de la barrière dure à la simple suggestion :

1. **Les hooks** bloquent les lectures qui déverseraient un gros fichier en contexte.
2. **Les scripts** effectuent l'appel à Gemini et nettoient la sortie.
3. **Les skills** indiquent à l'agent quand et comment déléguer.

L'agent n'assemble jamais de commande à partir de prose : il appelle un script avec des
arguments nommés.

### Ce qui fonctionne réellement, par hôte

| Couche | Claude Code | Codex | Cursor |
|---|---|---|---|
| Hook sur la lecture de fichiers | ✅ | ❌ **pas d'outil `Read`** | ✅ |
| Hook sur les lectures shell | ✅ | ✅ | ✅ |
| Scripts | ✅ | ✅ | ✅ |
| Skills | ✅ | ✅ | ✅ |

Vérifié de bout en bout sur Claude Code. Le support Codex et Cursor est écrit d'après
leurs documentations officielles mais **n'a pas été vérifié sur une installation
réelle**. Sur Codex, l'application restera de toute façon partielle : l'hôte n'a pas
d'outil `Read`, donc les lectures y passent par le shell.

## Prérequis

- [`jq`](https://jqlang.org): `brew install jq`
- `curl`: fourni avec macOS
- Une clé API Google AI Studio

> **Où partent vos fichiers.** Les fichiers délégués sont envoyés à l'API publique de
> Google sous votre propre clé. Si vous étiez habitué à un point d'accès opéré en
> interne, c'est un changement de destination pour votre code source, pas seulement de
> transport. Vérifiez que cela cadre avec la politique de votre organisation.

## Configuration

| Variable | Défaut | Rôle |
|---|---|---|
| `GEMINI_API_KEY` | - | Clé API |
| `GEMINI_API_KEY_FILE` | `~/.config/siphon/gemini.key` | Lu si la variable n'est pas définie |
| `SIPHON_MODEL` | `gemini-2.5-flash` | Modèle des appels délégués |
| `SIPHON_MIN_LINES` | `350` | Nombre de lignes au-delà duquel une lecture est bloquée |
| `SIPHON_PEEK_LINES` | `50` | Un compte explicite inférieur ou égal est un coup d'œil, pas une lecture massive |
| `SIPHON_THINKING_BUDGET` | `0` | Budget de réflexion de Gemini (voir ci-dessous) |
| `SIPHON_TIMEOUT_SECONDS` | `180` | Plafond par appel |

### Pourquoi la réflexion est désactivée par défaut

`gemini-2.5-flash` réfléchit d'office, et ces tokens sont facturés en sortie **et
prélevés sur le budget de la réponse**. Avec `maxOutputTokens` à 40, un test a consommé
35 tokens de réflexion et n'en a laissé qu'**un seul** pour répondre, renvoyant une
réponse tronquée. Les tâches d'exécution n'y gagnent rien. Mettez
`SIPHON_THINKING_BUDGET=-1` pour laisser le modèle décider.

## Ce qui n'est jamais délégué

- **Le débogage** : cela demande un vrai raisonnement, pas un résumé
- **L'édition** : l'agent a besoin du contenu exact ; préférez une lecture ciblée
- **Les décisions d'architecture** : le jugement reste au modèle principal

## Développement

```bash
bash plugins/siphon/evals/run.sh              # 86 tests, sans clé ni réseau
bash plugins/siphon/evals/run.sh --benchmark  # ajoute l'aller-retour réel
```

## Crédits

Écrit par Benjamin Polge pour [Le Journal du Net](https://www.journaldunet.com).

## Licence

Apache-2.0, comme le projet d'origine. Voir [`NOTICE`](NOTICE) pour l'attribution
obligatoire à Spotify AB.

Sans affiliation avec Spotify ni Google, et sans lien de parrainage. Gemini et Google AI
Studio sont des marques de Google LLC.
