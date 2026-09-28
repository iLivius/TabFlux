# Helpers that read config.yaml into `tabflux_config`, the list that drives the
# whole pipeline.
#
# Data flow:
#   config.yaml  ->  load_tabflux_config()  ->  tabflux_config (nested R list)
#   analysis/tabflux.qmd ("sourcing pkgs" chunk) sources this file and calls
#   load_tabflux_config(); its "settings" chunk unpacks each field into a plain
#   variable (target, normalization, ...).
#   scripts/run_multi_tax_levels.R sources the same file, loads the config once,
#   and writes one edited copy per taxonomic level for its child renders, so
#   both entry points read the YAML in exactly the same way.
#
# Done here: defaults for keys the user left out, tidying of fields YAML can
# write in more than one shape (a string vs a list), a hard error on a missing
# config file, and the Hugging Face token lookup for TabPFN v2.x runs
# (tabflux_resolve_hf_token). No validation of the config VALUES — that lives in
# the notebook's "settings" chunk, next to where each one is used.

# Built-in defaults, one entry per section of config.yaml with the same names
# and nesting. A key missing from the YAML gets the value listed here; a key
# present in the YAML replaces it (tabflux_merge_config). This is the reference
# for what each setting means.
tabflux_default_config <- function() {
  list(
    # Which learners to train: one or more of the names in the notebook's
    # `all_methods` (ranger, tabpfn, glmnet, xgboost, ...), always listed
    # explicitly. Default is TabPFN alone.
    methods = list(
      pick = c("tabpfn")
    ),
    # Where the TabPFN Python environment lives; read only when "tabpfn" is
    # among the picked methods. Empty = auto-detect: the notebook finds the
    # conda installation and builds the env path from env_name. The default
    # env_name is the environment built from conda/tabflux-tabpfn35-gpu.yml,
    # the one whose tabpfn package can load the default v3.5 weights.
    # model_version: "v3.5" (default) or "v2.5".
    # A key left out of config.yaml takes the value below, so the
    # TABPFN_ENV_NAME / TABPFN_MODEL_VERSION environment variables are read
    # only when config.yaml sets that key to "" (the notebook and the wrapper
    # fall back to the variable only for an empty value).
    # hf_token is the Hugging Face access token, needed for the v2.x weights
    # only; the 3.x weights need the one-time Prior Labs licence acceptance
    # instead (TABPFN_TOKEN when the run is non-interactive). Prefer keeping
    # the token in ~/.Renviron rather than here (tabflux_resolve_hf_token).
    runtime = list(
      tabpfn = list(
        conda_root = "",
        env_name = "tabflux-tabpfn35-gpu",
        python = "",
        model_version = "v3.5",
        hf_token = ""
      )
    ),
    # How the training runs, not what it learns. num_threads = CPU threads per
    # learner ("auto" = let the notebook pick); num_jobs = parallel R workers
    # inside one tuning or benchmark run, i.e. folds fitted at the same time
    # (the methods themselves are still tuned one after another); "auto" (and
    # the legacy "kfold") = one worker per group when dataset.group is set,
    # evaluation.inner_folds otherwise, never more than num_threads;
    # future_globals_max_gb = how much data each worker may receive; term_min =
    # wall-clock tuning cap in minutes, applied to the SVM only (every other
    # learner stops when its own tuner schedule is done); log_threshold = mlr3 logging
    # verbosity ("off" keeps the rendered report clean).
    execution = list(
      seed = 42L,
      num_threads = "auto",
      num_jobs = "auto",
      future_globals_max_gb = 2,
      term_min = 20L,
      # Rule for picking the final setting from the tuning results:
      # "one_se" (lowest logloss within one SE of the best balanced accuracy)
      # or "max_bacc" (highest balanced accuracy). See train_methods().
      tuning_selection = "one_se",
      log_threshold = "off"
    ),
    # What is being modeled. id + version name the output folder; target = the
    # metadata column with the class labels; group = the metadata column naming
    # the site / study / batch a sample comes from, so samples that share a
    # value are never split across a fold boundary (empty = plain random
    # splits); pta = optional grouping column for fairness metrics; tax_level =
    # the rank to aggregate ASVs to ("" or "asv" = no aggregation; a list of
    # ranks only works through run_multi_tax_levels.R); positive_class = the
    # class counted as "positive" in the metrics (empty = the minority class).
    dataset = list(
      id = "TabFlux",
      version = "v1.0.0",
      target = "",
      group = "",
      pta = "",
      tax_level = "",
      positive_class = ""
    ),
    input = list(
      # Three-file layout (recommended; mirrors MetaFlux output):
      #   counts_path – feature_id + one raw-count column per sample
      #   taxa_path   – feature_id, sequence (optional), rank columns and/or
      #                 a semicolon-delimited 'taxonomy' string
      #   meta_path   – sample metadata; first column = sample IDs
      counts_path = "",
      taxa_path = "",
      # Legacy single-file layout (kept working): sample x feature table, or a
      # BIOM-style feature x sample table with a trailing 'taxonomy' column.
      asv_path = "",
      meta_path = "",
      # Optional external test set (three-file layout only). When set, the
      # trained models predict these samples after the internal evaluation.
      test_counts_path = "",
      test_taxa_path = "",
      test_meta_path = "",
      # Where the training tables come from. "files" = the paths
      # above. "cfmd" = a public release of the curated Food Metagenomic Data,
      # downloaded and rewritten in the three-file layout by
      # R/tabflux_cfmd_helpers.R (settings under `cfmd`; the training paths
      # above are ignored). With cFMD, set dataset.target to "category",
      # "type", "subtype" or "country", and dataset.group to "dataset" so
      # that samples of one dataset are never split across a fold boundary.
      source = "files",
      cfmd = list(
        repo = "SegataLab/cFMD",
        ref = "v1.3.2",                 # release tag; never mix releases (taxonomy changed in v1.3.0)
        data_path = "cFMD_data",
        datasets = list(),              # empty = every dataset with a profile; or dataset folder names
        completeness_threshold = 99,    # minimum per-sample abundance sum (percent)
        min_samples_per_dataset = 10L,  # smaller datasets are dropped (a held-out fold needs samples)
        cache_dir = "input/cfmd_cache"  # downloads and the written files, per release
      ),
      # Metadata column used to break external test metrics down by group
      # (e.g. a site or study column). Empty = overall metrics only.
      test_group = ""
    ),
    # Sample/feature filtering and model-search switches, applied in the
    # notebook's "pre-process" and training chunks:
    #   min_samples_per_class – drop outcome classes rarer than this
    #   samples_to_keep       – random fraction of samples kept per class
    #                           (1 = all; < 1 only for quick test runs)
    #   feat_to_keep          – fraction of most-abundant features kept (1 = all)
    #   smote                 – class balancing of the training rows:
    #                           "smote" | "blsmote" | "adasyn" (oversample the
    #                           minority class; binary targets, a multi-class
    #                           target gets "balance" instead) | "balance"
    #                           (resample every class to the same size, any
    #                           target) | "none" (off) | "" (automatic).
    #                           The notebook decides in "Prepare Modeling
    #                           Inputs": balancing applies only when the
    #                           majority/minority ratio exceeds
    #                           smote_imbalance_threshold AND every class has
    #                           at least min_samples_per_class samples; ""
    #                           then picks smote on two classes, balance on
    #                           more. With evaluation.prior_correction TRUE
    #                           (the default) "" stays off, and a named method
    #                           stops the run whenever balancing would apply:
    #                           both correct for the same imbalance.
    #   filtering             – unsupervised feature filter: "minimal" |
    #                           "varcor" | "infogain" | TRUE | FALSE
    #   selecting             – run wrapper feature selection (RFE/ensemble)?
    #   fast_tuning           – cheaper tuning schedules
    #                           (get_tuner_for_method): successive halving on
    #                           row subsamples instead of a full grid for
    #                           glmnet/kknn/svm, Hyperband with 1 repetition
    #                           instead of 3 for ranger, 40 instead of 80
    #                           random-search settings for xgboost/mlp; tabpfn
    #                           is a one-point grid either way. The notebook's
    #                           "task" chunk turns it off below 500 samples or
    #                           25 features, where the shortcuts save nothing.
    #   learner_fallback      – run each fit in a separate R process; a fit that
    #                           errors is replaced by a majority-class stand-in
    #                           and a warning counts the failures (TabPFN stops
    #                           instead; so does any learner whose every
    #                           tuning evaluation fails)
    preprocessing = list(
      min_samples_per_class = 5L,
      samples_to_keep = 1,
      feat_to_keep = 1,
      smote = "",
      smote_imbalance_threshold = 1.5,
      filtering = "minimal",
      selecting = TRUE,
      fast_tuning = TRUE,
      learner_fallback = FALSE,
      # Per-sample depth normalization applied before the modeling task is
      # built: "none" | "tss" | "tss_log" | "tss_clr". TSS = total-sum
      # scaling: divide each sample's counts by that sample's total, i.e.
      # relative abundance; the other two take logs of that. See
      # normalize_abundance() in R/tabflux_data_helpers.R for details.
      normalization = "tss_log",
      # Constant added to relative abundances before taking logs (proportion
      # scale). Fixed, not data-derived, so the transform is identical for
      # training data and any future sample.
      pseudocount = 1e-6,
      # Probability calibration for binary tasks: "platt" fits a two-parameter
      # correction on the out-of-fold benchmark probabilities (no test data
      # involved) and reports external results at the corrected threshold as
      # well as the raw one; "none" switches this off.
      calibration = "platt"
    ),
    # Where run folders and reports are written. dir: "" = the project root,
    # the usual case; set it when code and outputs must live apart, e.g. a
    # container writing to a mounted volume or a read-only checkout on a
    # cluster. Relative paths resolve against the project root.
    # run_date: date prefix of the output folder, "" = today.
    # run_multi_tax_levels.R sets it once per batch, so every taxonomic level
    # gets its own folder under one date prefix
    # (<date>_<ds>_<ver>_target_<t>_tax_<level>_saved_learners) and only the
    # stacked metrics tables (<date>_<ds>_<ver>_multi_tax_results/) are shared.
    output = list(
      run_date = "",
      dir = "",
      # Title and author printed at the top of the HTML report. "" = the title
      # is "Predicting <target> from <tax_level>-level profiles", with
      # "<dataset.id> · run <dataset.version>" as the subtitle, and no author
      # line is shown.
      report_title = "",
      report_author = ""
    ),
    # Feature importance of the best model (the "which taxa drive the
    # prediction" step, after evaluation).
    importance = list(
      # "shap" | "perm" | "none". "none" skips the feature-importance chunk
      # entirely (no explainer is built, no model retraining happens).
      method = "shap",
      # Multi-level runs only: taxonomic levels that get feature importance.
      # Empty = all levels. E.g. ["genus"] computes SHAP at genus only, which
      # avoids paying the (very slow) TabPFN SHAP cost at every level.
      levels = list(),
      # SHAP cost knobs. Cost is rows x features x classes x sample_size, so
      # the row cap is what keeps the step bounded on a large training set.
      #   shap_sample_size     - permutation draws per Shapley value
      #   shap_max_rows        - training rows explained, ANY learner
      #   tabpfn_*             - tighter values for TabPFN, which re-runs the
      #                          whole model for every query
      # Without the row cap every learner would explain the whole training
      # set, and this one step would take longer than the rest of the run.
      shap_sample_size = 100L,
      shap_max_rows = 300L,
      tabpfn_shap_sample_size = 10L,
      tabpfn_shap_max_rows = 20L
    ),
    # How the reported performance is estimated. The terms are defined in
    # R/tabflux_evaluation_helpers.R; old `split` and "holdout" settings are
    # translated in load_tabflux_config. Two independent decisions: reserve an
    # internal test set or not, and how to resample what is left.
    #   test_split    – an INTERNAL test set carved out of the input data
    #                   before anything learns from it: 0 = none (the outer
    #                   folds are the estimate, the right choice below ~1000
    #                   samples), 0.2 = reserve 20 % (whole groups when
    #                   dataset.group is set, stratified by class otherwise).
    #                   Scored by the final models in the Prediction section,
    #                   like an external test set.
    #   outer         – how the training data is resampled: "cv",
    #                   "repeated_cv", "subsampling" (repeated random splits),
    #                   "loo" (one fold per sample), "lodo" (one fold per group
    #                   in dataset.group)
    #   outer_folds / outer_repeats – parameters of the above (subsampling
    #                   tests 1/outer_folds of the samples per split)
    #   nested        – TRUE: feature selection and tuning repeated inside
    #                   every outer fold (honest); FALSE: done once on all
    #                   training data, folds only scored (fast, mildly
    #                   optimistic)
    #   inner         – resampling for the tuning inside a fold: "auto"
    #                   (rules in choose_tuning_resampling), "cv",
    #                   "repeated_cv", "loo"
    # With dataset.group set, the test split and every outer strategy work on
    # whole groups.
    evaluation = list(
      test_split = 0,
      outer = "cv",
      outer_folds = 10L,
      outer_repeats = 3L,
      nested = TRUE,
      inner = "auto",
      inner_folds = 5L,
      inner_repeats = 3L,
      # Predicted category = largest probability divided by the class's
      # training frequency, for every learner: the decision rule that maximises
      # balanced accuracy. Probabilities are unchanged. FALSE = largest
      # probability (serves plain accuracy on unbalanced classes).
      prior_correction = TRUE
    ),
    # Ordination plots (PCA / t-SNE) only; no effect on the models. Large
    # tables are downsampled to downsample_size samples above
    # downsample_threshold, and features present in fewer than
    # prevalence_threshold of the samples are left out of the plot.
    visualization = list(
      downsample_threshold = 10000L,
      downsample_size = 1000L,
      prevalence_threshold = 0.05
    )
  )
}

