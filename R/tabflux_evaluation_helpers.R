# Helpers for the outer evaluation loop: how the test folds are
# made, and the loop that scores every learner on every fold.
#
# Vocabulary, shared with the `evaluation` block of config.yaml:
#   outer resampling – the folds whose scores are REPORTED; a fold's test part
#                      is never used for learning.
#   inner resampling – resampling inside a fold's training part, used to tune
#                      hyperparameters (see train_methods()).
#   nested           – TRUE: selection and tuning repeated inside every outer
#                      fold, on its training part only; the honest estimate
#                      (Varma & Simon 2006). FALSE: both run once on all
#                      training data, folds only refit and score those settings
#                      — fast, mildly optimistic.
#   test split       – samples reserved before any of the above
#                      (evaluation.test_split). Not an outer fold: outer folds
#                      come from the training part only, and these samples are
#                      scored once by the final models in the Prediction
#                      section, like an external test set.
#   outer = "lodo"   – leave-one-out over the groups in dataset.group.
#
# Every design runs through the same loop, so the report looks the same.
# Sourced by analysis/tabflux.qmd: the "task" chunk (build_test_split,
# build_outer_resampling, describe_outer_folds) and the "benchmarking" chunk
# (run_outer_evaluation). train_methods() and select_features() are in the
# training and selection helpers.


# Reserve an internal test set from the full task (config evaluation.test_split).
#
# Input:  task       – the full modelling task, roles already set. A "group"
#                      role (dataset.group) keeps whole groups on one side of
#                      the split; without it the target carries a "stratum"
#                      role and the class ratio is kept equal in both parts.
#                      Either/or: mlr3 cannot combine grouping and stratifying.
#         test_split – fraction of samples to reserve, 0 = none. 0.5 or more is
#                      refused: nobody means to reserve as much test data as
#                      training data.
#         seed       – repeatable split; offset so it does not reuse the
#                      tuning draws.
# Output: NULL if test_split is 0, else list(train_ids, test_ids) of task row
#         ids. The task chunk filters task_train / task_test from them;
#         everything that learns sees train_ids only.
build_test_split <- function(task, test_split, seed) {
  test_split <- as.numeric(test_split)
  if (is.na(test_split) || test_split < 0 || test_split >= 0.5) {
    stop("evaluation.test_split must be 0 (no internal test set) or a fraction below 0.5 (got ",
         test_split, ").")
  }
  if (test_split == 0) return(NULL)
  set.seed(as.integer(seed) + 2000L)
  split <- rsmp("holdout", ratio = 1 - test_split)
  split$instantiate(task)
  list(train_ids = split$train_set(1), test_ids = split$test_set(1))
}


