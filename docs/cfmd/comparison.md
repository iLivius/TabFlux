# Comparing learners

TabPFN, a random forest and XGBoost in the [full run](results.md): the same 3,680
samples, five grouped folds, nested selection and tuning. Every number below comes from
that run's `metrics/` folder: log-loss as the run reports it, everything else recomputed
from the saved out-of-fold probabilities (`metrics/oof_predictions.csv`). The tables and
figures on this page come from `scripts/make_cfmd_comparison.R`, applied to the run
folder:

```bash
Rscript scripts/make_cfmd_comparison.R out/<run>_saved_learners out/comparison
```

## The decision rule

A learner returns one probability per category. Two rules turn that into a prediction:

- **largest probability**;
- **largest probability divided by the category's frequency in the training samples**:
  TabFlux's default (`evaluation.prior_correction`), applied per outer fold with that
  fold's training frequencies.

Both columns below come from the same saved probabilities, so log-loss is the same for
both rules. Mean over the five folds, ± the standard deviation across them:

| | balanced accuracy, largest probability | balanced accuracy, default rule | accuracy, largest probability | accuracy, default rule | log-loss |
|---|---:|---:|---:|---:|---:|
| TabPFN | 0.621 ± 0.118 | 0.662 ± 0.121 | 0.823 | 0.801 | 0.572 ± 0.118 |
| Random forest | 0.552 ± 0.128 | 0.626 ± 0.157 | 0.807 | 0.743 | 0.677 ± 0.163 |
| XGBoost | 0.582 ± 0.098 | 0.634 ± 0.103 | 0.805 | 0.801 | 0.565 ± 0.177 |

![Balanced accuracy of each learner under the two decision rules](../assets/cfmd_cmp_rule.png#only-light)
![Balanced accuracy of each learner under the two decision rules](../assets/cfmd_cmp_rule_dark.png#only-dark)

- The rule moves each learner more than the learners differ: +0.041 (TabPFN), +0.074
  (forest), +0.052 (XGBoost), against a gap of 0.028 between the first and second learner
  under the default rule.
- The cost is accuracy, through dairy recall: the forest loses 0.064 accuracy (dairy
  recall 0.998 → 0.843), TabPFN 0.022, XGBoost 0.004.
- **Rules must match across learners.** TabPFN has the same correction built in
  (`balance_probabilities`). With it on and the trees on the largest probability, the
  comparison reads 0.662 against 0.552 and 0.582: most of that gap comes from the rule,
  not the learner. TabFlux turns TabPFN's option off and applies its own rule to every
  learner.

## Per category

Pooled recall over the out-of-fold predictions, largest probability → default rule.

![Recall per food category for the three learners under the two decision rules](../assets/cfmd_cmp_per_class.png#only-light)
![Recall per food category for the three learners under the two decision rules](../assets/cfmd_cmp_per_class_dark.png#only-dark)

| category | n | TabPFN | random forest | XGBoost |
|---|---:|---:|---:|---:|
| `dairy` | 2,467 | 0.988 → 0.926 | 0.998 → 0.843 | 0.993 → 0.942 |
| `fermented_beverages` | 422 | 0.055 → 0.062 | 0.026 → 0.059 | 0.064 → 0.085 |
| `fruits_and_vegetables` | 224 | 0.576 → 0.580 | 0.411 → 0.688 | 0.424 → 0.558 |
| `meat` | 197 | 0.838 → 0.838 | 0.761 → 0.756 | 0.822 → 0.853 |
| `fermented_meat` | 154 | 0.825 → 0.857 | 0.481 → 0.838 | 0.701 → 0.844 |
| `fish` | 141 | 0.418 → 0.645 | 0.390 → 0.631 | 0.270 → 0.454 |
| `fermented_grains` | 75 | 0.013 → 0.240 | 0.000 → 0.320 | 0.000 → 0.253 |

- Largest probability: all three keep ≥ 0.988 of dairy and recall at most 1 of the 75
  `fermented_grains` samples.
- Default rule: `fermented_grains` 0.24–0.32, `fish` 0.45–0.65, dairy 0.84–0.94.
- The forest gains most from the rule on `fermented_meat` (0.481 → 0.838) and
  `fruits_and_vegetables` (0.411 → 0.688).
- `fermented_beverages` stays below 0.09 under both rules: most of its samples are one
  dataset that none of the learners transfers to
  ([results](results.md#per-category)).

## Per fold

![Balanced accuracy per outer fold for the three learners, default rule](../assets/cfmd_cmp_per_fold.png#only-light)
![Balanced accuracy per outer fold for the three learners, default rule](../assets/cfmd_cmp_per_fold_dark.png#only-dark)

Paired differences in balanced accuracy, default rule:

| fold | n test | TabPFN − forest | TabPFN − XGBoost |
|---|---:|---:|---:|
| 1 | 1433 | +0.052 | −0.012 |
| 2 | 487 | −0.018 | +0.059 |
| 3 | 608 | +0.002 | +0.037 |
| 4 | 552 | +0.076 | +0.077 |
| 5 | 600 | +0.068 | −0.023 |
| **mean** | | **+0.036** | **+0.028** |

- TabPFN is ahead of the forest in four folds and of XGBoost in three.
- Five paired differences from folds that share training data: too few to call a winner.
- Fold means run from 0.46 to 0.77. Which datasets are held out moves the score more than
  which learner is used.

## XGBoost's configuration

Settings that decide what XGBoost can reach here
([learners and tuning](../workflow/learners.md#tuning)):

| setting | value | why |
|---|---|---|
| tuner | random search, 80 settings (40 with `fast_tuning`) | early stopping sets the number of rounds, so there is no budget for Hyperband to grow |
| boosting rounds | early stopping on a 20 % validation slice, 10 rounds of patience, at most 1,000; final refit on the inner folds' mean | the right number depends on `eta`; early stopping finds it per fit |
| `eta` | 0.01–1, log scale | below 0.01, 1,000 rounds cannot move the model far from its starting score |
| decision rule | default rule, as for every learner | see above |

- The `eta` floor: a log-scale range reaching down to 1e-4 would put half the draws
  below 0.01, where they are wasted; the floor at 0.01 spends every draw on a rate that
  can learn within 1,000 rounds.
- With these settings XGBoost has the lowest log-loss of the three, 0.565, and the
  smallest fold-to-fold spread in balanced accuracy, ± 0.103.

## Limits of this comparison

- One run, five folds, folds that share training data. A difference of 0.03 in balanced
  accuracy is inside the fold-to-fold spread and does not rank the learners.
- The largest-probability columns are recomputed from models that were tuned and whose
  features were selected under the default rule. Tuned and selected under the
  largest-probability rule, the models could differ.
- Per-category recall rests on few datasets per category: `fermented_grains` on three,
  `fermented_beverages` mostly on one.
