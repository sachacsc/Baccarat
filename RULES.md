# Règles du Baccarat 3-Boards

> Variante maison de poker à 3 boards. Source de vérité : ce document + le code dans `index.html`.

## Vue d'ensemble

- **Jeu** : 1 deck de 52 cartes standard
- **Joueurs** : 2 à 8 joueurs actifs par manche (10 connectés max, les surnuméraires sont spectateurs)
- **Modes** :
  - **Compteur** : on joue avec de vraies cartes physiques, l'app gère uniquement les comptes
  - **Online** : l'app distribue les cartes virtuellement aux téléphones

## Distribution

Total visible par manche : 3 cartes brûlées + 5 cartes × 3 boards + cartes en main.

| Nb joueurs actifs | Cartes par joueur |
|-------------------|-------------------|
| 2 – 5             | 6                 |
| 6                 | 6 (4 joueurs) + 5 (2 joueurs) — round-robin |
| 7 – 8             | 4                 |
| > 8               | non supporté (les 9è / 10è restent spectateurs) |

Le donneur est servi **en dernier**, distribution circulaire en commençant après lui. Le donneur tourne à chaque manche (cercle).

### Le board

1. **Burn 1** carte → puis **flop** : le donneur sert d'abord 3 cartes sur le Board 1, puis 3 sur le Board 2, puis 3 sur le Board 3 (= 9 cartes)
2. **Burn 1** carte → puis **turn** : 1 carte sur le Board 1, puis 1 sur le Board 2, puis 1 sur le Board 3 (= 3 cartes)
3. **Burn 1** carte → puis **river** : pareil pour les rivers (= 3 cartes)

Chaque board fait donc 5 cartes au final. Les 3 boards sont indépendants — chaque joueur "joue" les 3 successivement.

#### Ordre exact des cartes piochées

Si on numérote les 15 cases du tableau communautaire ainsi :

```
Board 1 : c1=1  c2=2  c3=3  c4=4  c5=5
Board 2 : c1=6  c2=7  c3=8  c4=9  c5=10
Board 3 : c1=11 c2=12 c3=13 c4=14 c5=15
```

L'ordre de distribution depuis le deck (après les mains) est :

```
[burn] 1,2,3 6,7,8 11,12,13   [burn] 4,9,14   [burn] 5,10,15
        └─── flop ────┘            turn          river
```

