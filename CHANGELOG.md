# Changelog

All notable changes to TabFlux. Released versions are tagged in git from 1.6.0 on.

## 1.6.0 — 2026-09-28

- **One decision rule for every learner** (`evaluation.prior_correction`, on by
  default). The predicted category is the largest probability divided by that
  category's frequency in the training rows, the decision that maximises balanced
  accuracy; probabilities and log-loss are unchanged. It applies in the outer folds
  (each with its own training frequencies), on the internal and external test sets,
  in tuning and in the random-forest feature selection. TabPFN's own
  `balance_probabilities` is off: with it on, TabPFN alone was scored under this rule
  and the other learners under the largest probability. Never combined with class
  balancing: an automatic `smote` becomes `none`, an explicit one stops the run. The
  binary Platt report uses one cut for raw and calibrated labels.
- **Learner audit**, with an end-to-end toy-data test for every learner except TabPFN
  (`tests/test_all_learners.R`):
    - budget parameters (trees, row fraction) are refit at the top of their range, not
      at the winning row's budget;
    - the row-subsample budget samples rows, stratified by class, not whole studies;
    - a fallback to the majority-class dummy is counted: an error for TabPFN, a
      warning otherwise;
    - resume checks for a finished tuning result; before, every re-render refit;
    - an inner fold without one of the classes is reported;
    - the one-SE rule uses a paired standard error; the between-fold SE on grouped data
      exceeded the spread between settings, so every setting qualified;
    - `preprocessing.fast_tuning` is resolved once, before feature selection, so every
      outer fold tunes under the same protocol;
    - `kknn`'s `k` is bounded by the rarest class and the row-subsample floor.
- **XGBoost**: random search (80 / 40 settings) replaces Hyperband; `nrounds` is found
  by early stopping and refit on the inner folds' mean; `eta` starts at 0.01 instead of
  1e-4, where half the draws could not fit a model in 1,000 rounds.
- **LDA and naive Bayes retired.** LDA needs more samples per class than features and
  ran only on PCA scores whose rank had to stay below the rarest class; naive Bayes
  assumes features independent given the class, which relative abundances are not.
  Neither was competitive.
- **MLP tuning rebuilt.** The final refit used the setting as evaluated — epochs at
  the cap, early stopping and the 20 % validation slice still on — so the shipped
  network trained on 80 % of its rows, stopped afresh on one grouped holdout and,
  since mlr3torch keeps the last epoch, ended past its own best. It now trains the
  inner folds' mean epoch count on every row. Early stopping watches log-loss first
  (the slice is whole groups and often lacks a class, which balanced accuracy hides),
  every epoch, patience 10. Random search with a fixed count (40 / 80) replaces
  Hyperband, whose budget was width or batch size, neither a fidelity: one family of
  equal-width networks, a smaller box under `fast_tuning`; learning rate capped at
  1e-2; AdamW weight decay fixed at 0.01 and stated; one torch thread per fit instead
  of one per worker.
- **Container image published to GHCR** on a `v*` tag, after the unit tests and the
  cFMD smoke run pass: the version tag and `latest`.
- cFMD case study re-run with TabPFN, random forest and XGBoost under the one rule; new
  documentation page comparing the three, and a "Why TabFlux" page.
- **Per-class SHAP figure rebuilt** (`importance_by_class`): each class's most
  influential taxa by mean |SHAP|, coloured by whether more of the taxon raises or
  lowers that class's probability (Spearman correlation between its value and its
  SHAP value). The signed mean SHAP it replaces largely cancels over samples.
  `metrics/shap_class_contributions.csv` holds `mean_phi`, `mean_abs_phi`,
  `direction_rho` and `direction` per taxon and class.
- A method whose every tuning evaluation fails stops the run instead of shipping an
  untuned model.
- An external-test sample with no reads in the model's features is reported and
  skipped instead of stopping the run.
- The default TabPFN environment is `tabflux-tabpfn35-gpu`, matching the default
  `v3.5`, in the built-in defaults, the notebook and the wrapper.
- The wrapper creates `output.dir` when it does not exist.
- R packages loaded but never used removed from the notebook and the install script
  (coin, cowplot, farff, FactoMineR, httr, mlr3oml, mlr3tuningspaces, plotly, vegan,
  wordcloud, wordcloud2); the image is smaller.
- The image sets `TABPFN_NO_BROWSER=1` and includes `config_cfmd_category.yaml`. One
  image name everywhere, `ghcr.io/ilivius/tabflux:<version>`, also for a local build.
- `config_cfmd_demo.yaml` drops HellmannSL_2020 (8 samples, always removed by
  `min_samples_per_dataset`): 18 datasets.
