# Protocole d'analyse fondamentale + technique pour agent IA

Version 1.0 — octobre 2026

Ce protocole dit à un agent IA **comment combiner les données fondamentales et les calculs techniques** pour décider s'il faut entrer sur un marché, où, avec quel stop et quelle taille. Il est construit à partir de trois cas réels étudiés (Nasdaq-100, EUR/USD, USD/CHF, août–octobre 2026), résumés en section 9.

L'agent ne cherche pas à **prédire** le marché. Il cherche à **se placer du côté le plus probable avec un risque défini à l'avance**. Une analyse correcte peut donner un trade perdant : c'est normal et prévu par la gestion du risque.

---

## 0. Règles absolues

Ces règles s'appliquent avant tout le reste. Aucune analyse ne peut les contourner.

1. **Pas de trade sans stop.** Le stop est défini avant l'entrée et n'est jamais élargi.
2. **Risque maximum de 1 % du capital par trade**, et 3 % au total sur toutes les positions ouvertes.
3. **Pas de trade contre la structure du prix**, même avec une fondamentale très forte (cas du 20 août, section 9.2).
4. **Ratio gain/risque d'au moins 2.** En dessous, pas de trade.
5. **Pas de nouvelle position dans les 30 minutes avant un événement de catégorie A** (section 2.3), sauf si le plan est explicitement un trade post-événement.
6. **Une seule exposition par devise et par direction.** Vendre EUR/USD et acheter USD/CHF revient à faire deux fois le même pari sur le dollar : ça compte comme une seule position pour le calcul du risque.
7. **En cas de doute ou de données manquantes, la décision est « ATTENDRE ».** L'agent ne comble jamais un trou de données par une supposition.

---

## 1. Données d'entrée

L'agent doit disposer de ces données avant de lancer l'analyse. Si l'une d'elles manque, il le signale dans la sortie (`donnees_manquantes`) et applique la règle 0.7 si elle est critique.

| Donnée | Unité de temps | Usage | Critique ? |
|---|---|---|---|
| Bougies OHLCV | Journalier (300 bougies) | Régime, structure, ATR | Oui |
| Bougies OHLCV | H4 et H1 (500 bougies) | Déclencheur d'entrée | Oui |
| Calendrier économique (réel, consensus, précédent) | 60 jours passés + 14 jours à venir | Surprises, événements | Oui |
| Taux directeurs et dernière décision de chaque banque centrale | — | Écart de politique monétaire | Oui |
| Rendements obligataires à 2 ans des deux zones | Journalier | Écart de taux | Non (recommandé) |
| Actualités (titres, horodatage) | 7 derniers jours | Contexte, chocs imprévus | Non (recommandé) |
| Indice dollar (DXY), or, Nasdaq, VIX | Journalier | Sentiment de risque, corrélations | Non (recommandé) |

---

## 2. Étape 1 : analyse fondamentale

L'objectif est de produire un **score fondamental F entre −3 et +3** pour chaque devise ou actif, puis un score de paire.

### 2.1 Score de surprise économique (S)

Pour chaque publication des 30 derniers jours :

```
z = (Réel − Consensus) / σ_surprise
```

- `σ_surprise` est l'écart-type historique des surprises de cet indicateur (au moins 24 publications). S'il n'est pas disponible, utiliser `|Précédent − Consensus|` moyen comme approximation et le signaler.
- Le signe est **orienté devise** : un chiffre qui pousse la banque centrale à monter ses taux est positif (emploi fort, inflation haute, activité forte). Pour le chômage, inverser le signe.
- Pondérer par l'importance : catégorie A = 3, B = 2, C = 1 (voir 2.3).
- Les publications plus anciennes pèsent moins (demi-vie de 10 jours).

```
S = Σ(z × poids × e^(−âge_jours × ln2 / 10)) / Σ(poids × e^(−âge_jours × ln2 / 10))
```

Lecture : S > +1 est un flux de données nettement fort, S < −1 nettement faible.

> Exemple réel : emploi américain d'août à 162k contre 56k attendus, une surprise d'environ +2σ sur un indicateur de catégorie A.

### 2.2 Score de politique monétaire (M)

| Situation de la banque centrale | M |
|---|---|
| Vient de monter ses taux, ou le marché anticipe une hausse | +2 |
| Ton ferme (« hawkish »), sans action | +1 |
| Neutre, en pause | 0 |
| Ton accommodant (« dovish ») | −1 |
| Vient de baisser ses taux, ou le marché anticipe une baisse | −2 |