# Build and instantiate the outer resampling from the config.
#
# Input:  outer          – "subsampling" | "cv" | "repeated_cv" | "loo" | "lodo"
#         outer_folds, outer_repeats – from the config. subsampling draws
#                          outer_repeats random splits, each testing
#                          1/outer_folds of the samples (10 folds -> 10 %),
#                          so one fold count serves every strategy.
#         min_count      – size of the rarest class (get_training_task_stats);
#                          caps the folds so each can hold both classes.
#         task           – the TRAINING task (task_train: all of it, or what is
#                          left after build_test_split). With a group role set
#                          (dataset.group) every strategy works on WHOLE groups:
#                          subsampling, cv and repeated_cv put whole groups in
#                          a fold, loo = one group per fold.
# Output: an instantiated mlr3 Resampling; $train_set(i) / $test_set(i) give
#         each fold's row ids. Instantiated once, so every learner sees the
#         same folds.
build_outer_resampling <- function(outer, outer_folds, outer_repeats, min_count, task) {
  outer <- tolower(outer)
  has_groups <- length(task$col_roles$group) > 0
  n_groups <- if (has_groups) length(unique(task$groups$group)) else NA_integer_

  # Fold cap: never more folds than the rarest class can populate (plain
  # samples) or than there are groups (grouped task); never fewer than 2.
  cap_folds <- function(k) {
    limit <- if (has_groups) n_groups else as.integer(min_count)
    max(2L, min(as.integer(k), limit))
  }

  resampling <- switch(
    outer,
    subsampling = rsmp("subsampling", repeats = as.integer(outer_repeats),
                       ratio = 1 - 1 / cap_folds(outer_folds)),
    cv = rsmp("cv", folds = cap_folds(outer_folds)),
    repeated_cv = rsmp("repeated_cv", folds = cap_folds(outer_folds), repeats = as.integer(outer_repeats)),
    loo = rsmp("loo"),
    lodo = {
      if (!has_groups) {
        stop("evaluation.outer = 'lodo' needs dataset.group set to the grouping column (study, site, ...).")
      }
      rsmp("loo")   # leave-one-out over the groups = one fold per group
    },
    stop("evaluation.outer must be one of: subsampling, cv, repeated_cv, loo, lodo (got '",
         outer, "').")
  )
  if (outer %in% c("cv", "repeated_cv") && cap_folds(outer_folds) < as.integer(outer_folds)) {
    message(sprintf("Outer folds reduced from %d to %d (rarest class / number of groups).",
                    as.integer(outer_folds), cap_folds(outer_folds)))
  }

  resampling$instantiate(task)
  resampling
}

# Build the inner (tuning) resampling when the config names one explicitly;
# "auto" is handled in train_methods() via choose_tuning_resampling(). Folds
# are capped by the rarest class, or by the number of groups when grouped.
# Grouped tasks stay grouped: mlr3 keeps whole groups in the inner splits too.
build_inner_resampling <- function(inner, inner_folds, inner_repeats, min_count, task) {
  inner <- tolower(inner)
  has_groups <- length(task$col_roles$group) > 0
  limit <- if (has_groups) length(unique(task$groups$group)) else as.integer(min_count)
  folds <- max(2L, min(as.integer(inner_folds), limit))
  switch(
    inner,
    cv = rsmp("cv", folds = folds),
    repeated_cv = rsmp("repeated_cv", folds = folds, repeats = as.integer(inner_repeats)),
    loo = rsmp("loo"),
    stop("evaluation.inner must be one of: auto, cv, repeated_cv, loo (got '", inner, "').")
  )
}