# Merge the user's (usually partial) config into the default config.
#
# Input:  defaults  – the full list from tabflux_default_config()
#         overrides – what yaml::read_yaml() returned for config.yaml
# Output: one complete list shaped like the defaults, with every key the user
#         set replacing the default. Used only by load_tabflux_config().
#
# The function calls itself on each nested section, so a YAML that sets only
# `execution: {seed: 7}` keeps term_min, num_jobs and the rest of that block
# instead of wiping it. A user value that is not itself a section (a string,
# number, or vector of strings) replaces the default wholesale.
tabflux_merge_config <- function(defaults, overrides) {
  if (is.null(overrides)) {
    return(defaults)
  }

  for (nm in names(overrides)) {
    default_value <- defaults[[nm]]
    override_value <- overrides[[nm]]
    if (is.null(override_value)) {
      # A key left blank in the YAML ("asv_path:" with no value) parses as
      # NULL. Assigning NULL into a list DELETES the element, so the built-in
      # default would silently vanish and later code would crash far from the
      # config. Blank key = keep the default.
      next
    }
    if (is.list(default_value) && is.list(override_value)) {
      defaults[[nm]] <- tabflux_merge_config(default_value, override_value)
    } else {
      defaults[[nm]] <- override_value
    }
  }

  defaults
}

