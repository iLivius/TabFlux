# Running it

Two cFMD configurations ship with the repository and the image, next to the template
`config.yaml`. They ask the same question — which food category a sample came from,
given nothing but its species-level profile — and differ only in scope. Both run at the
native SGB level, both group by `dataset` and both are nested. The demo picks TabPFN 3.5
and a random forest; the full run adds XGBoost.

## The quick demo

`config_cfmd_demo.yaml` is the image's default command: a slice of the food-category
analysis.

- **Eighteen datasets**, listed in the config, chosen so that every category kept
  below occurs in at least five of them.
- **1,020 samples**, of which **891 in four categories** remain after
  `preprocessing.min_samples_per_class = 50`.
- **Three grouped folds** — `outer: cv`, `outer_folds: 3`, nested, SHAP on 100 rows;
  no class balancing, no calibration.
- **34 min** on the workstation described under [what it costs](#what-it-costs): 12 min
  to the metrics, 22 min of SHAP, the rest rendering.

| category | samples | datasets |
|---|---:|---:|
| `dairy` | 447 | 7 |
| `fruits_and_vegetables` | 159 | 6 |
| `fermented_meat` | 154 | 7 |
| `meat` | 131 | 5 |

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  ghcr.io/ilivius/tabflux:1.6.0                   # the image's default command
```

`-e TABPFN_TOKEN` passes the Prior Labs token from your shell; see
[installation](../getting-started/installation.md).

!!! warning "A demonstration of the machinery, not a result"

    Four classes over 891 samples, half of them dairy, settle nothing about food
    metagenomes. The run shows the pipeline end to end — download, preprocessing,
    grouped nested resampling, SHAP, report. Chance level is 0.25. The numbers worth
    quoting come from the full run.

## The full run

`config_cfmd_category.yaml` is the analysis the [results](results.md) page reports:
every dataset with at least ten samples, keeping the categories with fifty samples or
more — seven of them, 3,680 samples across 57 datasets — in five grouped folds. Two
design choices follow from the [structure of the database](database.md):

- **Grouped cross-validation instead of leave-one-dataset-out.** 96 of the 109 datasets
  hold one category, so holding one out gives a fold that scores that category only:
  balanced accuracy reduces to its recall, and ranking metrics are undefined. The
  dataset stays the grouping column, so no study is ever split, but `outer: cv` with
  five folds pools about eleven studies per fold. In the split the run actually drew,
  all seven classes are present in the training part of every one of the five folds.
- **No SMOTE, no calibration.** Both are binary tools; on seven classes the first
  mis-balances and the second does not apply, and the default
  [decision rule](../workflow/evaluation.md#which-category-is-predicted) already corrects
  for the class frequencies. Dairy is two thirds of the samples, so plain accuracy has a
  floor of 0.67 from the majority class alone: read balanced accuracy, whose chance
  level is 0.14.

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  ghcr.io/ilivius/tabflux:1.6.0 Rscript scripts/run_multi_tax_levels.R config_cfmd_category.yaml
```

## What it costs

The full run takes **1 h 37 min** on a 16-core Threadripper with one RTX 4090. Only
TabPFN uses the card; the forest, XGBoost, the feature selection inside every fold and
the SHAP pass are CPU work. The run writes the time of every stage to
`metrics/timings.csv` — seconds and minutes per learner, per fold and for the final
models.

| learner | tuning, summed over the five outer folds | final model |
|---|---:|---:|
| TabPFN | 11 min 5 s | 1 min 59 s |
| random forest | 10 min 4 s | 1 min 34 s |
| XGBoost | 10 min 49 s | 1 min 47 s |

The final model of each learner is tuned once on all the training data, before the folds
start. Per fold, each learner takes 1.6–2.2 min, except fold 3 at 2.7–3.5 min: its
selection kept 550 SGBs. The outer loop — selection, tuning and scoring, three learners,
all five folds — accounts for 37.5 min of the wall clock; the SHAP pass and the render
take 51 min after it.
TabPFN is not trained — the training table is passed as context at prediction time — so
its tuning line is the cost of evaluating one fixed setting across the inner resampling.

The inner resampling, which ranks candidate settings inside each outer fold and whose
scores are never reported, is k-fold over the groups (`evaluation.inner_folds`, 5 here)
above `max(inner_folds, 10)` groups and leave-one-group-out below it. Whole groups stay
together either way. The bound only changes how the forest's and XGBoost's candidates
are ordered — a learner with one candidate setting has nothing to rank.

## Practicalities

- **Cache.** Both configs cache under `/work/out/cfmd_cache`, inside the mounted volume,
  so the download happens once. Mount `~/.cache/tabpfn` as above to keep the model
  weights between runs.
- **Rate limit.** Listing the release is one GitHub API call. Anonymous calls are
  limited to 60 an hour per public IP address, shared by every machine behind that
  address (an institute or company network, for example). With the data already cached a refused call is harmless: the run
  continues from the cache. A `GITHUB_TOKEN` raises the limit (`-e GITHUB_TOKEN` in the
  container, `~/.Renviron` on a workstation).
- **On CPU** drop `--gpus all` and set `input.cfmd.datasets` to a handful of small
  datasets; the quick-start uses three.
- **Any other target.** `dataset.target` accepts any metadata column: `category`,
  `type`, `subtype`, `country`. Check the class × dataset table the report prints before
  trusting a grouped design; the [grouping](../workflow/grouping.md) page says what to
  look for.
