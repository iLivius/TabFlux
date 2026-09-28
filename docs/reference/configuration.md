# Configuration

Every setting lives in `config.yaml`. Missing keys fall back to the defaults in
`R/tabflux_config_helpers.R`. The keys `dataset.lodo`, `split`, `outer: holdout`,
`execution.kfold` / `repeats` and a top-level `smote` block are accepted as aliases and
translated with a message.
`config.yaml` in the repository is the template; `config_cfmd_demo.yaml` and
`config_cfmd_category.yaml` are complete, runnable examples. Both cFMD configurations
write to `/work/out`, a path that exists inside the container; on a workstation set
`output.dir` to `""` (or any writable folder) and `input.cfmd.cache_dir` to
`"input/cfmd_cache"`.

## `methods`

| key | meaning |
|---|---|
| `pick` | the learners to run, listed explicitly: any of `glmnet`, `kknn`, `mlp`, `ranger`, `svm`, `tabpfn`, `xgboost`. `mlp` and `tabpfn` cannot share a session. |

## `runtime.tabpfn`

Read only when `tabpfn` is picked. A non-empty value here wins over the corresponding
`TABPFN_*` environment variable; `hf_token` is the exception, secrets come from the
environment first.

| key | meaning |
|---|---|
| `conda_root`, `env_name` | the conda installation and environment holding TabPFN; `env_name` defaults to `tabflux-tabpfn35-gpu` |
| `python` | an interpreter path; set it instead of `env_name` to pin Python directly (the container sets it through `TABPFN_PYTHON`) |
| `model_version` | `v3.5` (default) or `v2.5`; the two generations use different fixed settings |
| `hf_token` | the Hugging Face token for the v2.5 weights; prefer `~/.Renviron` |

## `execution`

| key | meaning |
|---|---|
| `seed` | the global seed; every outer fold is seeded again from it, so a fold depends only on the data and its index |
| `num_threads` | cores one learner may use internally; `auto` = all |
| `num_jobs` | parallel R workers for tuning the R learners; `auto` = one per group when `dataset.group` is set, `evaluation.inner_folds` otherwise, never more than `num_threads`. TabPFN always stays single-process |
| `future_globals_max_gb` | the size limit for objects shipped to the workers |
| `term_min` | wall-clock tuning cap in minutes, SVM only |
| `tuning_selection` | `one_se` (lowest log-loss within one standard error of the best balanced accuracy) or `max_bacc` |
| `log_threshold` | mlr3 logging: `off`, `warn`, `info`, `debug` |

## `dataset`

| key | meaning |
|---|---|
| `id`, `version` | name the run folder; `version` also names the wrapper's report file and appears in the report subtitle |
| `target` | the metadata column with the class labels |
| `group` | the **grouping column** (site, study, batch, …): samples sharing a value are never split across a fold boundary. `""` = random folds. How groups become folds is `evaluation.outer` |
| `pta` | protected attribute for the fairness metrics, binary targets only; must differ from `group` |
| `tax_level` | one level, or a list for the wrapper: `asv`, `phylum`, `class`, `order`, `family`, `genus`, `species`, `SGB` |
| `positive_class` | the class reported as positive; `""` = the minority class, so name it when the classes are balanced |

## `input`

| key | meaning |
|---|---|
| `counts_path`, `taxa_path`, `meta_path` | the three training files |
| `test_counts_path`, `test_taxa_path`, `test_meta_path`, `test_group` | the external test set and the column for its per-group metrics |
| `asv_path` | legacy single-file layout; leave empty |
| `source` | `files` (the paths above) or `cfmd` (a public cFMD release rewritten into the same three files) |
| `cfmd.ref` | the release tag, e.g. `v1.3.2`; pin it |
| `cfmd.datasets` | a subset of dataset names, or `[]` for all |
| `cfmd.completeness_threshold` | drop samples whose profile sums below it, in percent (default 99) |
| `cfmd.min_samples_per_dataset` | drop smaller datasets, counted after the completeness filter: a group of three samples cannot carry a fold |
| `cfmd.cache_dir` | where the downloads and the rewritten files live (default `input/cfmd_cache`) |
| `cfmd.repo`, `cfmd.data_path` | the source repository and its data folder (`SegataLab/cFMD`, `cFMD_data`); leave as they are |

## `preprocessing`