# One row per outer fold: how many samples train and test it, and which
# group(s) the test part holds (under LODO: the held-out group). Printed in
# the task chunk so the design is visible before anything runs.
describe_outer_folds <- function(resampling, group_lookup = NULL) {
  rows <- lapply(seq_len(resampling$iters), function(i) {
    test_ids <- resampling$test_set(i)
    heldout <- if (is.null(group_lookup)) NA_character_ else
      paste(sort(unique(stats::na.omit(group_lookup[as.character(test_ids)]))), collapse = ";")
    data.frame(
      iteration = i,
      n_train = length(resampling$train_set(i)),
      n_test = length(test_ids),
      heldout_group = heldout,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# The outer evaluation loop.
#
# For every outer fold:
#   nested = TRUE : select features on the fold's training part, tune every
#                   learner there (train_methods, own inner resampling), refit
#                   the chosen settings on the whole training part, predict the
#                   fold's test part.
#   nested = FALSE: refit learners_best (tuned once on all training data) on
#                   the fold's training part, keeping only the taxa already
#                   selected, then predict its test part. Written out rather
#                   than left to mlr3's benchmark(), so both modes share one
#                   code path.
# Each fold writes its tuning files and predictions to
# <save_dir>/outer_fold_<i>/. A rerun skips folds whose predictions are on
# disk, so a crashed overnight run resumes where it stopped.
#
# Input:  task            – the FULL task (all candidate taxa), the one the
#                           outer resampling was instantiated on
#         outer_resampling – from build_outer_resampling()
#         methods         – named list of methods (config methods.pick)
#         nested, selecting – config flags
#         learners_best   – tuned learners (nested = FALSE only)
#         selected_feats  – taxa kept by the final selection (nested = FALSE
#                           only; NULL = all taxa)
#         train_args      – fully named list of the arguments train_methods()
#                           needs beyond task/save_dir/assign_env (learners,
#                           preprocessing_pipe, preproc_params, tab, ...)
#         fs_args         – list(seed, num_threads, prior_correction) for
#                           select_features(); seed also seeds every fold
#         save_dir        – run folder; per-fold subfolders are created in it
# Output: list(
#   results   – data.table, one row per learner x fold: learner_id, task_id,
#               resampling_id, iteration, prediction (list column of mlr3
#               Prediction objects), resampling (list column). Same columns as
#               as.data.table(<BenchmarkResult>), so the scoring helpers and
#               the benchmark chunk consume it unchanged.
#   fold_info – data.frame: iteration, n_train, n_test, n_features,
#               classes_untrainable (test classes absent from training, ";"-joined)
# )
run_outer_evaluation <- function(task, outer_resampling, methods, nested, selecting,
                                 learners_best = NULL, selected_feats = NULL,
                                 train_args, fs_args, save_dir,
                                 prior_correction = FALSE) {
  results <- list()
  fold_info <- list()

  for (i in seq_len(outer_resampling$iters)) {
    fold_dir <- file.path(save_dir, sprintf("outer_fold_%02d", i))
    dir.create(fold_dir, recursive = TRUE, showWarnings = FALSE)
    cat(sprintf("\n=== Outer fold %d of %d ===\n", i, outer_resampling$iters))

    # Seed every fold from its index. Selection and tuning draw random
    # numbers (RFE splits, random forests, Hyperband settings). Without this,
    # fold i would carry on from wherever fold i-1 left the generator, so
    # editing the tuning code would change which taxa later folds pick, and
    # with them the reported scores. Seeded here, a fold's result depends only
    # on the data and its index. The offset keeps these draws apart from the
    # notebook's other seeded steps.
    set.seed(as.integer(fs_args$seed) + 1000L * i,
             kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")

    fold_train <- task$clone(deep = TRUE)$filter(outer_resampling$train_set(i))
    fold_test  <- task$clone(deep = TRUE)$filter(outer_resampling$test_set(i))

    # A class that is in this fold's test part but not in its training part can
    # never be predicted here: every such sample is scored wrong and its
    # near-zero probability blows up the log-loss. It happens when a class lives
    # in one or two groups and those groups are held out together. Say so
    # loudly and record it, so a collapsed fold is explained rather than
    # puzzled over.
    truth_col <- fold_train$target_names
    train_classes <- unique(as.character(fold_train$data(cols = truth_col)[[1]]))
    test_classes  <- unique(as.character(fold_test$data(cols = truth_col)[[1]]))
    untrainable <- setdiff(test_classes, train_classes)
    if (length(untrainable) > 0) {
      warning(sprintf("Outer fold %d: class(es) %s occur in the held-out part but not in the training part; every such sample will be scored wrong. Add groups that carry them, or raise preprocessing.min_samples_per_class.",
                      i, paste(untrainable, collapse = ", ")), call. = FALSE)
    }

    # Resume: if every learner's prediction for this fold is on disk, reuse it.
    pred_files <- file.path(fold_dir, paste0("predictions_", names(methods), ".rds"))
    if (all(file.exists(pred_files))) {
      cat("  predictions found on disk, fold skipped\n")
      preds <- lapply(pred_files, readRDS)
      names(preds) <- names(methods)
      n_features_used <- NA_integer_
    } else if (nested) {
      # Feature selection on the fold's training part only.
      if (selecting) {
        fs_result <- select_features(
          task_train = fold_train, task_test = fold_test,
          seed = fs_args$seed, num_threads = fs_args$num_threads,
          out_dir = fold_dir,
          prior_correction = isTRUE(fs_args$prior_correction)
        )
        fold_train <- fs_result$task_train
        fold_test <- fs_result$task_test
      }
      n_features_used <- length(fold_train$feature_names)

      # Tuning on the fold's training part; the tuned learners are refit on
      # it by train_methods() itself. A private environment keeps the fold's
      # <method>_tuned_learner objects away from the final model's globals.
      stats <- get_training_task_stats(fold_train)
      # call_by_name(), not do.call(): see the helper at the end of this file.
      fold_learners <- call_by_name(train_methods, c(
        list(task_train = fold_train, save_dir = fold_dir, assign_env = new.env(),
             min_count = stats$min_count, num_feat = stats$num_feat, num_obs = stats$num_obs),
        train_args
      ))
      preds <- lapply(names(methods), function(m) fold_learners[[m]]$predict(fold_test))
      names(preds) <- names(methods)
    } else {
      # Fixed settings: reduce both parts to the selected taxa, refit, predict.
      if (!is.null(selected_feats)) {
        fold_train$select(selected_feats)
        fold_test$select(selected_feats)
      }
      n_features_used <- length(fold_train$feature_names)
      preds <- lapply(names(methods), function(m) {
        learner <- learners_best[[m]]$clone(deep = TRUE)
        learner$train(fold_train)
        learner$predict(fold_test)
      })
      names(preds) <- names(methods)
    }

    # The decision rule the scores are computed with: each prediction's category is
    # the largest probability divided by the class's frequency in THIS fold's
    # training part (apply_prior_correction(), training helpers). Idempotent, so a
    # prediction resumed from disk gets the same rule as a fresh one.
    if (isTRUE(prior_correction)) {
      train_truth <- task$truth(outer_resampling$train_set(i))
      preds <- lapply(preds, apply_prior_correction, train_truth = train_truth)
    }

    for (m in names(methods)) {
      saveRDS(preds[[m]], file.path(fold_dir, paste0("predictions_", m, ".rds")))
      results[[length(results) + 1]] <- data.table::data.table(
        learner_id = m,
        task_id = task$id,
        resampling_id = outer_resampling$id,
        iteration = i,
        prediction = list(preds[[m]]),
        resampling = list(outer_resampling)
      )
    }
    fold_info[[i]] <- data.frame(
      iteration = i, n_train = fold_train$nrow, n_test = fold_test$nrow,
      n_features = n_features_used,
      classes_untrainable = paste(untrainable, collapse = ";"),   # "" when every test class was seen in training
      stringsAsFactors = FALSE
    )
  }

  list(
    results = data.table::rbindlist(results),
    fold_info = do.call(rbind, fold_info)
  )
}


# Call a function with a list of named arguments, like do.call(), but without
# copying the argument VALUES into the recorded call.
#
# Why: do.call(f, list(task = big_task)) records the call
# `f(task = <the whole task object>)`, and R keeps that call (sys.call(),
# tracebacks). train_methods() then starts its parallel workers and the future
# package serialises and hashes the calling context, that copy included. On a
# fold of a few thousand samples that copy passes R's 2 GB limit for a single
# vector and the run dies with "long vectors not supported yet", while the
# same call written by hand is fine. Calling by NAME from an environment
# records only the names.
#
# Input:  fun  - the function to call
#         args - a fully named list of its arguments
# Output: whatever fun returns.
call_by_name <- function(fun, args) {
  if (is.null(names(args)) || any(!nzchar(names(args)))) {
    stop("call_by_name(): every argument must be named.")
  }
  arg_env <- list2env(args, parent = parent.frame())
  the_call <- as.call(c(list(fun), lapply(names(args), as.name)))
  names(the_call) <- c("", names(args))
  eval(the_call, envir = arg_env)
}
