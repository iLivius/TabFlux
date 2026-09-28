# Conda Environments

This folder contains three separate Conda environment specifications.

- `tabflux-r.yml`: the R-side environment used to open and run the Quarto
  notebook from Positron, VS Code, RStudio, or the terminal
- `tabflux-tabpfn35-gpu.yml`: the Python environment used only when the
  workflow runs `tabpfn` through `reticulate`, TabPFN-3.5 generation; this is
  the environment every shipped config names
- `tabflux-tabpfn-gpu.yml`: the same for the earlier TabPFN v2.5 generation

## Recommended setup

Create the R environment first:

```bash
conda env create -f conda/tabflux-r.yml
conda activate tabflux-r
Rscript conda/install_r_packages.R
```

If you plan to use the `mlp` learner, install the R `torch` backend as well:

```bash
CUDA=cpu INSTALL_R_TORCH=1 Rscript conda/install_r_packages.R
```

`CUDA=cpu` picks the CPU build of libtorch, as the image does: `mlp` runs on CPU
only, and the CPU build is a much smaller download than the CUDA one.

Create a TabPFN GPU environment only if you plan to use `tabpfn`:

```bash
conda env create -f conda/tabflux-tabpfn35-gpu.yml  # TabPFN-3.5, shipped default
conda env create -f conda/tabflux-tabpfn-gpu.yml    # TabPFN v2.5
```

Which environment runs is decided by `runtime.tabpfn` in the config: a non-empty
`env_name` or `model_version` there wins over the matching `TABPFN_*` variable.
All three shipped configs (the template `config.yaml` and the two cFMD ones) name
`tabflux-tabpfn35-gpu` and `v3.5`, so switch generation by editing the config, not
the environment variables.

`TABPFN_CONDA_ROOT`, `TABPFN_ENV_NAME`, `TABPFN_PYTHON` and `TABPFN_MODEL_VERSION`
are read only for a `runtime.tabpfn` field set to `""` in the config (a field left
out takes the built-in default: `tabflux-tabpfn35-gpu`, `v3.5`); `TABPFN_TOKEN` and
`TABPFN_NO_BROWSER` have no config field. Put them in `~/.Renviron` or the shell environment: under
`quarto render` a project-level `.Renviron` is read after Python has been bound,
so only `HF_TOKEN` is reliably picked up from there.

```bash
TABPFN_CONDA_ROOT=/path/to/miniconda3
TABPFN_ENV_NAME=tabflux-tabpfn35-gpu
TABPFN_MODEL_VERSION=v3.5
TABPFN_TOKEN=...
TABPFN_NO_BROWSER=1
```

`TABPFN_TOKEN` is the API key of a Prior Labs account. Accept the licence once on
that account; the package uses the key to confirm the acceptance before it downloads
the 3.5 weights. `TABPFN_NO_BROWSER=1` stops the package from trying to open a
browser for that acceptance, which a render cannot do. Keep comments off these
lines: R does not strip a comment written after a value in `.Renviron`. The same
block, commented, is in `.Renviron.example`.

For TabPFN v2.5 instead: `tabflux-tabpfn-gpu`, `v2.5`, and `HF_TOKEN=hf_xxx`, a
Hugging Face access token; TabFlux stops without it for v2.x.

If you prefer to pin the Python interpreter directly, set `TABPFN_PYTHON`
instead of `TABPFN_ENV_NAME`. `python` is empty in every shipped config, so that
one variable is never overridden.

## Notes

- The R environment is the main environment for this repository.
- The TabPFN environments are optional. If you run methods such as `ranger`,
  `glmnet`, or `xgboost`, you can skip them.
- GPU support is strongly recommended for TabPFN in this workflow. CPU-only
  execution is possible in principle, but repeated resampling and tuning make
  it much slower in practice.
- `tabflux-tabpfn-gpu` is pinned to a `conda-forge` CUDA-enabled PyTorch build,
  which is usually easier to solve under strict channel-priority setups than a
  separate `pytorch-cuda` metapackage. `tabflux-tabpfn35-gpu` takes torch from
  pip instead, whose wheel bundles its own CUDA libraries and so needs no
  `LD_LIBRARY_PATH` when Python is embedded in R.
- The TabPFN weights are not part of this code; they carry their own licence,
  for non-commercial research and benchmarking. They download on first use:
  the 3.5 weights after a one-time licence acceptance on a Prior Labs account
  (`TABPFN_TOKEN` when nothing can open a browser), the v2.5 weights with
  `HF_TOKEN`.
- Full install instructions, container included, are in
  `docs/getting-started/installation.md`.
