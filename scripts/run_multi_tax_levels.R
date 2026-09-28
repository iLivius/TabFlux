#!/usr/bin/env Rscript

# Multi-level wrapper around analysis/tabflux.qmd.
#
# The notebook models ONE taxonomic level per run: the raw ASV table, or the ASV
# counts summed to phylum ... species. Comparing taxonomic levels needs one render
# per level, so this script renders the notebook once per level ("child render"
# below) and stacks the per-level metric tables into one.
#
# Data flow:
#   config.yaml (dataset.tax_level = one level, or a YAML list of levels)
#     -> one temporary one-level config per level
#     -> `quarto render analysis/tabflux.qmd` once per level
#        -> <date>_<ds>_<ver>_target_<t>_tax_<level>_saved_learners/metrics/*.csv
#        -> tabflux_<ver>_<level>.html in the output directory
#     -> <date>_<ds>_<ver>_multi_tax_results/
#          performance_metrics_all_tax_levels.csv/.rds  (all levels stacked)
#          fold_metrics_all_tax_levels.csv, lodo_metrics_all_tax_levels.csv/.png
#          lodo_metrics_all_tax_levels_wide.csv  (groups x ranks, one block per method and metric)
#          multi_tax_run_manifest.csv  (where each level wrote its outputs)
# The stacked tables are the cross-level comparison; the per-level folders keep
# the full detail (models, SHAP, ...).
#
# Usage, from the project root:
#   Rscript scripts/run_multi_tax_levels.R
#   Rscript scripts/run_multi_tax_levels.R config.yaml analysis/tabflux.qmd
# Both arguments are optional: 1 = YAML config path, 2 = Quarto notebook path.
# Example YAML input:
#   dataset:
#     tax_level:
#       - phylum
#       - class
#       - order
#       - family
#       - genus
args <- commandArgs(trailingOnly = TRUE)
config_arg <- if (length(args) >= 1) args[[1]] else "config.yaml"
qmd_arg <- if (length(args) >= 2) args[[2]] else file.path("analysis", "tabflux.qmd")

# Turn a config/notebook path from the command line into a full path.
# Input: the path as typed, plus the project root from find_project_root() below.
# Tries it as given, then relative to the root; stops naming the path if neither
# exists. Output: absolute path -> config_path / qmd_path.
resolve_existing_path <- function(path, base_dir = getwd()) {
  candidate_paths <- unique(c(path, file.path(base_dir, path)))
  for (candidate_path in candidate_paths) {
    if (file.exists(candidate_path)) {
      return(normalizePath(candidate_path, winslash = "/", mustWork = TRUE))
    }
  }

  stop(sprintf("Path not found: %s", path))
}

# Find where this script file lives. `Rscript path/to/x.R` records the script path
# as a `--file=...` argument; read it back so find_project_root() can search
# upward from the script's own folder even when the shell sits elsewhere.
# Returns "" when run interactively; the caller skips empty seeds.
get_script_path <- function() {
  script_arg <- grep("^--file=", commandArgs(), value = TRUE)
  if (!length(script_arg)) {
    return("")
  }

  normalizePath(sub("^--file=", "", script_arg[[1]]), winslash = "/", mustWork = FALSE)
}

# A folder is the project root when it holds config.yaml plus R/, input/ and
# analysis/. The notebook has its own copy of this test (is_project_root inside
# resolve_project_root, first chunk) without the analysis/ condition, because only
# the wrapper has to find the .qmd. Keep the three shared conditions identical, or
# wrapper and notebook can disagree on where "the project" is.
is_project_root <- function(path) {
  file.exists(file.path(path, "config.yaml")) &&
    dir.exists(file.path(path, "R")) &&
    dir.exists(file.path(path, "input")) &&
    dir.exists(file.path(path, "analysis"))
}

# Search upward from the shell's working directory, the script's folder (scripts/)
# and its parent, so the wrapper works whether it is launched from the repository
# root or by script path. Output: the root path, stored as `workdir`. It anchors
# every path below and reaches each child render as TABFLUX_WORKDIR.
find_project_root <- function() {
  seed_paths <- unique(c(
    getwd(),
    dirname(get_script_path()),
    dirname(dirname(get_script_path()))
  ))
  seed_paths <- seed_paths[nzchar(seed_paths)]

  for (seed_path in seed_paths) {
    candidate_path <- normalizePath(seed_path, winslash = "/", mustWork = FALSE)
    repeat {
      if (is_project_root(candidate_path)) {
        return(candidate_path)
      }

      parent_path <- dirname(candidate_path)
      if (identical(parent_path, candidate_path)) {
        break
      }
      candidate_path <- parent_path
    }
  }

  stop(
    "Could not resolve the project root. Run this script from the repository root ",
    "or pass absolute paths for the config and notebook."
  )
}

