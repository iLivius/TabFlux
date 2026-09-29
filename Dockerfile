# TabFlux in one image: R and Python together, GPU-first.
#
# Why one image and not two runtimes: the workflow calls TabPFN from R through
# reticulate, so splitting them would make a user reproduce the handshake
# between an R container and a local Conda environment. Everything needed is
# here, and nothing is taken from the host except the kernel and, optionally,
# the NVIDIA driver.
#
# Why rocker/r-ver: it pins R and points install.packages() at Posit's package
# manager, which serves PRECOMPILED Linux binaries for CRAN. No compiler
# roulette, no dependency on libraries that happen to sit on the build machine
# — the failure mode that makes R environments hard to reproduce.
#
# GPU: PyTorch wheels carry their own CUDA libraries, so no CUDA base image is
# needed; `docker run --gpus all` injects the driver. Without a GPU the same
# image still runs on CPU, several times slower (about 30x at full cFMD size).
#
# Build:  docker build -t ghcr.io/ilivius/tabflux:1.6.0 .
#         (the same name as the published image, so every documented command
#         works on a local build too)
# Run:    mkdir -p out ~/.cache/tabpfn
#         docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
#           -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
#           ghcr.io/ilivius/tabflux:1.6.0
#         mkdir first: Docker would create a missing mount folder owned by root.
#         --user runs the container as you, so what it writes is yours.
#         -e TABPFN_TOKEN passes the Prior Labs API key from the host shell
#         (export it there once); the cache mount keeps the downloaded TabPFN
#         weights between runs, and out/ receives the report and tables.
FROM rocker/r-ver:4.5.3

# Snapshot date of the binary CRAN repository: pinning it means a rebuild in a
# year installs the same package versions as today.
ARG CRAN_SNAPSHOT=2026-09-15
ENV CRAN=https://packagemanager.posit.co/cran/__linux__/noble/${CRAN_SNAPSHOT}

# System libraries the R packages link against, plus Python and Quarto's needs.
# Installed from the distribution, so they match the base image by construction.
RUN apt-get update && apt-get install -y --no-install-recommends \
      # python3-dev is not optional: reticulate binds R to a SHARED libpython,
      # and that shared object ships in the -dev package. Without it the image
      # builds fine and then fails at run time with "reticulate can only bind to
      # copies of Python built with '--enable-shared'", which is misleading —
      # this Python is built that way, the library file is simply absent.
      python3 python3-pip python3-venv python3-dev \
      libxml2-dev libcurl4-openssl-dev libssl-dev libgit2-dev \
      libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
      libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
      libglpk-dev libgsl-dev libuv1-dev libsodium-dev cmake pandoc git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Python side: TabPFN 3.5 with a CUDA-capable PyTorch, in a virtual environment
# that reticulate is pointed at. No Conda. torch and tabpfn are pinned; the
# packages they pull in are not (pip takes the newest that fit).
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
# TABPFN_PYTHON is what TabFlux's own runtime resolution reads; RETICULATE_PYTHON
# covers anything that talks to reticulate directly. Both point at the venv, so
# a config that leaves runtime.tabpfn.python empty works here AND on a
# workstation, where the conda environment named in the config answers instead.
ENV PATH="$VIRTUAL_ENV/bin:$PATH" RETICULATE_PYTHON=$VIRTUAL_ENV/bin/python TABPFN_PYTHON=$VIRTUAL_ENV/bin/python
RUN pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cu129 \
      torch==2.9.1 tabpfn==9.0.0

# R side: every package from the pinned binary repository.
# The R torch backend (libtorch + Lantern) for the `mlp` learner. CUDA=cpu picks
# the CPU build: ~740 MB against several GB, and it cannot collide with the CUDA
# runtime the Python side loads for TabPFN. The two still must not share an R
# session, which the notebook refuses at config time.
ENV CUDA=cpu INSTALL_R_TORCH=1

COPY conda/install_r_packages.R /tmp/install_r_packages.R
# The repository is set here and the install script honours it (see the note
# in that file): CRAN packages arrive as binaries from the dated snapshot, so a
# rebuild later resolves them to the same versions. The exception is
# mlr3extralearners (the TabPFN wrapper) and a few of its dependencies, which
# come from mlr-org's r-universe as they are on build day, compiled from source.
# Verified below: the build stops if the repository is not the pinned binary one.
RUN echo "options(repos = c(CRAN = '${CRAN}'), Ncpus = parallel::detectCores())" >> /usr/local/lib/R/etc/Rprofile.site \
 && Rscript -e "stopifnot(grepl('packagemanager', getOption('repos')[['CRAN']]))" \
            -e "source('/tmp/install_r_packages.R')" \
 && rm /tmp/install_r_packages.R

