#!/usr/bin/env Rscript

# Install the R packages used by the TabFlux workflow into the active Conda
# environment. This keeps project dependencies isolated from the main system.

# Respect a repository the caller has already chosen. The container sets a
# date-pinned Posit repository that serves PRECOMPILED Linux binaries; hard
# coding the CRAN source mirror here would override it and rebuild ~540
# packages from source, which is both slow and the reason R environments break
# on machines with different system libraries. "@CRAN@" is R's placeholder for
# "no mirror chosen yet".
current_cran <- getOption("repos")[["CRAN"]]
if (is.null(current_cran) || identical(current_cran, "@CRAN@") || !nzchar(current_cran)) {
  options(repos = c(CRAN = "https://cloud.r-project.org"))
}
message("Installing R packages from: ", getOption("repos")[["CRAN"]])

# The CRAN packages the workflow calls by name: the ones analysis/tabflux.qmd
# attaches (its base_pkgs list, apart from base R's parallel; plus mlr3fairness
# when a protected attribute is set, mlr3torch for the MLP and reticulate for
# TabPFN), the ones the notebook, R/ helpers and scripts use without listing
# them there (conflicted, R.utils for .csv.gz input, digest, lgr, readr,
# stringr, yaml), the learners' own packages (xgboost, torch) and the
# installers (pacman, remotes). The other learner back-ends (glmnet; e1071 for
# the SVM) are not listed: mlr3learners names them as optional packages
# ("Suggests"), and dependencies = TRUE below installs those along with it.
# Keep this list and base_pkgs in step when a package is added or dropped.
cran_packages <- c(
  "callr", "compositions", "conflicted", "data.table",
  "emoa", "factoextra", "fastVoteR",
  "digest", "FSelectorRcpp", "future", "future.apply", "iml", "jsonlite",
  "kknn", "lgr", "magrittr", "mlr3fairness", "mlr3filters", "mlr3fselect",
  "mlr3hyperband", "mlr3learners", "mlr3pipelines",
  "mlr3torch", "mlr3tuning", "mlr3viz", "pacman",
  "paradox", "patchwork", "progressr", "Rtsne", "ranger",
  "readr", "remotes", "reticulate", "R.utils", "scales", "smotefamily", "stabm",
  "stringr", "tidyverse", "torch",
  "xgboost", "yaml", "zCompositions"
)

install_conda_r_packages <- function(packages) {
  conda_prefix <- Sys.getenv("CONDA_PREFIX", unset = "")
  conda_exe <- Sys.getenv("CONDA_EXE", unset = Sys.which("conda"))

  if (!nzchar(conda_prefix) || !nzchar(conda_exe) || !length(packages)) {
    return(invisible(FALSE))
  }

  message(
    "Installing compiled R dependencies from conda-forge into the active env: ",
    paste(packages, collapse = ", ")
  )

  status <- system2(
    conda_exe,
    c("install", "-y", "--freeze-installed", "-p", conda_prefix, "-c", "conda-forge", packages)
  )

  if (!identical(status, 0L)) {
    warning(
      "Conda installation failed for: ",
      paste(packages, collapse = ", "),
      ". Falling back to CRAN where possible."
    )
    return(invisible(FALSE))
  }

  invisible(TRUE)
}

conda_r_package_map <- c(
  igraph = "r-igraph",
  kknn = "r-kknn",
  smotefamily = "r-smotefamily"
)

missing_conda_r_packages <- names(conda_r_package_map)[!vapply(
  names(conda_r_package_map),
  requireNamespace,
  quietly = TRUE,
  FUN.VALUE = logical(1)
)]

if (length(missing_conda_r_packages)) {
  install_conda_r_packages(unname(conda_r_package_map[missing_conda_r_packages]))
}

missing_packages <- cran_packages[!vapply(
  cran_packages,
  requireNamespace,
  quietly = TRUE,
  FUN.VALUE = logical(1)
)]

if (length(missing_packages)) {
  install.packages(missing_packages, dependencies = TRUE)
}

# mlr3extralearners is not on CRAN. r-universe serves it (and its
# dependencies) the same way CRAN does, so install.packages() can fetch a
# build instead of compiling a GitHub checkout; remotes::install_github stays
# as the fallback when r-universe is unreachable.
if (!requireNamespace("mlr3extralearners", quietly = TRUE)) {
  ok <- tryCatch({
    install.packages("mlr3extralearners",
                     repos = c("https://mlr-org.r-universe.dev", getOption("repos")))
    requireNamespace("mlr3extralearners", quietly = TRUE)
  }, error = function(e) FALSE)
  if (!ok) {
    remotes::install_github("mlr-org/mlr3extralearners@*release",
                            upgrade = "never", dependencies = TRUE)
  }
}

# Install the torch backend only when explicitly requested. Most workflows in
# this repository do not need it, and it is a larger download.
if (identical(Sys.getenv("INSTALL_R_TORCH", unset = "0"), "1")) {
  if (!torch::torch_is_installed()) {
    torch::install_torch()
  }
}

message("R package bootstrap completed for the active Conda environment.")
