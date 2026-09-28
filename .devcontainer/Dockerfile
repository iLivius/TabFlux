# Development container: run analysis/tabflux.qmd chunk by chunk from VS Code
# (or Positron) with exactly the software of the TabFlux image - R 4.5 and its
# date-pinned packages, Quarto, the TabPFN Python environment and CUDA.
# Built by .devcontainer/devcontainer.json; nothing else uses this file.
#
# It starts FROM the TabFlux image instead of rebuilding it, so opening the
# container takes about a minute, not the twenty a full build needs. The image
# is pulled from GitHub's registry the first time. To use an image built from
# this checkout instead, build it under the same name before opening the
# container:
#   docker build -t ghcr.io/ilivius/tabflux:1.6.0 .
# The tag follows the release: update it with every version bump.
ARG TABFLUX_IMAGE=ghcr.io/ilivius/tabflux:1.6.0
FROM ${TABFLUX_IMAGE}

# The TabFlux image has only root. Files that root writes into the mounted
# checkout (the run folders under out/, the cFMD download) would come back
# owned by root on the host, and could not be deleted without sudo.
# This adds an ordinary user for the editor session. When the container starts,
# VS Code gives this user the host user's UID and GID (updateRemoteUserUID in
# devcontainer.json), so everything the notebook writes belongs to you.
# /home/tabflux/.cache/tabpfn is where the host's TabPFN cache is mounted:
# model weights and the Prior Labs licence token (see devcontainer.json).
RUN useradd --create-home --shell /bin/bash tabflux \
 && mkdir -p /home/tabflux/.cache/tabpfn \
 && chown -R tabflux:tabflux /home/tabflux