# Turn `methods.pick` into a plain character vector of learner names.
#
# YAML writes the same setting as `pick: tabpfn` (one string), `pick: [ranger,
# tabpfn]` (a vector) or a bulleted list (an R list), but the notebook matches
# the names against `all_methods` and needs a flat character vector. Missing/NA
# entries are dropped.
# Input:  whatever the merged config holds under methods$pick.
# Output: character vector, possibly empty; written back into the config by
#         load_tabflux_config() and read as `pick_method` in the notebook.
tabflux_normalize_pick_method <- function(x) {
  if (is.null(x)) {
    return(character())
  }

  if (is.list(x)) {
    x <- unlist(x, recursive = TRUE, use.names = FALSE)
  }

  x <- as.character(x)
  x[!is.na(x)]
}

# Return the first candidate that is not NULL, NA, or blank.
#
# Expresses a precedence chain in one call; the caller fixes the order. The
# notebook passes config value, then environment variable, then either an
# auto-detected value (TabPFN conda root, python path) or the `default`
# argument (env name, model version);
# tabflux_resolve_hf_token() puts the environment variables first and the config
# last. Candidates are checked left to right, only the first element of each is
# read, and the result is a single string.
tabflux_first_non_empty <- function(..., default = "") {
  candidates <- list(...)
  for (value in candidates) {
    if (is.null(value) || length(value) == 0) {
      next
    }
    value <- as.character(value[[1]])
    if (!is.na(value) && nzchar(trimws(value))) {
      return(value)
    }
  }
  default
}

