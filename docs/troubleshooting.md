# Troubleshooting

Messages you may meet, what they mean, and what to do.

## The run stops at the start

**`Only 1 class left in the target column '…' — a classifier needs at least two.`** —
after the class filter, fewer than two classes survived. The message names the surviving
classes and the filter, `preprocessing.min_samples_per_class`; lower it, or use more
data.

**`evaluation.outer = 'lodo' needs dataset.group set`** — name the grouping column, or
choose another `outer`.

**`dataset.group and dataset.pta both name …`** — the grouping column cannot also be the
protected attribute: a group held out of training has no samples inside that fold to
compare against. Use a different column, or leave `pta` empty.

**`Multiple taxonomic levels detected`** — `dataset.tax_level` is a list. Use the wrapper,
or set one level for a direct render.

## TabPFN

**`HF_TOKEN missing.`** (v2.5 only) — put `HF_TOKEN=hf_…` in `~/.Renviron`. A blank
`HF_TOKEN=` in a project-level `.Renviron` masks the global value.

**The 3.5 weights will not download in a render** — the package wants a browser for the
licence step. Accept the licence once at the Prior Labs site, then set
`TABPFN_TOKEN=…` and `TABPFN_NO_BROWSER=1` in `~/.Renviron`. The weights and the token
are cached under `~/.cache/tabpfn/`. In the container, export `TABPFN_TOKEN` in the shell
and pass `-e TABPFN_TOKEN`; the image sets `TABPFN_NO_BROWSER=1`, and the weights persist
when `$HOME/.cache/tabpfn` is mounted at `/work/.cache/tabpfn`.

**MKL / `libmkl_*.so` not found** (conda route, v2.5 environment) — the conda-forge
PyTorch of `tabflux-tabpfn-gpu` is linked against MKL, which an embedded interpreter
finds only through `LD_LIBRARY_PATH`. The wrapper sets it for every render; a direct
`quarto render` needs
`export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$(conda info --base)/envs/tabflux-tabpfn-gpu/lib"`
first. The 3.5 environment and the container are unaffected.

**`mlp` and `tabpfn` in one run** — two torch stacks cannot share an R session. Run them
in separate configurations.

**Everything is very slow** — TabPFN on CPU. Add `--gpus all` (the host needs the NVIDIA
container toolkit), or keep to a small `input.cfmd.datasets` subset.

## Grouped designs

**A held-out group's balanced accuracy equals its plain accuracy, or AUC is `NA`** — the
group holds a single class, so its fold measures only that class's recall. Switch
`evaluation.outer` to `cv` with a small fold count, which pools several groups per fold,
or restrict the run to groups that contain every class. The [grouping](workflow/grouping.md) page has the reasoning.

**Fewer folds than asked for** — the fold count is capped by the number of groups and by
the rarest class. The report prints the fold table it used.

## Caching and reruns

**A rerun finishes suspiciously fast, or reports old numbers** — tuned models and
out-of-fold predictions are cached per run folder, and a rerun skips every outer fold
whose predictions are on disk. Bump `dataset.version`, or delete the `outer_fold_*/`
folders together with `<method>_tuned_instance.rds` and `<method>_tuned_learner.rds` to
retune.

**Container outputs are owned by root** — the container ran without
`--user "$(id -u):$(id -g)"`, or Docker created a missing `out/` itself. Run
`mkdir -p out` and add `--user` next time. To take over what is already there, without
administrator rights: `docker run --rm --user 0 -v "$PWD/out:/o" ghcr.io/ilivius/tabflux:1.6.0 chown -R "$(id -u):$(id -g)" /o`.

## The cFMD module

**`Could not list the cFMD release '…' from GitHub`** — anonymous GitHub API calls are
limited to 60 an hour per public IP address, shared by every machine behind that address
(an institute or company network, for example). The module needs one call per run, falls back to the cached manifest when the
data are already downloaded, and uses `GITHUB_TOKEN` from `~/.Renviron` when present (in
the container, pass it with `-e GITHUB_TOKEN`).

**A dataset is missing from the run** — smaller than `input.cfmd.min_samples_per_dataset`
once samples below `input.cfmd.completeness_threshold` are dropped, or its class fell
below `preprocessing.min_samples_per_class`. The import section of the report lists what
was dropped and why.