| key | meaning |
|---|---|
| `min_samples_per_class` | classes below it are dropped before anything is fitted |
| `samples_to_keep`, `feat_to_keep` | fractions kept for quick test runs; 1 = everything |
| `smote`, `smote_imbalance_threshold` | class balancing: `""` automatic, `"none"` off, or a variant. See [class balancing](../workflow/data-preparation.md#class-balancing) |
| `filtering` | the cheap filter inside the learner graph; ignored while `selecting` is on |
| `selecting` | wrapper feature selection: information-gain filter, then recursive elimination with the one-standard-error rule |
| `fast_tuning` | the cheaper tuners; forced off below 500 samples or 25 features |
| `learner_fallback` | run each fit in a separate R process; a fit that errors is replaced by a majority-class stand-in and a warning counts the failures. TabPFN stops instead, and so does any learner whose every tuning evaluation fails |
| `normalization`, `pseudocount` | `tss_log` (default), `tss`, `tss_clr`, `none`; the constant added before the log |
| `calibration` | `platt` (fitted on out-of-fold predictions, applied to the external set; binary only) or `none` |

## `evaluation`

The [evaluation design](../workflow/evaluation.md) page explains the choices.

| key | meaning |
|---|---|
| `test_split` | fraction reserved as an internal test set before anything learns; `0` = none |
| `outer` | how the estimate on the training data is made: `cv`, `repeated_cv`, `subsampling`, `loo`, `lodo`; with a grouping column, every strategy keeps whole groups |
| `outer_folds`, `outer_repeats` | fold count and repetitions for the strategies that use them |
| `nested` | `true`: feature selection and tuning repeated inside every outer fold (honest, expensive); `false`: once on all training data |
| `inner`, `inner_folds`, `inner_repeats` | the resampling inside the tuning; `auto` = under a grouping column, leave-one-group-out up to `max(inner_folds, 10)` groups and k-fold over the groups above that; without one, k-fold or repeated k-fold by data size |
| `prior_correction` | `true` (default): every learner predicts the category with the largest probability divided by that category's frequency in the training rows, the decision that maximises balanced accuracy; probabilities and log-loss are unchanged. `false`: the largest probability. Not combined with class balancing: an automatic `smote` stays off, an explicit one stops the run |

## `importance`

| key | meaning |
|---|---|
| `method` | `shap`, `perm`, `none` |
| `levels` | restrict the step to these levels in a multi-level run; `[]` = all |
| `shap_sample_size` | permutation draws behind each Shapley value (default 100) |
| `shap_max_rows` | training rows explained, any learner (default 300); the step costs rows × features × classes × `shap_sample_size` |
| `tabpfn_shap_sample_size`, `tabpfn_shap_max_rows` | the same two for TabPFN, which reruns the whole model for every draw (defaults 10 and 20; the shipped configs use 25 and 100) |

## `output`

| key | meaning |
|---|---|
| `run_date` | `""` = today; the wrapper fixes one date for a whole batch |
| `dir` | where run folders and reports go; `""` = the project root. In the container set `/work/out` (the mounted `out/`), as the cFMD configs do; left empty, the results stay inside the container and `--rm` deletes them. Created when missing; relative paths resolve against the project root |
| `report_title`, `report_author` | the HTML report's title and author line; `""` = "Predicting `<target>` from `<level>`-level profiles", with `<id> · run <version>` as subtitle, and no author line |

## `visualization`

`downsample_threshold`, `downsample_size` (ordination plots on large tables) and
`prevalence_threshold`. Rarely changed.

## Environment variables

`TABPFN_CONDA_ROOT`, `TABPFN_ENV_NAME`, `TABPFN_PYTHON` and `TABPFN_MODEL_VERSION` are
read only for a `runtime.tabpfn` field set to `""` in the config; a field left out takes
the built-in default (`env_name` `tabflux-tabpfn35-gpu`, `model_version` `v3.5`, the
other two empty). The natural place for all of them is `~/.Renviron`.

| variable | meaning |
|---|---|
| `TABPFN_CONDA_ROOT`, `TABPFN_ENV_NAME`, `TABPFN_PYTHON`, `TABPFN_MODEL_VERSION` | the TabPFN runtime, as above |
| `HF_TOKEN` | Hugging Face token for the v2.5 weights (also read as `HUGGINGFACE_HUB_TOKEN`) |
| `TABPFN_TOKEN`, `TABPFN_NO_BROWSER=1` | the Prior Labs account token for the 3.5 weights in non-interactive runs; the container image sets `TABPFN_NO_BROWSER=1` |
| `GITHUB_TOKEN` | optional; raises the API rate limit for the cFMD listing |
| `TABFLUX_CONFIG` | the config file a render reads; set by the wrapper for every child render |

A blank `HF_TOKEN=` in a project-level `.Renviron` masks a working global value: keep
only the variables you override there.