# Turn `dataset.tax_level` from config.yaml into a character vector, one entry per
# level to run. YAML gives a string for one level and a list for several; both
# must work. Missing or empty becomes "" = raw ASV table, no aggregation, the same
# convention the notebook uses. Output -> canonical_tax_level_value().
normalize_tax_levels_input <- function(x) {
  if (is.null(x)) {
    return("")
  }

  if (is.list(x)) {
    x <- unlist(x, recursive = TRUE, use.names = FALSE)
  }

  x <- trimws(as.character(x))
  x <- x[!is.na(x)]
  if (!length(x)) {
    return("")
  }

  x
}

# The single validation point for a taxonomic level.
# Input: one value as typed in the config ("Genus", "ASV", "", ...).
# Output: the lowercase key ("genus", "asv", ""), or stop() listing the allowed
# values. "", "asv" and "sgb" all mean "do not aggregate": keep the finest level
# the input provides. "sgb" is for shotgun profiles, whose finest unit is a
# species-level genome bin, not an ASV. The three helpers below spell this key out
# as label, folder slug and config value.
canonical_tax_level_value <- function(x = "") {
  valid_tax_levels <- c("", "asv", "sgb", "phylum", "class", "order", "family", "genus", "species")

  if (is.null(x) || length(x) == 0) {
    return("")
  }

  tax_level_value <- trimws(as.character(x[[1]]))
  if (is.na(tax_level_value) || !nzchar(tax_level_value)) {
    return("")
  }

  tax_level_key <- tolower(tax_level_value)
  if (!(tax_level_key %in% valid_tax_levels)) {
    stop(
      "Parameter 'tax_level' must be one of: \"\", \"ASV\", \"SGB\", \"phylum\", \"class\", ",
      "\"order\", \"family\", \"genus\", or \"species\"."
    )
  }

  tax_level_key
}

# Spelling 1 of 3, the human-readable label: "ASV" or "SGB" in capitals, as papers
# write them, or the lowercase rank name. Used in console messages, the run
# manifest and the tax_level column of the stacked metric tables.
format_tax_level_label <- function(x = "") {
  tax_level_key <- canonical_tax_level_value(x)
  if (identical(tax_level_key, "sgb")) {
    return("SGB")
  }
  if (!nzchar(tax_level_key) || identical(tax_level_key, "asv")) {
    return("ASV")
  }

  tax_level_key
}

# Spelling 2 of 3, the file-safe "slug" ("asv", "genus"): the label in lowercase,
# safe inside file and folder names. Used in the temp config name, the per-level
# HTML name, the tax_<slug> part of each save folder and the tax_level_key column.
# Must match make_tax_level_slug() in the notebook, or the wrapper looks for the
# child outputs in the wrong folder.
make_tax_level_slug <- function(x = "") {
  tolower(format_tax_level_label(x))
}

# Spelling 3 of 3, the config value: the notebook reads "" as "ASV level",
# so both "asv" and "" are written back as "" in each child config; the
# other ranks are written as their lowercase name.
normalize_tax_level_for_config <- function(x = "") {
  tax_level_key <- canonical_tax_level_value(x)
  if (identical(tax_level_key, "sgb")) {
    return("sgb")
  }
  if (!nzchar(tax_level_key) || identical(tax_level_key, "asv")) {
    return("")
  }

  tax_level_key
}

# File-name-safe version of the prediction target (dataset.target in config.yaml):
# lower case, runs of non-alphanumeric characters replaced by "-", an empty target
# becomes "unspecified". Same logic as make_target_slug() in the notebook's "Set
# Parameters" section, because the target is part of every save-folder name.
make_target_slug <- function(x = "") {
  value <- trimws(as.character(if (length(x)) x[[1]] else ""))
  if (!nzchar(value)) value <- "unspecified"
  value <- gsub("[^A-Za-z0-9]+", "-", value)
  value <- gsub("^-+|-+$", "", value)
  tolower(value)
}