- The renv route (`renv.lock`, `renv/`, `.Rprofile`, `dependencies.R`) and the
  scratch config `config_cfmd_cat_smoke.yaml` removed; the image and conda are the
  two installs.
- CI: the cFMD smoke test runs the random forest only, since a clean runner has no
  Prior Labs key for the TabPFN weights, and passes `GITHUB_TOKEN` for the cFMD
  listing; the published image name uses a lowercase owner.
- `scripts/make_cfmd_comparison.R` recomputes the tables and figures of the cFMD
  learner comparison from a run folder.
- Documented container commands create `out/` and the weight cache first and run as
  the calling user (`--user "$(id -u):$(id -g)"`), so results belong to the user, not
  to root.
- **Development container** (`.devcontainer/`): VS Code (or Positron) opens the
  repository inside the TabFlux image and runs the notebook chunk by chunk with the
  image's R, packages, TabPFN and GPU; files it writes belong to the host user.
- **Known limitation:** metagenomic taxonomic profiles are supported at demo stage (the
  cFMD case study). An external test set at SGB level is not supported yet and stops the
  run at that step; fuller support comes with the next release.

## 1.5.0 — 2026-09-21

- **Renamed metaML to TabFlux.** `SegataLab/metaml` is MetAML (Pasolli et al.,
  *PLoS Comput Biol* 2016), a microbiome machine-learning tool from the same group
  that curates the cFMD data this workflow ships as its case study — the collision
  was in the same field, on the same data. TabFlux joins the BioFlux family
  (BacFlux, MetaFlux, FunFlux): the prefix names what goes in, a table. Helper
  files, the notebook, the conda environments, the image tag, the environment
  variables (`TABFLUX_*`) and `dataset.id` all follow.

- **Selection leak in the outer loop fixed.** Feature selection ran once on all the
  training data and the outer folds were handed the reduced task, so each fold's
  "nested" selection could only re-rank a shortlist drawn with its own held-out
  samples in view. On the cFMD category run that was 7,847 SGBs cut to 250 before
  any fold started, and every per-fold selection a subset of those 250. The outer
  loop now starts from the full feature space and each fold selects on its training
  part alone; the final model, which should use the selection made on all the
  training data, is unchanged. cFMD numbers measured before this fix cannot be
  compared with those now reported; the case study has been re-run.
- **Inner resampling bounded on grouped tasks.** `auto` returned leave-one-group-out
  for any grouped task: ten refits per candidate setting with ten groups, but 57
  on the 57 cFMD datasets — 9,975 fits to tune
  one random forest — for a ranking whose scores are never reported. Up to
  `max(inner_folds, 10)` groups it stays leave-one-group-out; above that it is
  k-fold over the groups. Whole groups stay together either way. The cFMD category
  run, 7 h 43 under the old rule with three learners, takes 1 h 53 with two.
- `dataset.lodo` is now **`dataset.group`**. The old name said what the column was
  *for* rather than what it *is*: naming it never selected leave-one-dataset-out —
  `evaluation.outer` does that — and every outer strategy honours it. Old configs are
  translated with a message. `"lodo"` remains the name of the `evaluation.outer`
  strategy and of the `lodo_metrics*.csv` files.
- **Per-class recall table** for every prediction set (`per_class_recall_*.csv`, and
  printed in the report): one row per class, one column per method, what each class is
  mistaken for, and a mean row that reproduces balanced accuracy. Balanced accuracy is
  the mean of the per-class recalls, and on unequal classes the single number hides
  which classes a model never gets right.
- **`preprocessing.smote: "balance"`** — `po("classbalancing")`, which resamples every
  class towards the largest by copying rows. The automatic mode now chooses by target
  type, and a SMOTE variant asked for on a multi-class target switches to `balance`
  with a message: the SMOTE family interpolates towards one minority class and
  mis-balances everything else.
- **Figures exported at print resolution** to `figures/` in each run folder, PNG (300
  dpi) and SVG, for slides and manuscripts.
- **`metrics/timings.csv`**: wall clock per learner for the final models and for
  every outer fold, with the outer loop's total as a last row. Each training call
  writes a copy next to the learners it produced; the notebook gathers them. What
  a run costs is a table now, not something to scrape out of the report.
- **The report title describes the run.** An empty `output.report_title` used to
  fall back to `<dataset.id> <dataset.version>`, which for the shipped cFMD configs
  rendered as "TabFlux category" and read as a software version. The default is now
  "Predicting <target> from <tax_level>-level profiles"; the run label moves to the
  subtitle, and a custom title keeps target and rank in the subtitle so two reports
  of one batch stay distinguishable.