# Load a `.Renviron` file into the session if it exists; do nothing otherwise.
#
# `.Renviron` is a plain KEY=value file R reads at startup, the usual place to
# keep secrets like the Hugging Face token out of the config file and out of
# git. At startup R reads only one such file: the one in the startup working
# directory if present, else ~/.Renviron. Quarto starts R in analysis/, so a
# project-root .Renviron would never be picked up — hence reading both
# explicitly here. Returns TRUE/FALSE invisibly for "was a file read"; the only
# caller, tabflux_resolve_hf_token(), ignores it.
tabflux_read_renviron_if_exists <- function(path) {
  if (is.null(path) || length(path) == 0) {
    return(invisible(FALSE))
  }

  path <- trimws(path.expand(as.character(path[[1]])))
  if (!nzchar(path) || !file.exists(path)) {
    return(invisible(FALSE))
  }

  readRenviron(path)
  invisible(TRUE)
}

# Find the Hugging Face access token and make it visible to Python.
#
# Which token a TabPFN download needs depends on the model generation:
#   v2.x weights come from Hugging Face, and TabFlux requires an HF token
#   for them (HF_TOKEN);
#   3.x weights need no HF token: their download is unlocked by a one-time
#   Prior Labs licence acceptance (TABPFN_TOKEN when the run is
#   non-interactive), which this function does not handle.
# The Python process reticulate starts inherits R's environment variables, so
# exporting the token here is enough for the Python side to authenticate.
#
# Looked for in this order, first non-empty wins:
#   1. environment variables already set (HF_TOKEN and its two older aliases),
#      after reading ~/.Renviron and <project>/.Renviron;
#   2. runtime.tabpfn.hf_token in config.yaml — discouraged, the config is
#      meant to be shared.
# Exported under all three names because huggingface_hub versions differ in
# which one they read.
#
# Input:  tabpfn_cfg  – tabflux_config$runtime$tabpfn; project_dir – WORKDIR.
# Output: the token string, or "" when none was found. Called once in the
#         notebook's "sourcing pkgs" chunk, only when TabPFN is picked; on ""
#         the notebook stops with a clear message for v2.x weights, and only
#         prints a note for 3.x weights.
tabflux_resolve_hf_token <- function(tabpfn_cfg = list(), project_dir = getwd()) {
  project_renviron <- file.path(project_dir, ".Renviron")
  tabflux_read_renviron_if_exists("~/.Renviron")
  tabflux_read_renviron_if_exists(project_renviron)

  token <- tabflux_first_non_empty(
    Sys.getenv("HF_TOKEN", unset = ""),
    Sys.getenv("HUGGINGFACE_HUB_TOKEN", unset = ""),
    Sys.getenv("HUGGING_FACE_HUB_TOKEN", unset = ""),
    tabpfn_cfg$hf_token,
    default = ""
  )

  if (!nzchar(token)) {
    return("")
  }

  Sys.setenv(
    HF_TOKEN = token,
    HUGGINGFACE_HUB_TOKEN = token,
    HUGGING_FACE_HUB_TOKEN = token
  )
  token
}

