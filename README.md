<p align="center">
  <img src="assets/logo.svg" alt="TabFlux logo" width="560"/>
</p>

<p align="center">
  <a href="https://www.r-project.org"><img src="https://img.shields.io/badge/R-4.5-276DC3?logo=r&logoColor=white" alt="R 4.5"></a>
  <a href="https://mlr3.mlr-org.com"><img src="https://img.shields.io/badge/built%20on-mlr3-2C3E50" alt="built on mlr3"></a>
  <a href="https://quarto.org"><img src="https://img.shields.io/badge/Quarto-75AADB?logo=quarto&logoColor=white" alt="Quarto"></a>
  <a href="Dockerfile"><img src="https://img.shields.io/badge/Docker-GPU%20ready-2496ED?logo=docker&logoColor=white" alt="Docker"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache 2.0 license"></a>
  <a href="https://iLivius.github.io/TabFlux/"><img src="https://img.shields.io/badge/docs-iLivius.github.io%2FTabFlux-5E35B1" alt="Documentation"></a>
  <img src="https://img.shields.io/badge/DOI-pending%20release-lightgrey.svg" alt="DOI pending">
</p>

**TabFlux** turns a microbial community profile — amplicon ASV/OTU counts or shotgun taxonomic profiles — into a machine-learning classifier, and into an honest estimate of what that classifier is worth on samples it has never seen. One Quarto notebook and one plain-text configuration file drive the whole run: aggregation to any taxonomic level, depth normalisation, feature selection, tuning, grouped and nested evaluation, calibration, an external test set and SHAP explanations. Built on [mlr3](https://mlr3.mlr-org.com), TabFlux runs the classic learners of microbiome machine learning — random forest, XGBoost, penalised regression, k-nearest neighbours, support vector machines — and, beyond them, [TabPFN](https://priorlabs.ai), a foundation model for tabular data that learns from your data in context instead of being trained on it. Every learner is scored on the same unseen samples.

## 📖 Documentation

**Full documentation: [iLivius.github.io/TabFlux](https://iLivius.github.io/TabFlux/)**

| | |
|---|---|
| [Installation](https://iLivius.github.io/TabFlux/getting-started/installation/) | the container (recommended) or conda |
| [Quick start](https://iLivius.github.io/TabFlux/getting-started/quick-start/) | a public dataset, one command |
| [Your own data](https://iLivius.github.io/TabFlux/getting-started/your-data/) | the three input files and the settings that matter |
| [Evaluation design](https://iLivius.github.io/TabFlux/workflow/evaluation/) | why the reported numbers can be trusted |
| [Configuration](https://iLivius.github.io/TabFlux/reference/configuration/) | every key in `config.yaml` |
| [Case study](https://iLivius.github.io/TabFlux/cfmd/) | 4,000 public food metagenomes, no local data needed |

TabFlux belongs to the [BioFlux](https://github.com/stars/iLivius/lists/bioflux) family of workflows, next to [BacFlux](https://github.com/iLivius/BacFlux) and [MetaFlux](https://github.com/iLivius/MetaFlux).

## Quick start

The TabPFN 3.5 weights download only after a one-time licence acceptance on a [Prior Labs](https://ux.priorlabs.ai) account. Register, accept the licence, and export the API key once in your shell (`export TABPFN_TOKEN=...`) before the first run: without it the download fails, every TabPFN fit falls back to a majority-class dummy, and the run stops after TabPFN's tuning with an error that counts the failed fits. Once the weights sit in the mounted cache, later runs do not need the token.

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  ghcr.io/ilivius/tabflux:1.6.0
```

The demo downloads eighteen datasets of the curated Food Metagenomic Data and predicts which of four food categories a sample came from, over three folds that keep whole studies together. It writes an HTML report and a `metrics/` folder to `out/`. It shows the machinery end to end; four classes over 891 samples settle nothing. Support for metagenomic taxonomic profiles is at demo stage in this release; fuller support comes with the next one.

For your own data, put three files in `input/` (counts, taxonomy, metadata), edit `config.yaml`, set `output.dir: "/work/out"` in it, and mount both over the image's own copies:

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  -v "$PWD/input:/work/input:ro" -v "$PWD/config.yaml:/work/config.yaml:ro" \
  ghcr.io/ilivius/tabflux:1.6.0 Rscript scripts/run_multi_tax_levels.R config.yaml
```

Relative paths in the config resolve against `/work`, the project folder inside the image, so the template's `input/counts.csv.gz` is read from the mounted `input/`. Leave `output.dir` empty and the run targets the image's own `/work`: with `--user` it stops at once, because that folder is not writable for you; without `--user` the results land inside the container, and `--rm` discards them.

Drop `--gpus all` to run on CPU; TabPFN is several times slower there. Building the image locally and the workstation install with conda are described on the [installation](https://iLivius.github.io/TabFlux/getting-started/installation/) page.

## What you get

- **An honest number.** Every split keeps whole studies, sites or batches together, and feature selection and tuning are repeated inside every fold, so the reported score is the score on data the whole procedure never saw — with the per-group table and the spread across folds next to it.
- **A model you can use.** The final models are refit on all training data, saved, and used to predict internal and external test sets, with bootstrap intervals and probability calibration.
- **An explanation.** SHAP values for the best model: a global ranking and, for each class, the taxa that matter most and whether more of each raises or lowers that class's probability.

## Citation

TabFlux has no DOI yet; a Zenodo DOI will be minted with the first public release. Until then:

> Antonielli, L., & Pucher, L. (2026). *TabFlux: machine-learning classification of microbial community profiles.* GitHub. <https://github.com/iLivius/TabFlux>

Machine-readable metadata is in [`CITATION.cff`](CITATION.cff). TabFlux stands on other people's methods and software — mlr3, ranger, TabPFN, SHAP, cFMD and more — so **cite those too**: the full list is on the [citation page](https://iLivius.github.io/TabFlux/about/citation/).

## Acknowledgements

Developed at the [AIT Austrian Institute of Technology](https://www.ait.ac.at). TabFlux grew out of the **MICROSUPPRESS** project (*The role of wheat microbiomes in stress suppressiveness*), funded by the [Austrian Science Fund (FWF)](https://www.fwf.ac.at/en), project [P 36288](https://www.fwf.ac.at/en/research-radar/10.55776/P36288).

Much of the road from a single notebook to v1.6.0 — the nested evaluation, the container, the cFMD module and the documentation — was travelled with [Claude Code](https://claude.com/claude-code). Anthropic provided six months of Claude Max through their Open Source programme, and the scale of that rewrite would not have been realistic without it. Every line was reviewed by the authors.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). The TabPFN model weights carry their own licence, separate from this code; no study data ship with this repository.
