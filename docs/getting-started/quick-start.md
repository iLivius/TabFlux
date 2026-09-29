# Quick start

This runs the whole workflow on public data, with no files of your own. With your
Prior Labs token exported in the shell (`export TABPFN_TOKEN=<your token>`):

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  ghcr.io/ilivius/tabflux:1.6.0
```

The cache mount keeps the TabPFN weights outside the container, so `--rm` does not
throw away the download; the `out/` mount receives the results. `mkdir` and `--user`
keep everything the run writes owned by you ([why](installation.md#container-recommended)).
See [installation](installation.md) for the image and a local build.

!!! warning "Without the token, the run stops"

    The 3.5 weights download after a one-time licence acceptance on a Prior Labs
    account. A container cannot open a browser, so the image sets
    `TABPFN_NO_BROWSER=1` and the API key passed with `-e TABPFN_TOKEN` shows the
    package that the licence was accepted (see
    [installation](installation.md#tabpfn-weights)). Without the token the download
    fails. Every TabPFN fit runs in its own
    process behind a fallback, a dummy that ignores the taxa and always answers the
    majority class; TabFlux counts those fallbacks and stops the run after TabPFN's
    tuning rather than report the dummy's scores. Once the weights are in the mounted
    cache, later runs do not need the token.

## What just happened

The default configuration, `config_cfmd_demo.yaml`, asks for
[cFMD](../cfmd/database.md) release v1.3.2 and eighteen of its datasets. TabFlux
downloads the taxonomic profiles (1,020 samples), rewrites them into the three input
files it reads, keeps cFMD's native species-level genome bins (SGBs) without
aggregating, and normalises depth. Categories with fewer than 50 samples are then
dropped, which leaves 891 samples in four: dairy 447, fruits_and_vegetables 159,
fermented_meat 154, meat 131. Each of the four occurs in at least five of the datasets.

The eighteen datasets become three folds, and no dataset is split across two of them.
Inside each fold TabFlux selects features and tunes TabPFN and the random forest on
the two folds it can see, then scores the held-out one. SHAP at the end says which
taxa the winning model used.

!!! warning "A demonstration of the machinery, not a result"

    Four categories over 891 samples settle nothing. Dairy is half the samples and
    chance level for balanced accuracy is 0.25. The real analysis is the
    [case study](../cfmd/index.md): 57 datasets, 3,680 samples, seven categories,
    five folds, 1 h 37 min. The demo takes 34 min on the same machine, 22 of them SHAP.

When it finishes, `out/` holds one HTML report and one run folder per taxonomic level —
one of each here, since the demo runs SGB alone. The run folder's `metrics/` holds:

| file | what it answers |
|---|---|
| `benchmark_metrics.csv` | how each learner did on average |
| `benchmark_metrics_spread.csv` | how much that average hides |
| `lodo_metrics.csv` | how each outer fold scored, and which datasets it held out |
| `per_class_recall_oof.csv` | which categories a learner gets right, and which it misses |
| `oof_predictions.csv` | every sample's out-of-fold prediction |
| `shap_importance.csv` | which taxa the winning model used |

`lodo_metrics.csv` has one row per held-out *group*: one whole dataset under
`outer: lodo`, a fold's worth of datasets under `outer: cv`.

Read the HTML report first; it contains the same numbers with the figures.

## Smaller and faster

SHAP is the largest single cost; `importance.method: none` removes it. Copy
`config_cfmd_demo.yaml` to `my_config.yaml` in the current folder — from a clone, or out
of the image with
`docker run --rm ghcr.io/ilivius/tabflux:1.6.0 cat config_cfmd_demo.yaml > my_config.yaml`
— and cut the dataset list to three:

```yaml
input:
  cfmd:
    datasets: [AlvarezOrdonezA_xxxx, DeFilippisF_xxxx, SequinoG_2024_b]
```

That gives 346 samples in three categories (dairy 157, meat 102, fermented_meat 87),
each present in two of the three datasets, so every fold can learn every class it is
scored on. A class that survives the size filter but lives in a single dataset is
reported by the run as untrainable in the fold that holds that dataset out. Setting
`evaluation.nested: false` on top makes it cheaper again: feature selection and tuning
run once on all the training data instead of inside every fold, which is mildly
optimistic.

Then mount your copy into `/work` and name it on the command line. It keeps the demo's
`output.dir: "/work/out"`, so the results still land in `out/`:

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  -v "$PWD/my_config.yaml:/work/my_config.yaml:ro" \
  ghcr.io/ilivius/tabflux:1.6.0 Rscript scripts/run_multi_tax_levels.R my_config.yaml
```

!!! tip "Give every run its own `dataset.version`"

    Tuned models are cached per run folder. A second run with the same version reuses
    them, which is what makes an interrupted run resumable — and what will silently
    reuse a cheap test if you forget.

## Running on your own data

Put the three files in `input/`, edit `config.yaml` (the template in the repository)
and run it in the container or on a workstation.

**Container.** Relative paths in the config resolve against `/work`, so mount `input/`
and the config there, and set `output.dir: "/work/out"` in `config.yaml`. Left empty, the
run stops at once with `--user` (the image's `/work` is not writable for you), and
without `--user` it writes inside the container, where `--rm` deletes the results:

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  -v "$PWD/input:/work/input:ro" -v "$PWD/config.yaml:/work/config.yaml:ro" \
  ghcr.io/ilivius/tabflux:1.6.0 Rscript scripts/run_multi_tax_levels.R config.yaml
```

Reports, run folders and the stacked tables land in `out/`.

**Workstation** (the conda route of [installation](installation.md); `input.*` can then
point anywhere):

| how | command | output |
|---|---|---|
| every level | `Rscript scripts/run_multi_tax_levels.R` | one `tabflux_<version>_<level>.html` report per level and its run folder in `output.dir` (the project root when empty), plus the stacked `*_multi_tax_results/` |
| one level | `quarto render analysis/tabflux.qmd` (with `tax_level` set to a single string) | `analysis/tabflux.html` and the run folder |
| interactive | open `analysis/tabflux.qmd` in RStudio, RStudio Server, Positron or VS Code with the `tabflux-r` environment and run the chunks ([chunk by chunk](interactive.md#rstudio-rstudio-server-positron)) | in-session objects and the run folder |

To run the chunks inside the container instead, with the image's R and packages, open
the repository in VS Code's dev container: [chunk by chunk](interactive.md#vs-code-in-the-container).

What the files must look like and which settings matter: [your own data](your-data.md).
