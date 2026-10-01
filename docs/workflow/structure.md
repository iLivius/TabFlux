# Code structure

## The pipeline at a glance

```text
 input/                        config.yaml
 ├─ counts.csv.gz        ───┐      │
 ├─ taxa.csv.gz          ───┼──────┘
 └─ meta.csv             ───┘
            │
            ▼
 [1] Import + aggregate        counts summed to phylum … species, or kept as
                               sequence-hashed ASV ids / SGBs        → feature_name_map.csv
            │
            ▼
 [2] Normalise (per sample)    relative abundance → log10, fixed pseudocount
                               full feature space saved             → normalization.json,
                                                                      reference_features.csv
            │
            ▼
 [3] Outer folds               grouped by dataset.group; inside every fold (nested):
     ├─ feature selection      information-gain filter → recursive elimination
     ├─ tuning                 grid, Hyperband or random search per learner, two measures
     └─ fit + score            on the held-out fold                → metrics/fold_metrics.csv,
                                                                      lodo_metrics.csv,
                                                                      oof_predictions.csv
            │
            ▼
 [4] Final models              fitted before the outer folds run; the same selection + tuning, once, on all
                               training data                        → <method>_tuned_learner.rds
            │
            ▼
 [5] Test sets                 internal (test_split) and external (input/test_*):
                               align → normalise → predict → score  → metrics/*test*.csv
            │
            ▼
 [6] Importance                SHAP on the best final model         → metrics/shap_*.csv
```

`scripts/run_multi_tax_levels.R` runs [1]–[6] once per level listed in
`dataset.tax_level` and stacks the metrics into
`<date>_<id>_<version>_multi_tax_results/`.

## Repository layout

Entries marked `●` are also copied into the container image, under `/work`; the rest
stay in the repository.

```text
.
├── analysis/tabflux.qmd           ●  # the notebook: every step, one taxonomic level per render
├── config.yaml                    ●  # template configuration for your own data
├── config_cfmd_demo.yaml          ●  # the container default: an 18-dataset, 891-sample slice of the category run
├── config_cfmd_category.yaml      ●  # the public multi-class run: food category, grouped CV
├── R/                             ●
│   ├── tabflux_config_helpers.R      # reads config.yaml, fills defaults, translates renamed keys
│   ├── tabflux_data_helpers.R        # aggregation, sequence-hashed ids, normalisation, alignment
│   ├── tabflux_cfmd_helpers.R        # a public cFMD release -> the three input files
│   ├── tabflux_selection_helpers.R   # feature selection on a training task
│   ├── tabflux_training_helpers.R    # learners, search spaces, tuners, the selection rule
│   ├── tabflux_evaluation_helpers.R  # test split, outer folds, the nested outer loop
│   ├── tabflux_scoring_helpers.R     # metric tables from mlr3 predictions, per-group tables
│   ├── tabflux_prediction_helpers.R  # pooled predictions, bootstrap intervals, curves, dumbbells
│   ├── tabflux_summary_helpers.R     # the group × rank table and figure of the wrapper
│   └── tabflux_figure_helpers.R      # PNG + SVG copies of the report figures; the per-class SHAP figure
├── scripts/                       ●
│   ├── run_multi_tax_levels.R        # renders the notebook once per level, stacks the metrics
│   └── make_cfmd_comparison.R        # the learner-comparison tables and figures, from a run folder
├── tests/                         ●  # plain-script tests: Rscript tests/test_<helpers>.R
├── conda/                         ●  # workstation environments; install_r_packages.R also builds the image
├── README.md, CHANGELOG.md, CITATION.cff, LICENSE, NOTICE ●  # overview, releases, citation, licence
├── Dockerfile                        # the image: R 4.5 + Python + TabPFN, GPU-ready
├── .Renviron.example                 # TabPFN and token variables, to copy into ~/.Renviron
├── .gitignore, .dockerignore         # what git and the image build leave out
├── .github/workflows/                # CI (image build + cFMD smoke test) and the docs deploy
├── .devcontainer/                    # VS Code / Positron: the editor inside the image (docs: Chunk by chunk)
├── assets/logo.svg                   # the README logo
├── docs/, mkdocs.yml                 # this site
└── input/                            # where your three files go; only README.md ships
```

### The two cFMD configurations

Six keys differ (table below). Everything else is the same: `tax_level: SGB`,
`group: dataset`, `outer: cv`, nested, `min_samples_per_dataset: 10`,
`min_samples_per_class: 50`, `smote: none`, `calibration: none`,
`prior_correction: true`, and TabPFN's SHAP settings (25 draws, 100 rows).

| key | `config_cfmd_demo.yaml` | `config_cfmd_category.yaml` |
|---|---|---|
| `methods.pick` | `tabpfn`, `ranger` | `tabpfn`, `ranger`, `xgboost` |
| `input.cfmd.datasets` | 18 listed datasets | `[]`, every dataset |
| `evaluation.outer_folds` | 3 | 5 |
| `importance.shap_max_rows` | 100 | 300 |
| `execution.future_globals_max_gb` | 2 | 4 |
| `dataset.version` | `demo` | `category` |

- The result: 891 samples in 4 categories, about 34 min; against 3,680 samples in 7
  categories, about 1 h 37 min, on the workstation described in
  [running it](../cfmd/running.md).
- `shap_max_rows` applies when the best learner is not TabPFN. For TabPFN both use
  `tabpfn_shap_max_rows: 100`.
- `future_globals_max_gb` caps the data sent to each parallel worker.

## The notebook, section by section

| section | what it does |
|---|---|
| Project Setup | finds the repository root; every path is built from it |
| Methods and Libraries | reads the config, decides which learners run, binds the TabPFN Python runtime |
| Set Parameters | turns every config value into a validated R variable; names the run folder and the report |
| Import Data | reads the three files, aggregates to the requested level, saves the name map |
| Preprocess Data | drops small classes; optional subsampling for test runs; prints the class sizes and, with a grouping column, a group × class table |
| Inspect Data | ordination of the samples (PCA and t-SNE): do the classes separate at all? |
| Normalize Abundances | per-sample relative abundance and log; prints the spread of sequencing depth, overall and per group; saves the settings |
| Define Task | builds the mlr3 task, reserves the internal test set, builds the outer folds |
| Prepare Modeling Inputs | the preprocessing graph every learner sits behind |
| Feature Selection | selection on the full training data, for the final models |
| Train models | tuning and refit of the final models, cached as `.rds` |
| Benchmark | the outer loop: selection and tuning inside every fold; per-fold and per-group metrics |
| Prediction | the internal test set, scored by the final models |
| Performance Comparison, Save Metrics | the tables that leave the run folder |
| External Test Set | your independent samples, predicted and scored |
| Feature Importance | SHAP on the best final model |

## How the wrapper drives the notebook

The wrapper writes a one-level temporary configuration per taxonomic level, hands it to
the child render through the `TABFLUX_CONFIG` environment variable, and stops at the
first level that fails. Only when every level has rendered does it stack the per-level
metrics and draw the group × rank figure. Both arguments are optional:

```bash
Rscript scripts/run_multi_tax_levels.R [config.yaml] [analysis/tabflux.qmd]
```

Every render writes one run folder,
`<date>_<id>_<version>_target_<target>_tax_<level>_saved_learners/`, in the project root
or under `output.dir` when set, which is created when missing (the container writes to
`/work/out`). The HTML report is titled from `output.report_title`, or "Predicting
<target> from <level>-level profiles" when that is empty; the run label goes in the
subtitle.