Ajouter **+1 / −1** si l'écart de taux à 2 ans entre les deux zones a bougé de plus de 15 points de base en faveur / en défaveur de la devise sur 20 jours.

### 2.3 Classement des événements

| Catégorie | Événements | Poids |
|---|---|---|
| A | Décision de taux, inflation (CPI, PCE), emploi (NFP), conférence de presse d'un président de banque centrale | 3 |
| B | PMI/ISM, ventes au détail, PIB, indices régionaux (Philly Fed…), discours de membres votants | 2 |
| C | Immobilier, confiance des ménages, balance commerciale, autres | 1 |

### 2.4 Sentiment de risque (R)

Utile pour les valeurs refuges (CHF, JPY, or) et les indices actions.

- **Risque en hausse** (aversion) : VIX en hausse de plus de 20 % sur 5 jours, ou Nasdaq en baisse de plus de 3 % sur 5 jours.
- Dans ce cas : R = +1 pour CHF, JPY et l'or, R = −1 pour les indices actions et les devises liées aux matières premières (AUD, NZD, CAD).
- Sinon R = 0.

### 2.5 Score fondamental

```
F_devise = clamp( 0,5 × S + 0,4 × M + 0,1 × 3 × R , −3 , +3 )
F_paire  = clamp( F_base − F_cotation , −3 , +3 )
```

Pour EUR/USD, la base est EUR et la cotation USD : un dollar fort donne un F_paire négatif, donc un biais vendeur.

| F_paire | Biais fondamental |
|---|---|
| ≥ +1,5 | Acheteur |
| entre −1,5 et +1,5 | Neutre : pas de trade fondamental |
| ≤ −1,5 | Vendeur |

### 2.6 Test « déjà dans les prix »

Avant de valider le biais, vérifier si le marché a déjà intégré l'information :

```
Mouvement_anticipé = variation du prix sur les 10 dernières séances / ATR journalier
```

- Si le biais est vendeur et que le prix a déjà baissé de plus de 4 ATR sur 10 séances, **ou** si l'événement attendu est connu de tous (consensus unanime), marquer `deja_price = true`.
- Avec `deja_price = true`, l'agent **ne poursuit pas le mouvement**. Il attend un repli (section 4.1) ou la réaction post-événement (section 4.3).

> Cas réel : le Nasdaq a baissé avant la hausse de taux de la Fed du 16 septembre, attendue par tous, puis il a rebondi dès l'annonce (section 9.1).

### 2.7 Réaction à la nouvelle

Après chaque événement de catégorie A ou B, mesurer :

```
Réaction = mouvement du prix 30 minutes après la publication / ATR H1
```

| Surprise (z) | Réaction | Interprétation |
|---|---|---|
| Forte (abs ≥ 1) | Même sens, ≥ 1 ATR | Confirmation : renforce le biais |
| Forte | Faible (< 0,5 ATR) | Déjà dans les prix, ou le marché n'y croit pas |
| Forte | Sens opposé | **Signal d'alerte fort** : le marché regarde autre chose. Passer le biais à neutre |

---

## 3. Étape 2 : analyse technique

L'objectif est de produire un **score technique T entre −3 et +3**, calculé en journalier, puis de chercher un déclencheur en H4 ou en H1.

### 3.1 Calculs à effectuer

| Indicateur | Paramètres | Formule ou définition |
|---|---|---|
| EMA | 20, 50, 200 | Moyenne mobile exponentielle des clôtures |
| ATR | 14 | Moyenne du True Range = max(H−B, abs(H−C_préc), abs(B−C_préc)) |
| ADX | 14 | Force de tendance (méthode de Wilder) |
| RSI | 14 | Méthode de Wilder |
| MACD | 12, 26, 9 | EMA12 − EMA26, signal = EMA9 du MACD |
| Swings | N = 3 | Sommet de swing : le plus haut des 3 bougies avant et des 3 bougies après. Même logique pour un creux |

### 3.2 Score technique

| Composante | +1 | 0 | −1 |
|---|---|---|---|
| **Régime** | Clôture > EMA200 et EMA50 > EMA200 | Situation mixte | Clôture < EMA200 et EMA50 < EMA200 |
| **Structure** | Les 2 derniers creux et sommets de swing sont de plus en plus hauts | Mixte | Les 2 derniers sommets et creux de swing sont de plus en plus bas |
| **Élan** | Clôture > EMA20 et MACD > signal | Mixte | Clôture < EMA20 et MACD < signal |

```
T = Régime + Structure + Élan          (de −3 à +3)
```