# Load the YAML config, merge it with the defaults, and normalize fields that
# can appear in more than one shape. The config entry point for both the
# notebook and the multi-level wrapper.
#
# Input:  path to config.yaml. The notebook takes it from the TABFLUX_CONFIG
#         environment variable (default "config.yaml", resolved against the
#         project root); run_multi_tax_levels.R takes it from its command line
#         and then points TABFLUX_CONFIG at a per-level temporary copy for each
#         child render.
# Output: the complete nested list `tabflux_config`, unpacked field by field in
#         the notebook's "settings" chunk.
#
# A missing config file is a hard error, not a fallback: falling back to the
# built-in defaults would send the run off with the default method list
# (TabPFN), perhaps on a machine without TabPFN, and the crash would come
# nowhere near the real mistake, a config path that did not resolve.
load_tabflux_config <- function(path = "config.yaml") {
  config <- tabflux_default_config()

  if (!file.exists(path)) {
    stop(
      "Config file not found at '", normalizePath(path, mustWork = FALSE), "'. ",
      "Set the TABFLUX_CONFIG environment variable to the config's full path, ",
      "or place config.yaml in the project root."
    )
  }

  user_config <- yaml::read_yaml(path)
  config <- tabflux_merge_config(config, user_config)

  config$methods$pick <- tabflux_normalize_pick_method(config$methods$pick)

  # dataset.lodo was renamed dataset.group in v1.5.0. The old name said what the column
  # was FOR (leave-one-dataset-out) rather than what it IS (the grouping column),
  # which misled: naming it never selected that design - evaluation.outer does -
  # and every outer strategy honours it. Old configs keep working.
  if (!is.null(user_config$dataset$lodo)) {
    if (!nzchar(as.character(config$dataset$group %||% ""))) {
      config$dataset$group <- user_config$dataset$lodo
    }
    config$dataset$lodo <- NULL
    message(
      "dataset.lodo is now dataset.group (it names the grouping column; ",
      "evaluation.outer chooses the fold design). Rename it in config.yaml to silence this."
    )
  }

  # Legacy configs (pre-1.2) describe the evaluation with a `split` block
  # instead of `evaluation`. Translate them so old runs keep meaning the same:
  #   dataset.group set    -> outer "lodo", test_split = lodo_test_group_ratio
  #                           (whole groups reserved as the internal test set)
  #   dataset.group empty  -> outer "cv", test_split = 1 - train_ratio
  # nested = FALSE everywhere because that is what those versions computed.
  if (is.null(user_config$evaluation) && !is.null(user_config$split)) {
    group_col <- as.character(config$dataset$group %||% "")
    group_ratio <- as.numeric(user_config$split$lodo_test_group_ratio %||% 0.2)
    train_ratio <- as.numeric(user_config$split$train_ratio %||% 0.8)
    if (nzchar(group_col)) {
      config$evaluation$outer <- "lodo"
      config$evaluation$test_split <- max(0, group_ratio)
    } else {
      config$evaluation$outer <- "cv"
      config$evaluation$test_split <- 1 - train_ratio
    }
    config$evaluation$nested <- FALSE
    message(sprintf(
      "Legacy 'split' settings translated to evaluation: outer = %s, test_split = %s, nested = FALSE. Add an 'evaluation' block to config.yaml to silence this.",
      config$evaluation$outer, config$evaluation$test_split
    ))
  }

  # v1.2.x configs used outer = "holdout" (one train/test split as the only
  # outer fold) with holdout_ratio = the training share. Since v1.3.0 the same
  # design is written as test_split = 1 - holdout_ratio plus an outer resampling
  # of the training part (lodo when dataset.group is set, else cv): same reserved
  # test set, plus a resampled estimate with its spread.
  if (identical(tolower(as.character(config$evaluation$outer %||% "")), "holdout")) {
    holdout_ratio <- as.numeric(user_config$evaluation$holdout_ratio %||% 0.8)
    group_col <- as.character(config$dataset$group %||% "")
    config$evaluation$test_split <- 1 - holdout_ratio
    config$evaluation$outer <- if (nzchar(group_col)) "lodo" else "cv"
    message(sprintf(
      "evaluation.outer = 'holdout' is no longer a strategy: translated to test_split = %s, outer = %s. Update config.yaml to silence this.",
      config$evaluation$test_split, config$evaluation$outer
    ))
  }

  # v1.4.0: the tuning folds are evaluation.inner_folds / inner_repeats only.
  # A config still carrying execution.kfold / repeats gets them copied over
  # (unless the evaluation block sets its own); num_jobs "kfold" is translated
  # to "auto" whether or not those legacy keys are present.
  if (!is.null(user_config$execution$kfold) || !is.null(user_config$execution$repeats)) {
    if (is.null(user_config$evaluation$inner_folds) && !is.null(user_config$execution$kfold)) {
      config$evaluation$inner_folds <- as.integer(user_config$execution$kfold)
    }
    if (is.null(user_config$evaluation$inner_repeats) && !is.null(user_config$execution$repeats)) {
      config$evaluation$inner_repeats <- as.integer(user_config$execution$repeats)
    }
    message("execution.kfold / repeats are no longer read (v1.4.0): the tuning folds come from evaluation.inner_folds / inner_repeats. Remove them from config.yaml to silence this.")
  }
  if (identical(tolower(as.character(config$execution$num_jobs %||% "")), "kfold")) {
    config$execution$num_jobs <- "auto"
  }
  # v1.4.0: the top-level `smote` block is gone; its threshold lives under
  # preprocessing, and the SMOTE guard uses preprocessing.min_samples_per_class.
  if (!is.null(user_config$smote)) {
    if (!is.null(user_config$smote$imbalance_threshold) && is.null(user_config$preprocessing$smote_imbalance_threshold)) {
      config$preprocessing$smote_imbalance_threshold <- as.numeric(user_config$smote$imbalance_threshold)
    }
    config$smote <- NULL
    message("The top-level 'smote' block is no longer read (v1.4.0): use preprocessing.smote_imbalance_threshold and preprocessing.min_samples_per_class.")
  }

  config
}

# NULL-coalescing helper: return `x` unless it is NULL or empty, else `y`.
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