# Name of the folder where one child render saves everything (models,
# metrics, SHAP plots):
#   <run_date>_<ds>_<ver>_target_<target>_tax_<level>_saved_learners
#   e.g. 2026-09-23_TabFlux_demo_target_category_tax_sgb_saved_learners
# A copy of the notebook's build_tax_level_save_dir(): the child never reports its
# folder name back, so the wrapper recomputes it and the two copies must stay
# identical. The metrics CSVs are read from <this folder>/metrics/ after each render.
build_tax_level_save_dir <- function(run_date, ds, ver, tax_level = "", target = "") {
  paste(
    run_date,
    ds,
    ver,
    paste0("target_", make_target_slug(target)),
    paste0("tax_", make_tax_level_slug(tax_level)),
    "saved_learners",
    sep = "_"
  )
}

# Resolve the project root and the two main inputs up front so the rest of the
# script can work with full paths.
workdir <- find_project_root()
config_path <- resolve_existing_path(config_arg, base_dir = workdir)
qmd_path <- resolve_existing_path(qmd_arg, base_dir = workdir)

# Each child render gets its own temporary YAML file, so check for YAML support
# before starting the run loop.
if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required to run the multi-tax wrapper.")
}

# Reuse the notebook's config helpers so both entry points read the YAML the same
# way. load_tabflux_config() fills missing fields with the project defaults and
# stops if the file is missing.
source(file.path(workdir, "R", "tabflux_config_helpers.R"))

# Summary helpers used at the very end of this script: the wide group-by-rank
# LODO table and the per-group figure (see R/tabflux_summary_helpers.R).
source(file.path(workdir, "R", "tabflux_summary_helpers.R"))

# Read the config, extract the requested taxonomic levels, and drop duplicates
# so the script does not rerun the same level twice.
tabflux_config <- load_tabflux_config(config_path)
tax_levels <- normalize_tax_levels_input(tabflux_config$dataset$tax_level)
tax_levels <- unique(vapply(tax_levels, canonical_tax_level_value, character(1)))

# ── Shared libraries of the TabPFN environment ────────────────────────────────
# The v2.5 environment (tabflux-tabpfn-gpu) uses the conda-forge PyTorch, which
# links against Intel MKL inside the environment. An embedded Python interpreter
# finds those libraries only through LD_LIBRARY_PATH, which a process cannot
# change after it starts - the notebook's own Sys.setenv() reaches its workers,
# not the render. Every render below is a child process of this script, so
# setting it here is what makes that import work. The default 3.5 environment
# (pip PyTorch) does not need it, and it does no harm there. Appended, so R keeps
# its own libraries first (R's own BLAS stays in use). Precedence as in the notebook: config.yaml, TABPFN_*, then a
# detected Conda root. Skipped when TabPFN is not picked.
#
# Which environment: when TabPFN's Python is given directly (runtime.tabpfn.python
# or TABPFN_PYTHON, <env>/bin/python), its environment is two folders up;
# otherwise it is the Conda environment named by env_name. Only a Conda
# environment (recognised by its conda-meta/ folder) needs its lib/ added. The
# container gives TabPFN's Python directly, from a plain Python environment
# (/opt/venv) with nothing to add, so the step says nothing there.
if ("tabpfn" %in% unlist(tabflux_config$methods$pick)) {
  tabpfn_cfg <- tabflux_config$runtime$tabpfn
  first_non_empty <- function(...) {
    for (v in list(...)) if (length(v) && !is.na(v[[1]]) && nzchar(trimws(as.character(v[[1]])))) return(as.character(v[[1]]))
    ""
  }
  python_given <- first_non_empty(tabpfn_cfg$python, Sys.getenv("TABPFN_PYTHON"))
  if (nzchar(python_given)) {
    env_dir <- dirname(dirname(python_given))          # <env>/bin/python -> <env>
  } else {
    conda_root <- first_non_empty(tabpfn_cfg$conda_root, Sys.getenv("TABPFN_CONDA_ROOT"),
                                  tryCatch(system2("conda", c("info", "--base"), stdout = TRUE, stderr = FALSE)[1],
                                           error = function(e) ""))
    env_name <- first_non_empty(tabpfn_cfg$env_name, Sys.getenv("TABPFN_ENV_NAME"), "tabflux-tabpfn35-gpu")
    env_dir <- if (dir.exists(env_name)) env_name else file.path(conda_root, "envs", env_name)
  }
  env_lib <- file.path(env_dir, "lib")
  if (dir.exists(file.path(env_dir, "conda-meta")) && dir.exists(env_lib)) {
    ld_now <- Sys.getenv("LD_LIBRARY_PATH", unset = "")
    if (!grepl(env_lib, ld_now, fixed = TRUE)) {
      Sys.setenv(LD_LIBRARY_PATH = paste(c(if (nzchar(ld_now)) ld_now, env_lib), collapse = .Platform$path.sep))
    }
    message("TabPFN environment libraries appended to LD_LIBRARY_PATH for the renders: ", env_lib)
  } else if (!nzchar(python_given)) {
    # Conda route, but no environment where env_name points: say so now; the
    # notebook stops with the exact problem if the TabPFN import then fails.
    message("TabPFN Conda environment not found (", env_dir, "); the notebook will report the exact problem if the import fails.")
  }
}