- Tuning fixes found by adding `xgboost` to the cFMD configs: its Hyperband budget
  started at 10 boosting rounds, so the widest bracket trained 64 settings on models
  too small to mean anything (over an hour on 295 samples, against five minutes for
  the random forest); floor raised to 100, matching ranger. And `booster` is now set
  explicitly, because mlr3 gates `colsample_bylevel` on it being *set* rather than
  defaulted — without it a run dies after tuning finishes, when the learners are
  reassembled for scoring.
- Grouped cross-validation reporting: fold labels no longer concatenate every group in
  the fold (which pushed the figure off its own canvas), the chance line is `1 / number
  of classes` instead of a hard-coded 0.5, and a figure only calls itself LODO when
  that is the strategy in use.
- `preprocessing.smote` and `preprocessing.filtering` are validated at startup: a typo
  used to disable them silently while the report announced they had been applied.
- **The image runs as the calling user.** `docker run --user "$(id -u):$(id -g)"`
  was documented but failed: Quarto renders next to the notebook and TabPFN caches
  under `HOME`, both root-owned in the image, so everything under `out/` came back
  owned by root. The work directories are now world-writable and `HOME` is `/tmp`.
  The "Invalid cross-device link" warning printed before the copy-and-delete
  fallback across the image layer and the mounted volume is silenced.
- Documentation checked against the code; the container commands corrected (the TabPFN
  licence token, the weights cache mount, `output.dir`); renv made opt-in so a fresh
  clone no longer hijacks the R library.

## 1.4.0 — 2026-09-15

- Configuration cleanup: one set of tuning-fold keys (`evaluation.inner_folds` /
  `inner_repeats`; `execution.kfold` / `repeats` removed and translated),
  `num_jobs: auto`, `term_min` SVM-only, no evaluation caps left on any tuner,
  `methods.pick: all` removed, one `min_samples_per_class`, the SMOTE threshold
  under `preprocessing`, the `filtering` override announced, the `fast_tuning`
  auto-off rule documented.
- `runtime.tabpfn` values in `config.yaml` now win over the `TABPFN_*`
  environment variables; the wrapper puts the TabPFN environment's `lib/` on
  the loader path for every render (conda-forge PyTorch needs MKL).
- cFMD input module (`input.source: "cfmd"`): run the whole workflow on a
  public release of the curated Food Metagenomic Data, downloaded once and
  rewritten in the three-file layout.
- TabPFN-3.5 support: `conda/tabflux-tabpfn35-gpu.yml`, `model_version: "v3.5"`,
  generation-specific fixed settings.
- Public release preparation: Apache 2.0 licence, NOTICE, CITATION.cff, this file.

## 1.3.0 — 2026-09-07

- `evaluation.test_split` replaces the `holdout` strategy: an internal test set
  reserved before selection, tuning and the outer folds, scored by the final
  models like the external set.
- Prediction-set summaries for the pooled out-of-fold predictions, the internal
  and the external test set: per-sample tables, bootstrap 95 % intervals,
  per-site tables, right/wrong-per-class figures, benchmark-vs-test dumbbells
  with fold spread and intervals, per-fold ROC and calibration curves;
  `benchmark_metrics_spread.csv`.

## 1.2.1 — 2026-09-05

- Random forest tuned properly: the 25-evaluation cap that stopped Hyperband
  inside its first bracket (every forest had 16 trees) removed; Hyperband budget
  100–1000 trees; per-method parallel tuning (TabPFN alone stays
  single-process).
- Wide site × rank LODO table; nested-aware per-site figure.

## 1.2.0 — 2026-09-04

- Nested resampling: an explicit outer evaluation loop (`evaluation` block;
  cv / repeated_cv / subsampling / loo / lodo) with feature selection and tuning
  repeated inside every fold; per-fold and per-site metrics; one-SE rule on the
  Pareto front for the final hyperparameters.

## 1.1.2 — 2026-09-01

- Platt calibration fitted on out-of-fold predictions and applied to the external
  test set; `renv` lockfile and dependency manifest.

## 1.1.1 — 2026-08-31

- Explicit hyperparameter selection rule, SHAP orientation on the positive
  class, review fixes (integer64 counts, placeholder taxa, positional taxonomy
  parsing, duplicate sequences).

## 1.1.0 — 2026-08-28

- Three-file input layout (counts, taxa, metadata) with sequence-hashed feature
  ids; per-sample depth normalisation (`tss_log`); external test set with
  per-group metrics; leave-one-site-out over all sites; multi-rank wrapper with
  version-stamped reports.

## 1.0.0 — 2026-08-14

- First release: mlr3 workflow with TabPFN and random forest, train/test split,
  LODO by study, SHAP importance.