# Quarto, needed to render the notebook.
ARG QUARTO_VERSION=1.8.27
RUN curl -fsSL -o /tmp/quarto.deb "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
 && dpkg -i /tmp/quarto.deb && rm /tmp/quarto.deb

# The workflow itself. Data are never copied in: the demo downloads a public
# cFMD release at run time, and your own tables are mounted.
WORKDIR /work
COPY analysis/ analysis/
COPY R/ R/
COPY scripts/ scripts/
COPY tests/ tests/
COPY conda/ conda/
# The three shipped configs: the template for your own data, the demo (the
# default command below) and the full cFMD category run, so both cFMD runs
# work without mounting a config.
COPY config.yaml config_cfmd_demo.yaml config_cfmd_category.yaml LICENSE NOTICE README.md CHANGELOG.md CITATION.cff ./

# TabPFN weights land here; mount a volume to keep them across runs.
ENV TABPFN_MODEL_CACHE_DIR=/work/.cache/tabpfn
# A container never has a browser. With this set, the TabPFN package does not
# try to open one for the licence acceptance: it relies on TABPFN_TOKEN and,
# when that is missing, stops at once with a message naming it. Set here, so
# no run command has to pass it.
ENV TABPFN_NO_BROWSER=1
# input/ stays empty on purpose — no data ship in this image — but it must
# exist: the multi-rank wrapper recognises a project root by the presence of
# config.yaml, R/, analysis/ AND input/, and refuses to start without it.
RUN mkdir -p /work/.cache/tabpfn /work/out /work/input

# Let the container run as the calling user (docker run --user "$(id -u):$(id -g)"),
# so the files in out/ belong to them instead of root. Quarto renders next to
# the notebook and TabPFN caches under HOME, so both must be writable by anyone;
# HOME points at /tmp because an arbitrary uid has no home directory here.
RUN chmod -R a+rwX /work/analysis /work/out /work/input /work/.cache
ENV HOME=/tmp

# Name the image after TabFlux. Without these lines it inherits the labels of
# the base image (rocker/r-ver: its title, authors, licence and source), and
# GitHub's package page shows rocker's description as TabFlux's own. They sit
# at the end so that changing them never invalidates the cached build steps.
# TABFLUX_REVISION is the git commit the image was built from: CI passes it,
# a local build says "local-build".
ARG TABFLUX_REVISION=local-build
LABEL org.opencontainers.image.title="TabFlux" \
      org.opencontainers.image.description="Machine-learning classification of microbial community profiles, with grouped and nested evaluation: classic learners and TabPFN, in R/mlr3 and Quarto." \
      org.opencontainers.image.version="1.6.0" \
      org.opencontainers.image.revision="${TABFLUX_REVISION}" \
      org.opencontainers.image.source="https://github.com/iLivius/TabFlux" \
      org.opencontainers.image.documentation="https://ilivius.github.io/TabFlux/" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.authors="Livio Antonielli, Lukas Pucher" \
      org.opencontainers.image.vendor="AIT Austrian Institute of Technology" \
      org.opencontainers.image.base.name="docker.io/rocker/r-ver:4.5.3"

# Default: the public cFMD demo. To run your own data, mount your input files
# and config over the image's copies (relative config paths resolve against
# /work) and set output.dir: "/work/out" in that config:
#   mkdir -p out ~/.cache/tabpfn
#   docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
#     -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
#     -v "$PWD/input:/work/input:ro" -v "$PWD/config.yaml:/work/config.yaml:ro" \
#     ghcr.io/ilivius/tabflux:1.6.0 Rscript scripts/run_multi_tax_levels.R config.yaml
# The full cFMD category run is shipped too, so it needs no config mount:
#   mkdir -p out ~/.cache/tabpfn
#   docker run --rm --gpus all --user "$(id -u):$(id -g)" -e TABPFN_TOKEN \
#     -v "$HOME/.cache/tabpfn:/work/.cache/tabpfn" -v "$PWD/out:/work/out" \
#     ghcr.io/ilivius/tabflux:1.6.0 Rscript scripts/run_multi_tax_levels.R config_cfmd_category.yaml
CMD ["Rscript", "scripts/run_multi_tax_levels.R", "config_cfmd_demo.yaml"]