### 3.3 Qualificateurs

- **ADX < 20 : régime de range.** Le score T est ramené à zéro sauf sur la composante Structure, et on ne joue que les cassures (section 4.2).
- **ADX > 25 : tendance.** On privilégie les replis (section 4.1).
- **RSI > 70 en biais acheteur, ou RSI < 30 en biais vendeur : excès.** Interdiction d'entrer au marché, on attend un repli.
- **Divergence** : le prix fait un nouveau sommet (ou creux) mais le RSI non. On n'entre pas dans le sens de la tendance, on prend une partie des gains sur les positions existantes.

### 3.4 Niveaux clés à calculer

- Plus haut et plus bas de la veille, de la semaine et du mois précédents.
- Les 3 derniers sommets et creux de swing en journalier.
- Les bornes du range s'il y en a un : un range existe si `(plus haut − plus bas) des 15 dernières bougies < 1,5 × ATR × √15`.
- Les niveaux ronds (par exemple 1,1500 ou 0,8400).

---

## 4. Étape 3 : déclencheurs d'entrée

Un trade n'est envisagé que si **le biais fondamental et le score technique vont dans le même sens** (section 5). Ensuite, l'agent cherche **un** des trois déclencheurs suivants en H4 ou en H1.

### 4.1 Repli dans la tendance (déclencheur préféré)

Conditions :
1. Le prix revient dans une zone de résistance pour un vendeur (support pour un acheteur) : EMA20 journalière, ancien niveau cassé ou dernier sommet de swing.
2. Une bougie de rejet se forme en H1 ou en H4 : mèche dans la zone supérieure ou égale à 50 % de la taille totale de la bougie, clôture dans le sens du biais.
3. Entrée à la clôture de cette bougie, ou par un ordre limite dans la zone.

> Cas réel : vente de l'EUR/USD vers 1,1640 le 9 septembre, sur un sommet plus bas sous le double top de 1,1712.

### 4.2 Cassure de range

Conditions :
1. Un range est identifié (section 3.4).
2. Clôture en dehors du range avec un corps de bougie d'au moins 0,7 ATR.
3. Entrée en deux moitiés : 50 % à la clôture de la cassure, 50 % sur un éventuel retest de la borne cassée. Si le retest ne vient pas dans les 5 bougies, la seconde moitié est annulée.

> Cas réel : cassure du bas du range de l'EUR/USD (1,1566) le 14 septembre. Le retest n'est jamais venu, d'où l'intérêt d'entrer en deux fois.

### 4.3 Trade post-événement

Conditions :
1. Événement de catégorie A.
2. Attendre 15 à 30 minutes après la publication.
3. Si la réaction (section 2.7) va dans le sens du biais et dépasse 1 ATR H1 : entrer sur le premier repli en M15 ou en H1.
4. Si le marché réagit à l'inverse d'une bonne surprise : ne pas trader, et réévaluer le biais.

> Cas réel : le 16 septembre, la hausse de taux de la Fed a fait chuter l'EUR/USD de 0,7 % et monter l'USD/CHF de 0,85 %, alors que le Nasdaq a rebondi le lendemain.

---

## 5. Étape 4 : matrice de décision

| F_paire | T | Décision | Taille |
|---|---|---|---|
| ≥ +1,5 | ≥ +2 | **ACHAT** sur déclencheur | 100 % du risque autorisé |
| ≥ +1,5 | +1 | ACHAT seulement sur repli (4.1) | 50 % |
| ≥ +1,5 | ≤ 0 | **ATTENDRE** : fondamentale pas encore confirmée par le prix | — |
| entre −1,5 et +1,5 | n'importe lequel | **ATTENDRE** (ou trading purement technique hors protocole) | — |
| ≤ −1,5 | ≥ 0 | **ATTENDRE** | — |
| ≤ −1,5 | −1 | VENTE seulement sur repli (4.1) | 50 % |
| ≤ −1,5 | ≤ −2 | **VENTE** sur déclencheur | 100 % |

Modificateurs qui s'appliquent après la matrice :
- `deja_price = true` : seuls les déclencheurs 4.1 et 4.3 sont autorisés.
- Événement de catégorie A dans les 24 heures : taille × 0,5.
- ATR actuel > 1,5 × ATR moyen sur 50 jours : taille × 0,5.
- Réaction opposée à une forte surprise dans les 48 dernières heures : **ATTENDRE**.

### 5.1 Choix de la paire

