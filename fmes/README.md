# FMES Indicator

Indicateur TradingView (Pine v6) qui automatise le « FMES Blueprint » de Flipping Markets :
contexte H4 (tendance, fib, 0.71) + exécution 15m (sweep, displacement, MSS, fib 0.71, order block, volume gap).
À poser sur un graphique 15m.

## Modèles

- **Modèle 1 – Confirmation** : premier setup après le contact du 0.71 H4.
- **Modèle 2 – Continuation** : même séquence, plus loin dans la même tendance H4.
- **Modèle 3 – Flip du range** : clôture H4 au-delà du niveau 1 ; ordre limite direct au 0.71 de l'impulsion
  si son origine est protégée en 15m, sinon séquence de confirmation.

## Historique des modifications

### Corrections v1.1
1. Une position ouverte n'est plus effacée quand la tendance H4 s'inverse : elle est gérée jusqu'au SL ou au TP,
   dans son propre sens, et reste comptée dans les statistiques.
2. Cibles du modèle 3 alignées sur le handbook : prochain 0.71 H4 opposé, sinon structure H4 externe opposée
   (ancien comportement conservé en repli si aucune structure n'est trouvée dans l'historique).
3. Les trades du modèle 3 en ordre limite sont comptés (ligne « Pris : limite directe (modèle 3) »), avec le R réel.
4. L'alerte « setup complet » envoie le même TP2 que l'alerte « entrée » (`null` s'il n'est pas au-delà du TP1).
