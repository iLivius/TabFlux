# Installation

There are two ways to run TabFlux. The container is the default; conda is there for
interactive development.

## Container (recommended)

One image holds both runtimes, R and Python, because the workflow calls TabPFN from R
through `reticulate`.

Each release is published as a ready-made image on GitHub's container registry:
`docker run` downloads it on first use, so you need neither the source code nor a build.
Export your Prior Labs token once in the shell (`export TABPFN_TOKEN=<your token>`; see
[TabPFN weights](#tabpfn-weights)), then:

```bash
mkdir -p out ~/.cache/tabpfn
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
  -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
  ghcr.io/ilivius/tabflux:1.6.0
```

This runs the [cFMD demo](../cfmd/index.md) on public data and writes everything to
`out/`. No local data are needed.

- `mkdir -p` first: Docker creates a missing mount folder itself, owned by root, and the
  container, running as you, could not write to it.
- `--user "$(id -u):$(id -g)"` runs the container as you, so everything it writes to
  `out/` and to the weight cache belongs to you. Without it the container runs as root,
  and only an administrator can then change or delete its output.
- `-e TABPFN_TOKEN` passes the variable from the shell into the container.
- Rootless Docker or Podman: leave `--user` out; there the container's root is already
  your own user.

Docker itself needs an administrator: to install it, and to give you access (membership
of the `docker` group, which amounts to root rights). Without Docker access, use
[conda](#conda).

The first `docker pull` fetches about 7 GB and is then cached. Quote the version tag,
never `latest`, in anything you publish: `latest` moves with every release.

To build it yourself instead — to change the code, or to check that the recipe still
produces the same thing — tag the build with the published name, so every command on
this site runs it unchanged:

```bash
git clone https://github.com/iLivius/TabFlux.git && cd TabFlux
docker build -t ghcr.io/ilivius/tabflux:1.6.0 .
```

!!! note "What the image pins"

    R 4.5.3, and every R package as a precompiled binary from a date-pinned
    [Posit](https://packagemanager.posit.co) repository. Nothing is compiled at build
    time, so no package links against a library that happens to sit on the build
    machine.

### GPU

`--gpus all` needs the
[NVIDIA container toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
on the host. You do not need CUDA installed: the image brings its own copy. Only the
NVIDIA driver has to be on the machine.

Drop `--gpus all` and the same image runs on CPU. TabPFN pays for it, and the penalty
grows with the table:

| table | GPU | CPU |
|---|---|---|
| 1,000 samples × 50 features | 3.9 s | 20 s |
| 3,200 samples × 200 features | 12.8 s | 395 s |

A nested run performs hundreds of such fits. On CPU, keep to a small
`input.cfmd.datasets` subset.

### TabPFN weights

They download on first use into `/work/.cache/tabpfn`, which sits beside `out/`, not
inside it. Mount it as in the command above, or `--rm` discards the ~876 MB download with
the container and every run repeats it.

The 3.5 download needs a one-time licence acceptance: log in (or register) at
<https://ux.priorlabs.ai>, accept the licence on the Licenses tab, and copy the API key
from the account page. Export it as `TABPFN_TOKEN` and pass it with `-e TABPFN_TOKEN`.
A container cannot open a browser, so the image sets `TABPFN_NO_BROWSER=1` and the
package checks the acceptance through the key instead. Once the weights are in the
mounted cache, later runs do not need the token. The weights carry their own licence,
separate from this code: testing, evaluation and non-commercial research (see
[licensing](../about/licensing.md)).

## Conda

For interactive work, two environments: R and its packages in one, TabPFN and PyTorch
in the other, because the two torch stacks cannot share an R session. How to run the
notebook chunk by chunk from them, or inside the container instead:
[chunk by chunk](interactive.md).

```bash
conda env create -f conda/tabflux-r.yml            # R 4.5, the workflow
conda activate tabflux-r                           # the next line installs into it
Rscript conda/install_r_packages.R                # CRAN packages
conda env create -f conda/tabflux-tabpfn35-gpu.yml # TabPFN 3.5, the default
conda env create -f conda/tabflux-tabpfn-gpu.yml   # TabPFN v2.5, only for model_version: v2.5
```

Point the workflow at the Python environment through `runtime.tabpfn` in the config,
or through the `TABPFN_*` variables below. A non-empty value in the config wins.

!!! warning "The conda route is not reproducible the way the container is"

    `conda env create` resolves the newest package versions that satisfy the file,
    and the notebook installs any missing R package from CRAN at run time, so two
    machines set up a month apart can differ. Use it to develop; use the container
    for anything whose numbers you intend to report.

### TabPFN variables and weights

Put these in `~/.Renviron` (or the shell environment); `.Renviron.example` in the
repository is a template. The first four apply where the matching `runtime.tabpfn` value
is empty: `conda_root` and `python` are empty unless the config sets them, while
`env_name` and `model_version` take the built-in defaults (`tabflux-tabpfn35-gpu`,
`v3.5`) unless the config sets them to `""`.

| variable | meaning | example |
|---|---|---|
| `TABPFN_CONDA_ROOT` | the conda installation holding the environment | `/home/me/miniforge3` |
| `TABPFN_ENV_NAME` | the environment name | `tabflux-tabpfn35-gpu` |
| `TABPFN_PYTHON` | an interpreter path; set it instead of the name to pin Python directly | `…/envs/tabflux-tabpfn35-gpu/bin/python` |
| `TABPFN_MODEL_VERSION` | `v2.5` or `v3.5` | `v3.5` |
| `HF_TOKEN` | Hugging Face token, v2.5 weights only | `hf_…` |
| `TABPFN_TOKEN`, `TABPFN_NO_BROWSER=1` | Prior Labs account token, 3.5 weights in non-interactive runs | |

**v2.5** weights download from Hugging Face (`Prior-Labs/tabpfn_2_5`) under the
TabPFN-2.5 licence. TabFlux stops before the first TabPFN fit if `HF_TOKEN` is not set.
With the `tabpfn` 9.0 package of the container, the v2.5 download also needs the Prior
Labs licence acceptance, as for 3.5.

**3.5** weights (one file, ~876 MB) download after a one-time licence acceptance on your
Prior Labs account; a `quarto render` cannot open a browser, so put the account token in
`~/.Renviron` as above. The package caches both under `~/.cache/tabpfn/`. Under `quarto
render` the `TABPFN_*` values belong in `~/.Renviron` or the shell: the project-level
`.Renviron` is read only when the token is resolved, after Python has been bound, so it
is reliably honoured for `HF_TOKEN` alone.

!!! warning "conda-forge PyTorch and the loader path"

    The v2.5 environment, `tabflux-tabpfn-gpu`, uses the conda-forge PyTorch build, which is
    linked against MKL. An embedded Python interpreter finds those libraries only
    through `LD_LIBRARY_PATH`, and a running process cannot set that for itself. The
    multi-rank wrapper does it for every render it starts; a direct
    `quarto render analysis/tabflux.qmd` needs it exported first. The container has no
    such problem.