Quand un scénario touche une devise (par exemple « dollar fort »), l'agent calcule F pour toutes les paires concernées et choisit celle où **|F_paire| est le plus élevé ET le score T va dans le même sens**.

Il évite d'opposer la devise forte à une valeur refuge (CHF, JPY) quand R > 0 : le statut de refuge freine le mouvement.

> Cas réel : avec le même scénario « dollar fort », l'EUR/USD a continué de baisser en octobre, alors que l'USD/CHF a été rejeté sur 0,8382 le 1er octobre (section 9.3).

---

## 6. Étape 5 : stop, objectifs et taille

### 6.1 Stop

```
Stop vendeur = dernier sommet de swing significatif + 0,5 × ATR
Stop acheteur = dernier creux de swing significatif − 0,5 × ATR
```

- Si la distance du stop dépasse 3 ATR, le trade est trop large : **ATTENDRE** un meilleur point d'entrée.
- Le stop est aussi **fondamental** : il faut sortir si un événement de catégorie A contredit le scénario (surprise d'au moins 1,5σ dans le sens opposé), même si le stop technique n'est pas touché.

### 6.2 Objectifs

- **Objectif 1** : le prochain niveau clé (section 3.4) ou 2 × la distance du stop. On encaisse 50 % de la position.
- **Objectif 2** : le niveau clé suivant, ou on laisse courir avec le stop suiveur.
- Si l'objectif 1 donne un ratio gain/risque inférieur à 2 : pas de trade (règle 0.4).

### 6.3 Taille de position

```
Taille (lots) = (Capital × Risque%) / (Distance_stop_en_pips × Valeur_du_pip_par_lot)
```

`Risque%` = 1 % × les multiplicateurs de la section 5.

### 6.4 Gestion de la position

- **Après l'objectif 1** : stop ramené au point d'entrée.
- **Stop suiveur** : à chaque nouveau sommet de swing plus bas (pour un vendeur), le stop descend au-dessus de ce sommet + 0,5 ATR.
- **Sortie complète** si la structure se casse (un sommet plus haut pour un vendeur), si F_paire repasse en neutre, ou si le score T change de signe.

---

## 7. Format de sortie

L'agent produit une réponse JSON par actif analysé, suivie d'un résumé en une phrase.

```json
{
  "actif": "FX:EURUSD",
  "date_analyse": "2026-09-14T21:00:00Z",
  "fondamental": {
    "S_base": -0.3, "S_cotation": 1.4,
    "M_base": 0, "M_cotation": 2,
    "R": 0,
    "F_paire": -2.1,
    "biais": "vendeur",
    "deja_price": false,
    "evenements_a_venir": [{"nom": "Décision Fed", "categorie": "A", "dans_heures": 45}]
  },
  "technique": {
    "regime": -1, "structure": -1, "elan": -1, "T": -3,
    "adx": 18.5, "rsi": 41.0, "atr": 0.0062,
    "niveaux": {"resistance": [1.1654, 1.1712], "support": [1.1500, 1.1450]},
    "range": {"haut": 1.1654, "bas": 1.1566, "casse": "bas"}
  },
  "decision": "VENTE",
  "declencheur": "cassure_range",
  "entree": 1.1550,
  "stop": 1.1685,
  "objectifs": [1.1280, 1.1150],
  "ratio_gain_risque": 2.0,
  "risque_pct": 0.5,
  "modificateurs": ["evenement_A_sous_24h → taille x0.5"],
  "invalidation": "Clôture journalière au-dessus de 1,1654 ou inflation US sous le consensus de plus de 1,5σ",
  "donnees_manquantes": [],
  "confiance": "moyenne"
}
```

Les valeurs de ce JSON sont **un exemple de format**. Elles reprennent la situation de l'EUR/USD au 14 septembre, mais les scores S, M, ADX et RSI y sont illustratifs.

Règles de rédaction :
- `confiance` vaut « haute » seulement si |F_paire| ≥ 2, |T| = 3 et aucun modificateur négatif ne s'applique.
- `invalidation` est **toujours** renseignée, en une phrase compréhensible par un humain.
- L'agent ne présente jamais une décision comme une certitude.

---

## 8. Journal et apprentissage

Chaque analyse est enregistrée, même quand la décision est « ATTENDRE ».

À la clôture de chaque trade, l'agent ajoute au journal :
- le résultat en R (multiples du risque initial : +2R, −1R…) ;
- si le scénario fondamental s'est vérifié, indépendamment du résultat ;
- le déclencheur utilisé.

Toutes les 30 transactions, il calcule :

```
Espérance = (taux_reussite × gain_moyen_R) − (taux_echec × perte_moyenne_R)
```

- Statistiques séparées par déclencheur (4.1, 4.2, 4.3), par actif et par niveau de confiance.
- Si un déclencheur a une espérance négative sur 30 trades ou plus, il est suspendu et signalé à l'humain.
- **Les paramètres du protocole ne sont jamais modifiés par l'agent seul.** Il propose les changements avec les statistiques à l'appui, et un humain valide.

---

## 9. Cas de référence pour calibrer l'agent

Ces trois cas viennent de données réelles (TradingView, août–octobre 2026). Ils servent d'exemples d'application du protocole. Ils ont été choisis après coup : ils montrent la méthode, pas un taux de réussite.

### 9.1 Nasdaq-100 : baisse de 30 000 à 28 753 (17 août – 16 septembre)

- **Fondamentale** : emploi fort (162k contre 56k), inflation qui repart (+0,4 % sur un mois), hausse de taux de la Fed le 16 septembre (3,75 % → 4 %), attendue par tous.
- **Ce que le protocole aurait fait** : biais vendeur sur les actions tech, mais `deja_price = true` à l'approche de la Fed, puisque la hausse était le consensus. Donc **pas de vente poursuivie** dans les derniers jours.
- **Résultat** : le creux est tombé le jour de la décision, puis +1,7 % le lendemain et +2,8 % le 21 septembre. Un vendeur tardif aurait été piégé.
- **Leçon codée dans le protocole** : section 2.6 (déjà dans les prix) et section 4.3 (trade post-événement).

### 9.2 EUR/USD : de 1,1712 à 1,1152 (20 août – 12 octobre)

- **Le sommet du 20 août n'était pas prévisible** : les chiffres américains des jours précédents étaient faibles (ventes au détail −0,6 %, mises en chantier sous le consensus). Le biais fondamental était plutôt acheteur au moment exact du sommet.
- **Premier signal contraire** : Philly Fed à 47,4 contre 25 attendu le 20 août. Une seule surprise ne suffit pas à retourner F.
- **Signal fondamental validé début septembre** : emploi +2σ, inflation et prix à la production qui accélèrent. F_paire devient nettement vendeur. Le prix était encore vers 1,1613–1,1633 : il n'avait pas réagi.
- **Confirmation technique** : sommet plus bas à 1,1654 (9 septembre) sous le double top à 1,1712, puis cassure du range à 1,1566 le 14 septembre.
- **Trades types** :
  - repli : vente à 1,1640, stop à 1,1720, soit environ 80 pips de risque et environ +485 pips au 12 octobre ;
  - cassure : vente à 1,1550, sans retest.
- **Leçons codées** : règle 0.3 (pas de trade contre la structure), matrice de la section 5 (attendre que T confirme F), entrée en deux fois sur cassure (4.2).

### 9.3 USD/CHF : de 0,7950 à 0,8382 (20 août – 1er octobre)

- **Miroir de l'EUR/USD** : creux le 20 août, même moteur (Fed à 4 % contre BNS à 0 %, maintenue le 24 septembre).
- **Particularité de valeur refuge** : le 19 août, le franc s'est apprécié deux fois plus que l'euro face au dollar (−1,8 % sur l'USD/CHF contre +0,9 % sur l'EUR/USD). Le 1er octobre, rejet sur 0,8382 avec le plus gros volume de la période, alors que l'EUR/USD continuait de baisser.
- **Leçons codées** : composante R (section 2.4) et choix de la paire (section 5.1). Pour jouer « dollar fort », la paire contre la devise la plus faible (l'euro) a mieux fonctionné que contre la valeur refuge (le franc).

---

## 10. Résumé de la procédure

```
1. Vérifier les règles absolues (section 0) et les données (section 1)
2. Calculer F_paire (section 2) → biais acheteur / vendeur / neutre
3. Tester « déjà dans les prix » et la réaction aux dernières nouvelles
4. Calculer T (section 3) et les niveaux clés
5. Appliquer la matrice de décision (section 5) et choisir la meilleure paire
6. Chercher un déclencheur (section 4)
7. Calculer stop, objectifs, ratio et taille (section 6)
8. Produire la sortie JSON (section 7) avec l'invalidation
9. Journaliser (section 8)
```

> Ce protocole est un outil d'aide à la décision. Il ne garantit aucun résultat et ne constitue pas un conseil en investissement. Il doit être testé sur l'historique, puis sur un compte de démonstration, avant toute utilisation avec de l'argent réel.
