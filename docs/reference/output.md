# Output files

Each render writes one self-describing run folder,
`<date>_<id>_<version>_target_<target>_tax_<level>_saved_learners/`, in the project
root or under `output.dir`. If you open only two things: the HTML report, and
`metrics/lodo_metrics.csv` (or `external_test_metrics.csv` when a test set is
configured). The "written by" column names the notebook section, which you can search
for in the report.

## The report

`tabflux_<version>_<level>.html`, the self-contained report with every figure and
table. The wrapper writes it next to the run folder, in `output.dir` (the project root
when empty), not inside it. A direct `quarto render analysis/tabflux.qmd` writes
`analysis/tabflux.html` instead.

## The run folder

| file | what it holds | written by |
|---|---|---|
| `<method>_tuned_learner.rds`, `<method>_tuned_instance.rds` | the final tuned learner and its tuning archive; reused on re-render | Train models |
| `timings.csv` | wall clock per learner for the final models | Train models |
| `outer_fold_NN/` | one folder per outer fold: that fold's `predictions_<method>.rds` and, in a nested run, its `selected_features.csv` (when feature selection is on), `<method>_tuned_*.rds` and `timings.csv`. It is the resume cache: a rerun skips every fold whose predictions are there | Benchmark |
| `feature_name_map.csv` | original taxon name → model-safe column name | Import Data |
| `normalization.json`, `reference_features.csv` | the normalisation settings and the full pre-selection feature space, for aligning new data | Normalize Abundances |
| `calibration.json` | the Platt correction fitted on the out-of-fold probabilities, for rescaling probabilities on new data; written whenever `calibration: platt` is set on a binary target, external test set or not | Benchmark |
| `metrics/selected_features.csv` | the taxa kept by feature selection | Feature Selection |
| `metrics/benchmark_metrics.csv` | fold-averaged metrics per method | Save Metrics |
| `metrics/benchmark_metrics_spread.csv` | mean and standard deviation of every metric across the outer folds | Benchmark |
| `metrics/fold_metrics.csv` | one row per method × fold, with the test-set class counts | Benchmark |
| `metrics/lodo_metrics.csv` | the fold rows labelled with the held-out group (grouped designs) | Benchmark |
| `metrics/oof_predictions.csv` | every sample's out-of-fold prediction by every method: name, group, truth, response, probabilities, right or wrong | Benchmark |
| `metrics/per_class_recall_oof.csv` | per-class recall, one column per method, with what each class is mistaken for; the last row is the mean, which is balanced accuracy | Benchmark |
| `metrics/predictions.csv` | the out-of-fold prediction of the best method only | Benchmark |
| `metrics/timings.csv` | wall clock per learner for the final models and for every outer fold, gathered from the `timings.csv` files above, plus the outer loop as a whole, in seconds and minutes | Benchmark |
| `metrics/test_metrics.csv` | scores on the internal test set (`evaluation.test_split > 0`) | Save Metrics |
| `metrics/test_predictions.csv`, `test_metrics_by_group.csv` | predictions and per-group scores on the internal test set | Prediction |
| `metrics/per_class_recall_test.csv`, `per_class_recall_external.csv` | the same per-class table for the internal and external test sets | Prediction, External Test Set |
| `metrics/performance_metrics_wide.csv`, `_long.csv`, `.rds` | training and test scores stamped with level, target and counts; the long file is what the wrapper stacks; the `.rds` bundles every table, intervals included | Save Metrics |
| `metrics/external_predictions.csv` | probabilities and quality control for every external sample | External Test Set |
| `metrics/external_test_metrics.csv`, `_by_group.csv`, `_ci.csv` | scores on the labelled external samples, overall, per group, with bootstrap intervals | External Test Set |
| `metrics/external_calibration.csv` | balanced accuracy on the external samples at the raw and at the calibrated threshold | External Test Set |
| `metrics/shap_values.csv` | one row per explained sample × taxon × class: the SHAP value (`phi`), the raw count, the proportion and `value_model`, the normalised value the model saw | Feature Importance |
| `metrics/shap_importance.csv` | the global ranking: mean absolute SHAP value per taxon | Feature Importance |
| `metrics/shap_class_contributions.csv` | one row per taxon × class: `mean_phi` (signed mean), `mean_abs_phi` (mean absolute value, the strength), `direction_rho` (Spearman correlation between `value_model` and the SHAP value; `NA` when either does not vary) and `direction` (more of the taxon raises or lowers the probability of that class, or no variation) | Feature Importance |
| `metrics/permutation_importance.csv` | permutation importance (`importance.method: perm`) | Feature Importance |
| `figures/*.png`, `*.svg` | print-resolution copies of the result figures a run produces: `out_of_fold_by_class`, `internal_test_by_class`, `per_group_balanced_accuracy`, `calibration_curve`, `importance_<method>`, and `importance_by_class`, the most influential taxa per class (mean \|SHAP\|), coloured by direction; 300 dpi PNG for slides, SVG for print | Benchmark, Prediction, Feature Importance |

SHAP values are measured against the model's average prediction, so over the explained
samples a taxon's pushes up and down largely cancel: a strong taxon can have a
`mean_phi` near zero. Read `mean_abs_phi` for how much a taxon matters to a class and
`direction` for which way more of it pushes.

## The multi-level folder

The wrapper adds `<date>_<id>_<version>_multi_tax_results/`:

| file | what it holds |
|---|---|
| `performance_metrics_all_tax_levels.csv` / `.rds` | every level's `performance_metrics_long.csv` stacked |
| `fold_metrics_all_tax_levels.csv` | every level's fold rows stacked |
| `lodo_metrics_all_tax_levels.csv` / `.png` / `.svg` | the per-group rows stacked, and the per-group figure (its subtitle states whether the estimates are nested) |
| `lodo_metrics_all_tax_levels_wide.csv` | the same scores as a group × level table, one block per method for balanced accuracy and AUC, with a mean row |
| `multi_tax_run_manifest.csv` | where each level's metrics, run folder and report are |

## Metrics

Binary targets: accuracy, balanced accuracy, log-loss, precision, recall, specificity,
F1, AUC, PR-AUC. Multi-class targets: accuracy, balanced accuracy, log-loss. Fairness
gaps (false-positive rate, true-positive rate, balanced accuracy per subgroup) are added
when `dataset.pta` is set on a binary task.

Resampling results carry the standard deviation across folds, never a standard error;
test sets carry a bootstrap 95 % interval. The [evaluation design](../workflow/evaluation.md#what-gets-reported)
page says why.

## Reading the per-class table

Balanced accuracy is the **mean of the per-class recalls**, so a single figure hides
which classes a model gets. `per_class_recall_*.csv` takes it apart: one row
per class with its size, one column per method, and the classes the reference method
confuses it with.

On an unbalanced target, plain accuracy and balanced accuracy can pick different
winners; the [cFMD case study](../cfmd/results.md) is a worked example.

A recall of 0.000 does not mean the model withholds the label. It can emit that class
freely and never land it on a sample that carries it. Check `oof_predictions.csv` before
describing a class as unused.

The mean row is computed on the pooled predictions of that set. The benchmark table
averages the per-fold balanced accuracies instead, so the two differ when the folds hold
unequal numbers of samples. Both are correct.

## Reusing a saved model

```r
learner <- readRDS("<run folder>/ranger_tuned_learner.rds")
learner$predict_newdata(new_table)     # columns aligned to reference_features.csv,
                                       # normalised with normalization.json
```

The notebook's External Test Set section does exactly this alignment and normalisation;
the simplest way to score new samples is to hand them over as `input.test_*` files.