Autrement dit : **board par board pendant le flop**, puis **une carte par board** au turn et au river. (À NE PAS confondre avec un dealing "column-major" où on poserait 1 carte sur chaque board avant de revenir au premier — ce n'est PAS le pattern utilisé.)

## Annonces et catégories

À chaque board, chaque joueur encore en lice **annonce** une catégorie qu'il pense pouvoir réaliser avec ses 2 cartes (sur ses 4-6) + les 5 cartes du board.

Les 10 catégories, classées de la plus faible à la plus forte :

| # | ID                | Nom                  | Multiplicateur de paiement |
|---|-------------------|----------------------|----------------------------|
| 0 | `highcard`        | Hauteur              | ×1                         |
| 1 | `pair`            | Paire                | ×1                         |
| 2 | `twopair`         | Double paire         | ×1                         |
| 3 | `trips`           | Brelan               | ×1                         |
| 4 | `straight`        | Suite                | ×1                         |
| 5 | `flush`           | Couleur              | ×1                         |
| 6 | `fullhouse`       | Full                 | ×1                         |
| 7 | `quads`           | Carré                | ×8                         |
| 8 | `sflush`          | Quinte flush         | ×16                        |
| 9 | `royal`           | Quinte flush royale  | ×20                        |

À noter : Full est à ×1 (différent du poker classique), seuls Carré et au-dessus déclenchent un multiplicateur.

**Skip** : un joueur peut renoncer à annoncer ce board → il ne gagne ni perd dessus (sauf full-board).

**Bluff** : si un joueur annonce une catégorie qu'il ne peut **pas** réaliser → il est éliminé du board courant et **perd** quand même (paie la mise de base × multi du gagnant).

### Reveal et gagnant

Une fois toutes les annonces faites :
1. Le joueur avec la **catégorie la plus haute** gagne (Royale > Quinte flush > … > Hauteur)
2. À catégorie égale, on compare les **ranks** (Carré d'As bat Carré de Rois, etc., kicker à kicker)
3. Si tout est égal → **split** (voir ci-dessous)

**Multi appliqué** : le multi de la catégorie annoncée par le gagnant. Par exemple, si le gagnant annonce "Carré" → multi ×8 pour ce board.

### Auto-pick vs sélection manuelle

- **Hauteur** : auto-pick par défaut — l'app choisit les 2 meilleures cartes du joueur. Pas besoin de sélectionner.
- **Toutes les autres** : sélection manuelle obligatoire de **1 ou 2 cartes**. Une seule carte peut suffire si elle complète déjà l'annonce avec le board (ex. un Valet pour une suite déjà presque max sur le board).

## Scoring

### Board normal (1 gagnant)

Soit :
- `prix` = prix de la ligne (configurable, ex. 0,50 €)
- `multi` = multi de la catégorie annoncée par le gagnant
- `N` = nombre de joueurs actifs

Alors :
- Le **gagnant** reçoit `prix × multi × (N - 1)`
- Chaque **autre joueur** (perdant, skip, bluff, forfait) paie `prix × multi`

### Split (égalité au top)

Quand 2+ joueurs annoncent la même catégorie avec la même force, le board passe en **tie-break** différé (en fin de manche).

**Le tie-break** :
- Un nouveau board de 5 cartes est tiré depuis le `tiebreakPool` (3 brûlées + cartes non distribuées, mélangées)
- Les splitters re-annoncent **avec leur main complète** (2 cartes parmi leurs 4-6)
- Itération possible (re-split → nouveau board) jusqu'à départager
- Les **bluffeurs en tie-break** sont exclus à jamais des itérations suivantes

**Paiement au tie-break** :
- Le **gagnant final** récupère :
  - `prix × multi_TB` de chaque autre **splitter**
  - `prix × 1` de chaque **non-splitter**
- Les splitters non-gagnants paient au **multi du tie-break** (souvent ×1 sauf si gros set de cartes)
- Les non-splitters paient au **multi base** (×1)

### Board abandonné

Si après plusieurs rebid rounds aucun joueur ne peut annoncer valide → board abandonné. Personne ne gagne, personne ne perd.

### Full Board (bonus de manche)

Si un **même joueur gagne les 3 boards** d'une manche → bonus "Full Board" :
- Le gagnant reçoit `prix × (N - 1)` (au multi ×1)
- Chaque autre joueur paie `prix × 1`

Le tie-break compte : si tu gagnes B1 normal, splittes B2 puis remportes le TB, puis gagnes B3 → c'est un full board.

## Phases d'une manche (online)

1. **`dealing`** — distribution animée des cartes (3 paires de 2s pour la suspense)
2. **`flop`** → flip des cartes flop des 3 boards (animation cascade)
3. **`announcing`** (Board 1) → chacun annonce + sélectionne ses cartes
4. **`board-reveal`** (Board 1) → comparaison des annonces, paiements
5. Répéter `announcing` + `board-reveal` pour Board 2 et Board 3
6. Si splits → `tiebreak-announcing` / `tiebreak-reveal` pour chaque board splitté
7. **`manche-end`** → résolution full board, scores mis à jour, donneur tourne

## Mode Flash (online uniquement)

Pour pimenter le jeu, le mode Flash :
- 4 cartes sont **face cachée** chez chaque joueur (lui-même peut cliquer pour les retourner secrètement)
- Les **dernières cartes** distribuées (1 ou 2 selon la taille de main) sont **publiques** pour tout le monde

Visuellement :
- 6 cartes par joueur → 4 cachées + 2 publiques
- 5 cartes par joueur → 4 cachées + 1 publique
- 4 cartes par joueur → 4 cachées + 0 publique (= mode standard, Flash inactif)

## Timer (optionnel, online)

Configurable par l'hôte au lobby : 0 (désactivé), 20, 30, 45, 60, 90 secondes par phase d'annonce. À expiration, les annonces non soumises sont marquées `__timeout__` (équivalent skip).

## Déconnexions

- Si un joueur se déco pendant une manche → il est marqué `forfeitFromBoard = currentBoard`, ses paiements à venir restent dus (loser sur ce board + suivants)
- S'il revient avant la fin → le flux de reconnexion par pseudo réassigne son peerId à son slot existant et migre ses données (main, soumissions, etc.)
- Si l'hôte se déco → host handoff : un autre joueur prend le rôle (le peerId est dérivé du code de la partie, donc stable)

## Comptes (Counter mode)

Pour 4 joueurs avec prix 0,50 €/ligne, manche typique :
- **Board 1** : Alice gagne en Paire (×1) → Alice +1,50 € ; les 3 autres −0,50 €
- **Board 2** : Bob gagne en Carré (×8) → Bob +12 € ; les 3 autres −4 €
- **Board 3** : Charlie gagne en Suite (×1) → Charlie +1,50 € ; les 3 autres −0,50 €
- Pas de full board (3 gagnants différents).
- **Delta net** : Alice +0,50, Bob +7, Charlie −3, Daniel −4,50 → somme = 0 ✓

## Tableaux de référence rapide

### Cartes utilisées par manche (sur 52)

| Joueurs | Mains | Brûles | Boards | Total servi | Reste (pool TB) |
|---------|-------|--------|--------|-------------|-----------------|
| 4       | 24    | 3      | 15     | 42          | 10              |
| 5       | 30    | 3      | 15     | 48          | 4               |
| 6       | 34    | 3      | 15     | 52          | 0               |
| 7       | 28    | 3      | 15     | 46          | 6               |
| 8       | 32    | 3      | 15     | 50          | 2               |

À 6 joueurs c'est le maximum théorique en 6 cartes/main : tout le deck est utilisé, le pool tie-break est limité aux 3 brûles uniquement.

### Force d'une catégorie

```
Royale > Quinte flush > Carré > Full > Couleur > Suite > Brelan > Double paire > Paire > Hauteur
```

À catégorie égale, on compare les ranks (kickers). Exemple Carré :
- Carré d'As bat Carré de Rois
- Carré de Rois avec kicker As bat Carré de Rois avec kicker Dame