# An empty `tax_level` still means "run the ASV-level workflow".
if (!length(tax_levels)) {
  tax_levels <- ""
}

# Quarto still does the actual rendering, so fail early if the CLI is not
# available.
quarto_bin <- Sys.which("quarto")
if (!nzchar(quarto_bin)) {
  stop("Quarto CLI not found in PATH. Install it before running this wrapper.")
}

# One run date for the whole multi-level run. output.run_date may be "" (= today);
# it is fixed here once and pushed into every child config, so all per-level
# folders share the same date prefix even if the renders cross midnight. Otherwise
# build_tax_level_save_dir() would look in a folder dated differently from the one
# the child wrote.
run_date <- as.character(tabflux_config$output$run_date[[1]])
if (!nzchar(run_date) || is.na(run_date)) {
  run_date <- as.character(Sys.Date())
}

# Dataset id, version and target (config.yaml, dataset.*) appear in every
# folder name. The stacked tables go to <run_date>_<ds>_<ver>_multi_tax_results/
# in the output directory (output.dir below; empty = the project root), next to
# the per-level *_saved_learners/ folders that the child renders create.
ds     <- as.character(tabflux_config$dataset$id[[1]])
ver    <- as.character(tabflux_config$dataset$version[[1]])
target <- as.character(tabflux_config$dataset$target[[1]])
# output.dir decides where results go; empty means the project root. The child
# renders read the same key, so every rank writes beside the combined folder.
# Resolved exactly as the notebook resolves it: an absolute path (starting with
# "/" or a drive letter) is used as written, a relative one is taken from the
# project root. A folder that does not exist yet is created, as the notebook
# does, so a fresh results folder or an empty mounted volume needs no mkdir.
output_dir_cfg <- as.character(tabflux_config$output$dir[[1]] %||% "")
if (!nzchar(output_dir_cfg)) {
  output_dir <- workdir
} else if (grepl("^(/|[A-Za-z]:)", output_dir_cfg)) {
  output_dir <- output_dir_cfg
} else {
  output_dir <- file.path(workdir, output_dir_cfg)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(output_dir)) {
  stop(sprintf("output.dir '%s' does not exist and could not be created.", output_dir))
}
output_dir <- normalizePath(output_dir, winslash = "/", mustWork = TRUE)
combined_dir <- file.path(output_dir, paste(run_date, ds, ver, "multi_tax_results", sep = "_"))
dir.create(combined_dir, recursive = TRUE, showWarnings = FALSE)

# Print a short summary before the renders start.
message("Wrapper config: ", config_path)
message("Notebook: ", qmd_path)
message("Taxonomic levels: ", paste(vapply(tax_levels, format_tax_level_label, character(1)), collapse = ", "))

# Two collectors, one slot per level, filled inside the loop:
# - combined_metrics: each level's performance_metrics_long.csv (one row per
#   method x data split x metric), stacked after the loop;
# - run_manifest: one row per level with its metrics file, save folder and HTML,
#   so a summary number can be traced back to that level's full outputs
#   (read_level_metrics() below reuses these paths).
combined_metrics <- vector("list", length(tax_levels))
run_manifest <- vector("list", length(tax_levels))
names(combined_metrics) <- vapply(tax_levels, make_tax_level_slug, character(1))

