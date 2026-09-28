# Explaining a model

`importance.method` decides how the best final model is explained: `shap`, `perm`, or
`none` to skip the step entirely.

## SHAP

For every explained sample, a Shapley value gives each taxon a share of the difference
between the model's prediction for that sample and the average prediction: positive when
the taxon pushed the sample towards the class being explained, negative when it pushed
away. The values are computed with the `iml` package on the best model from the
benchmark, never on a model that saw a test set.

| file | contents |
|---|---|
| `metrics/shap_values.csv` | long format: one row per explained sample × taxon × class, with the Shapley value (`phi`), the raw count, the proportion and the value the model saw (`value_model`) |
| `metrics/shap_importance.csv` | the global ranking: mean absolute contribution per taxon (`mean_abs_phi`) |
| `metrics/shap_class_contributions.csv` | one row per taxon × class: `mean_phi`, `mean_abs_phi`, `direction_rho`, `direction` |
| `figures/importance_shap.png` | the global ranking as bars |
| `figures/importance_by_class.png` | the most influential taxa of each class, with their direction |

### The per-class figure

A Shapley value is measured against the average prediction. Over the explained samples a
taxon's pushes towards a class and away from it largely cancel, so the signed mean
(`mean_phi`) is close to zero even for a taxon that moves the prediction a lot: it is
not a direction, and ranking by it hides the strongest taxa. The figure and the class
table therefore separate strength from direction:

- **strength**, `mean_abs_phi`: the mean absolute Shapley value, how far the taxon moves
  the class probability on average, up or down. It is the bar length.
- **direction**, `direction_rho`: the Spearman correlation, over the explained samples,
  between the taxon's value as the model saw it (`value_model`) and its Shapley value for
  that class. It sets the bar colour: blue for "more of it: higher P(class)" (ρ ≥ 0), red
  for "more of it: lower P(class)" (ρ < 0), grey for "no variation", when the taxon's
  value or its Shapley value is the same in every explained sample and ρ is undefined.

On a multi-class target the figure has one panel per class, each showing that class's
five strongest taxa; the x axis is shared, so bar lengths compare across panels. On a
binary target the two classes mirror each other, so one panel shows the ten strongest
taxa for the positive class. The [case study](../cfmd/results.md#which-taxa) shows the
figure on seven food categories.

!!! note "Why SHAP rather than the forest's own importance"

    Impurity importance says which taxa the model used, not in which direction, and it
    favours abundant features. A Shapley value is a signed contribution per sample, so
    its relation to the taxon's value says whether the taxon is associated with a
    class or with its absence.

### Cost, and how to bound it

Shapley values are computed by permuting features many times per sample, so the cost
grows with samples × taxa × permutations. These settings bound it:

- `importance.shap_sample_size` (default 100): how many permutation draws back each
  Shapley value — more draws, less noise, proportionally more time.
- `importance.shap_max_rows` (default 300): how many training samples are explained, for
  any learner; the cost grows with samples × taxa × classes.
- `importance.tabpfn_shap_sample_size` (default 10) and `tabpfn_shap_max_rows`
  (default 20): tighter values of the same two for TabPFN. The shipped configs raise
  them to 25 and 100. TabPFN's predictions run through a fresh Python process per call,
  which makes every call expensive: SHAP on TabPFN can take an hour or more per
  taxonomic level.
- `importance.levels`: in a multi-level run, restrict the step to the levels you will
  report, e.g. `[family, genus]`. Empty means every level.

## Permutation importance

`perm` shuffles one feature at a time and records how much a metric drops. It is cheaper
and works for any model, but it is unsigned: it says a taxon matters, not for which
class. Output: `metrics/permutation_importance.csv`.

## Reading the result

For a binary target the direction is oriented on `dataset.positive_class`. For a
multi-class target the per-class figure and table are the ones to read: the global
ranking says which taxa the model uses, the class table says for which class and in
which direction.