# Render the single-level notebook once per requested level. Each pass: write a
# one-level config -> quarto render -> move the HTML -> read that level's metrics
# into the collectors. Levels run in turn; a failed level stops the whole run.
for (i in seq_along(tax_levels)) {
  tax_level_i <- tax_levels[[i]]
  tax_level_i_label <- format_tax_level_label(tax_level_i)
  tax_level_i_slug <- make_tax_level_slug(tax_level_i)

  # Write a one-level config for this child render so the notebook can stay
  # focused on one taxonomic level at a time.
  child_config <- tabflux_config
  child_config$output$run_date <- run_date
  child_config$dataset$tax_level <- normalize_tax_level_for_config(tax_level_i)

  # Feature importance is the most expensive optional step (SHAP on TabPFN takes
  # hours per level). importance.levels lists the levels that keep it; every other
  # level runs with the importance chunk off. An empty list keeps it on everywhere.
  importance_levels <- tolower(unlist(tabflux_config$importance$levels, use.names = FALSE))
  if (length(importance_levels) && !(tax_level_i_slug %in% importance_levels)) {
    child_config$importance$method <- "none"
    message(sprintf(
      "Feature importance switched off for '%s' (importance.levels = %s).",
      tax_level_i_label, paste(importance_levels, collapse = ", ")
    ))
  }

  # Write the one-level config to a temporary YAML file; the child gets its path
  # through TABFLUX_CONFIG (see the render call). The temp file dies with this R
  # session, so config.yaml plus the level list is the only record of what ran.
  child_config_path <- tempfile(
    pattern = paste0("tabflux_", tax_level_i_slug, "_"),
    tmpdir = tempdir(),
    fileext = ".yaml"
  )
  yaml::write_yaml(child_config, child_config_path)

  # Work out where this child will write before it runs: the save folder (named by
  # build_tax_level_save_dir above), the metrics table inside it that gets stacked
  # (performance_metrics_long.csv, from the notebook's metrics-export chunk), and
  # the HTML report name (e.g. tabflux_demo_sgb.html).
  child_save_dir <- file.path(
    output_dir,
    build_tax_level_save_dir(
      run_date = run_date,
      ds = ds,
      ver = ver,
      tax_level = tax_level_i,
      target = target
    )
  )
  child_metrics_path <- file.path(child_save_dir, "metrics", "performance_metrics_long.csv")
  # The report name carries the dataset version as well as the rank, so two
  # runs from the same folder with different dataset.version values never
  # overwrite each other's reports.
  child_output_filename <- sprintf(
    "%s_%s_%s.html",
    tools::file_path_sans_ext(basename(qmd_path)),
    ver,
    tax_level_i_slug
  )
  # Render into analysis/ so embed-resources can resolve the companion _files/
  # directory, then move the finished HTML to the output directory.
  child_output_in_analysis <- file.path(dirname(qmd_path), child_output_filename)
  child_output_final <- file.path(output_dir, child_output_filename)

  # Print progress because these renders can take a while.
  message(sprintf(
    "Running full pipeline for taxonomic level '%s' (%d/%d).",
    tax_level_i_label,
    i,
    length(tax_levels)
  ))

  # Launch Quarto from analysis/ so the HTML and its companion _files/ directory
  # land together; embed-resources needs that to resolve the lib files.
  # `local({ ... })` scopes the directory change and on.exit() undoes it even if
  # the render fails.
  # The child reads its settings from three environment variables (notebook,
  # first two chunks):
  #   TABFLUX_CONFIG         -> the one-level config written above
  #   TABFLUX_WORKDIR  -> project root (fallback for resolve_project_root)
  #   TABFLUX_NOTEBOOK_PATH  -> notebook path (first choice for that search)
  # Set here, inherited by Quarto, then put back. system2()'s own `env =` is
  # tidier but Linux/macOS only; on Windows the child would render the full config.
  # `status` is Quarto's exit code: 0 = rendered, anything else = failure.
  status <- local({
    old_wd <- setwd(dirname(qmd_path))
    old_env <- Sys.getenv(c("TABFLUX_CONFIG", "TABFLUX_WORKDIR", "TABFLUX_NOTEBOOK_PATH"),
                          unset = NA)
    on.exit({
      setwd(old_wd)
      for (var in names(old_env)) {
        if (is.na(old_env[[var]])) {
          Sys.unsetenv(var)
        } else {
          # Sys.setenv() wants name = value arguments; build them from the
          # variable name held in `var`.
          do.call(Sys.setenv, as.list(stats::setNames(old_env[[var]], var)))
        }
      }
    })
    Sys.setenv(
      TABFLUX_CONFIG = child_config_path,
      TABFLUX_WORKDIR = workdir,
      TABFLUX_NOTEBOOK_PATH = qmd_path
    )
    system2(
      quarto_bin,
      args = c("render", qmd_path, "--output", child_output_filename),
      stdout = "",
      stderr = ""
    )
  })

  # Stop immediately if one child run fails so the combined output never mixes
  # completed and incomplete levels.
  if (!identical(status, 0L)) {
    stop(sprintf("Child render failed for taxonomic level '%s'.", tax_level_i_label))
  }

  # Move the self-contained HTML from analysis/ to the output directory.
  # file.rename() fails with "Invalid cross-device link" when the two paths are
  # on different filesystems, which is exactly the container case: the code sits
  # in an image layer and the output directory is a mounted volume. Copy and
  # delete instead, which works either way.
  # suppressWarnings(): file.rename() warns about the cross-device case itself,
  # and a user should not see an alarm for a situation the next line handles.
  if (!suppressWarnings(file.rename(child_output_in_analysis, child_output_final))) {
    if (file.copy(child_output_in_analysis, child_output_final, overwrite = TRUE)) {
      unlink(child_output_in_analysis)
    } else {
      warning("Could not move the report to ", child_output_final,
              "; it is still at ", child_output_in_analysis)
    }
  }

  # Confirm that the expected metrics file was created before trusting the run.
  if (!file.exists(child_metrics_path)) {
    stop(sprintf(
      "Expected metrics file for taxonomic level '%s' was not created at '%s'.",
      tax_level_i_label,
      child_metrics_path
    ))
  }

  # Read this level's performance_metrics_long.csv into its slot. The notebook
  # already added the tax_level / tax_level_key columns, so levels stay
  # distinguishable after stacking. check.names = FALSE keeps metric names such as
  # "balanced accuracy" as written.
  combined_metrics[[tax_level_i_slug]] <- utils::read.csv(
    child_metrics_path,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )

  # One manifest row per level: label, slug and the three paths a reader
  # needs to get from a summary number back to the full per-level outputs.
  run_manifest[[i]] <- data.frame(
    tax_level = tax_level_i_label,
    tax_level_key = tax_level_i_slug,
    metrics_path = child_metrics_path,
    save_dir = child_save_dir,
    output_file = child_output_final,
    stringsAsFactors = FALSE
  )
}

# Stack the per-level tables into one long table (tax_level, tax_level_key,
# data_split, target, n_samples, n_features, method, learner_id, metric, value)
# and one manifest pointing back to the per-level outputs. The stacked table
# answers the cross-level question: which rank gives the best classifier?
performance_metrics_all_tax_levels <- do.call(rbind, combined_metrics)
run_manifest_df <- do.call(rbind, run_manifest)

combined_metrics_path <- file.path(combined_dir, "performance_metrics_all_tax_levels.csv")
combined_metrics_rds_path <- file.path(combined_dir, "performance_metrics_all_tax_levels.rds")
manifest_path <- file.path(combined_dir, "multi_tax_run_manifest.csv")

# Save the combined results in both CSV and RDS form, plus the manifest. The
# CSV is easy to inspect, and the RDS preserves types.
utils::write.csv(
  performance_metrics_all_tax_levels,
  combined_metrics_path,
  row.names = FALSE
)
saveRDS(performance_metrics_all_tax_levels, combined_metrics_rds_path)
utils::write.csv(run_manifest_df, manifest_path, row.names = FALSE)

# ── Fold-level and LODO metrics across levels ─────────────────────────────────
# Each level's notebook also writes metrics/fold_metrics.csv (one row per method x
# resampling fold) and, when dataset.group is set, metrics/lodo_metrics.csv (the
# same rows labelled with the held-out group or groups). Stack them with a
# tax_level column so the per-group picture can be compared across ranks in one
# table, plus a figure.
# Input: a file name inside each level's metrics/ folder (paths from
# run_manifest_df). Output: one data frame with tax_level and tax_level_key as the
# first two columns, or NULL when no level produced that file.
read_level_metrics <- function(file_name) {
  tables <- list()
  for (i in seq_len(nrow(run_manifest_df))) {
    path <- file.path(run_manifest_df$save_dir[i], "metrics", file_name)
    if (!file.exists(path)) next   # e.g. lodo_metrics.csv in an ungrouped run
    table_i <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
    table_i$tax_level <- run_manifest_df$tax_level[i]
    table_i$tax_level_key <- run_manifest_df$tax_level_key[i]
    tables[[i]] <- table_i[, c("tax_level", "tax_level_key",
                               setdiff(names(table_i), c("tax_level", "tax_level_key")))]
  }
  if (!length(tables)) return(NULL)
  do.call(rbind, tables)
}

# Fold-level table: one row per method x fold x level, plus n_test and the class
# counts of each fold's test set - the spread behind the averaged numbers.
fold_metrics_all <- read_level_metrics("fold_metrics.csv")
if (!is.null(fold_metrics_all)) {
  fold_all_path <- file.path(combined_dir, "fold_metrics_all_tax_levels.csv")
  utils::write.csv(fold_metrics_all, fold_all_path, row.names = FALSE)
  message("Saved fold-level metrics for all levels to: ", fold_all_path)
}

# Per-group table, labelled with the held-out group(s) of each fold
# (heldout_dataset): one group per fold under LODO (leave-one-dataset-out), a
# slice of the groups under grouped cross-validation. Only exists when
# dataset.group is set (LODO or grouped cv); in an ungrouped run
# read_level_metrics() returns NULL and this block is skipped.
lodo_metrics_all <- read_level_metrics("lodo_metrics.csv")
if (!is.null(lodo_metrics_all)) {
  lodo_all_path <- file.path(combined_dir, "lodo_metrics_all_tax_levels.csv")
  utils::write.csv(lodo_metrics_all, lodo_all_path, row.names = FALSE)
  message("Saved LODO per-group metrics for all levels to: ", lodo_all_path)

  # Ranks in config order (phylum -> species): the column order of the wide
  # table and the panel order of the figure.
  level_order <- unique(run_manifest_df$tax_level)

  # Wide view: for balanced accuracy and AUC, one block per method, groups down the
  # rows, ranks across the columns, mean row at the bottom. Read this to ask "which
  # rank transfers to which group"; the long CSV above feeds further analyses.
  lodo_wide <- pivot_lodo_metrics_wide(lodo_metrics_all, level_order = level_order)
  lodo_wide_path <- file.path(combined_dir, "lodo_metrics_all_tax_levels_wide.csv")
  utils::write.csv(lodo_wide, lodo_wide_path, row.names = FALSE, na = "")
  message("Saved wide group-by-rank LODO table to: ", lodo_wide_path)

  # Per-group figure: balanced accuracy per held-out group, one panel per rank,
  # one bar colour per method. The subtitle states whether the bars are nested
  # estimates (evaluation.nested TRUE) or the non-nested internal ones, so the figure
  # cannot be misread on its own. Needs ggplot2; the long CSV above is always
  # written, so plot_lodo_metrics_by_level() can redraw the figure later.
  if (requireNamespace("ggplot2", quietly = TRUE)) {
    lodo_plot <- plot_lodo_metrics_by_level(
      lodo_metrics_all, level_order = level_order,
      nested = isTRUE(tabflux_config$evaluation$nested),
      outer = as.character(tabflux_config$evaluation$outer[[1]])
    )
    lodo_plot_path <- file.path(combined_dir, "lodo_metrics_all_tax_levels.png")
    ggplot2::ggsave(lodo_plot_path, lodo_plot, width = 12, height = 9, dpi = 300, bg = "white")
    # Vector copy next to it, for a figure that has to be scaled or edited.
    if (requireNamespace("svglite", quietly = TRUE)) {
      ggplot2::ggsave(sub("\\.png$", ".svg", lodo_plot_path), lodo_plot,
                      width = 12, height = 9, device = svglite::svglite, bg = "white")
    }
    message("Saved LODO per-group figure to: ", lodo_plot_path)
  }
}

# Report where the combined artifacts landed, then print the stacked table.
message("Saved combined metrics to: ", combined_metrics_path)
message("Saved run manifest to: ", manifest_path)
print(performance_metrics_all_tax_levels)
