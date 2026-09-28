# Helpers for turning predictions into the metric tables used in the notebook.
#
# Where this sits in analysis/tabflux.qmd:
#   - Benchmark chunk: the outer-evaluation results table (one prediction per
#     learner x outer fold on task_train) -> collect_benchmark_scores(),
#     aggregate_benchmark_scores();
#   - internal-test and external-test chunks: single Prediction objects ->
#     score_prediction_metrics();
#   - label_measure_name() / recode_method_labels() rename columns and rows for
#     the printed tables, the CSV exports (metrics/*.csv) and the plots.
# mlr3 objects in, plain vectors and data.frames out, so the notebook never
# calls the mlr3 scoring API directly.
#
# Terms used below:
#   Prediction - mlr3 object holding, per test sample, the true class (truth),
#                the predicted class (response) and the class probabilities.
#   Measure    - mlr3 object turning a Prediction into one number, e.g.
#                "classif.bacc"; msr("id") builds one from its id.
#   PTA        - Protected Target Attribute: the metadata column (e.g. site)
#                across which we check the model is not much better for some
#                groups than for others ("fairness").

# Translate raw mlr3 metric ids into labels that read well in tables and plots.
# Input: column names such as "classif.bacc", from score_prediction_metrics().
# Output: the same vector with plain names; unknown ids pass through unchanged.
# Applied with rename_with() on bench_df, fold_metrics, pred_df and the
# external-test tables, so these are the headers in the exported CSVs and the
# axis names in the plots.
label_measure_name <- function(x) {
  dplyr::case_when(
    x == "classif.acc" ~ "accuracy",
    x == "classif.bacc" ~ "balanced accuracy",
    x == "classif.precision" ~ "precision",
    x == "classif.recall" ~ "recall",
    x == "classif.specificity" ~ "specificity",
    x == "classif.fbeta" ~ "f1",
    x == "classif.auc" ~ "auc",
    x == "classif.prauc" ~ "pr auc",
    x == "classif.logloss" ~ "logloss",
    x == "fairness.fpr" ~ "fairness fpr gap",
    x == "fairness.tpr" ~ "fairness tpr gap",
    x == "fairness.bacc" ~ "fairness balanced accuracy gap",
    TRUE ~ x
  )
}

# Turn internal learner ids back into the method names shown in the notebook.
# Input: learner_id values from the fold-score tables and the *_pred_df /
# external tables. configure_final_learner() gives each tuned GraphLearner the
# short method key ("ranger", "tabpfn", ...) as its id. Matching is str_detect,
# not equality, so a longer pipeline id like "scale.classif.ranger" still maps.
# Output: display names; anything unrecognised becomes "Other" instead of
# failing. Keep these in sync with `all_methods` in the notebook.
recode_method_labels <- function(x) {
  dplyr::case_when(
    stringr::str_detect(x, "glmnet") ~ "GLM elastic net",
    stringr::str_detect(x, "kknn") ~ "K-Nearest Neighbor",
    stringr::str_detect(x, "mlp") ~ "Multi-layer Perceptron",
    stringr::str_detect(x, "ranger") ~ "Random Forest",
    stringr::str_detect(x, "svm") ~ "Support Vector Machine",
    stringr::str_detect(x, "tabpfn") ~ "TabPFN",
    stringr::str_detect(x, "xgboost") ~ "XGBoost",
    TRUE ~ "Other"
  )
}

# Fairness gaps across PTA groups, binary targets only. Each value is the
# spread (best group minus worst) of one group-level rate.
#
# Why: when samples come from several sources (studies, sites, batches), a
# model can look fine on average while being right mostly for one group and
# near random on another. Samples are split by PTA group (the
# metadata column named by `pta` in the config, e.g. site), then the
# true-positive rate, false-positive rate and balanced accuracy are computed
# per group; a large gap means the model generalises unevenly.
#
# Inputs:
#   pred           - one mlr3 Prediction: a benchmark fold, or the whole
#                    internal test set.
#   task           - the task the prediction was made on. Only used if its
#                    backend still carries a "pta" column; the task chunk
#                    strips it, so in this notebook pta_lookup does the work.
#   positive_class - the label counted as positive; "" means a non-binary
#                    target, so all gaps come back NA.
#   pta_lookup     - named character vector row_id -> PTA group, built in the
#                    task chunk from tab$pta. pred$row_ids are those same row
#                    ids, so a sample's group is recovered without the task
#                    knowing PTA.
# Output: named numeric vector (fairness.fpr, fairness.tpr, fairness.bacc); 0
# means all groups fare the same. NA without PTA info, or with fewer than two
# groups in this prediction (e.g. a LODO fold holding out one group). A group
# with no samples of one class has an undefined rate: gap_fun() drops it and
# returns NA if fewer than two groups are left.
# Consumed by score_prediction_metrics(), which appends it to the base scores.
compute_fairness_gaps <- function(pred, task, positive_class, pta_lookup = NULL) {
  gap_names <- c("fairness.fpr", "fairness.tpr", "fairness.bacc")
  out <- stats::setNames(rep(NA_real_, length(gap_names)), gap_names)

  if (!nzchar(positive_class)) {
    return(out)
  }

  pred_dt <- data.table::as.data.table(pred)
  if (!nrow(pred_dt)) {
    return(out)
  }

  pta_vals <- NULL
  if (!is.null(task) && "pta" %in% task$backend$colnames) {
    pta_vals <- task$backend$data(rows = pred$row_ids, cols = "pta")[["pta"]]
  } else if (!is.null(pta_lookup)) {
    row_key <- as.character(pred$row_ids)
    pta_vals <- unname(pta_lookup[row_key])
  }
  if (is.null(pta_vals) || length(pta_vals) != nrow(pred_dt)) {
    return(out)
  }

  # Attach the group label to each predicted sample and drop samples with no
  # group; at least two groups must remain, otherwise there is nothing to gap.
  pred_dt[, pta := as.character(pta_vals)]
  pred_dt <- pred_dt[!is.na(pta) & nzchar(pta)]
  if (!nrow(pred_dt) || length(unique(pred_dt$pta)) < 2) {
    return(out)
  }

  pred_dt[, truth_chr := as.character(truth)]
  pred_dt[, response_chr := as.character(response)]
  pred_dt[, is_pos_truth := truth_chr == positive_class]
  pred_dt[, is_pos_pred := response_chr == positive_class]

  # Confusion-matrix counts per group (data.table: `.( )` builds the summary
  # columns, `by = pta` gives one row per group), then the per-group rates.
  # A rate is NA when its denominator is 0, e.g. TPR in a group with no
  # positive samples.
  group_stats <- pred_dt[, .(
    tp = sum(is_pos_truth & is_pos_pred),
    fn = sum(is_pos_truth & !is_pos_pred),
    fp = sum(!is_pos_truth & is_pos_pred),
    tn = sum(!is_pos_truth & !is_pos_pred)
  ), by = pta]

  group_stats[, tpr := ifelse(tp + fn > 0, tp / (tp + fn), NA_real_)]
  group_stats[, fpr := ifelse(fp + tn > 0, fp / (fp + tn), NA_real_)]
  group_stats[, tnr := ifelse(fp + tn > 0, tn / (fp + tn), NA_real_)]
  group_stats[, bacc := ifelse(!is.na(tpr) & !is.na(tnr), (tpr + tnr) / 2, NA_real_)]

  # Gap = best group minus worst group, ignoring groups whose rate is NA;
  # needs at least two usable groups.
  gap_fun <- function(x) {
    x <- x[!is.na(x)]
    if (length(x) < 2) {
      return(NA_real_)
    }
    max(x) - min(x)
  }

  out["fairness.fpr"] <- gap_fun(group_stats$fpr)
  out["fairness.tpr"] <- gap_fun(group_stats$tpr)
  out["fairness.bacc"] <- gap_fun(group_stats$bacc)
  out
}

# Accept either ready-made Measure objects or character ids, so everything
# downstream sees one type. The notebook mostly passes Measure objects
# (bmr_measures, built with msr() at the end of the "pre-process" chunk), some
# calls pass ids like "classif.acc". Output: list of Measure objects.
normalize_mlr_measures <- function(measures) {
  lapply(measures, function(measure) {
    if (is.character(measure)) {
      return(msr(measure))
    }
    measure
  })
}

# Score one prediction and return a named numeric vector. A metric that fails
# to compute gives NA instead of stopping the run.
#
# Input: an mlr3 Prediction (a benchmark fold, the internal or the external test
# set) and the measures to apply (bmr_measures: accuracy, balanced accuracy,
# logloss and, for binary targets, precision, recall, specificity, F1, AUC,
# PR-AUC).
# Output: named numeric vector, one entry per measure id.
#
# NAs are expected in some folds: AUC is undefined when the held-out set holds
# a single class (a LODO fold from a one-class group), and probability metrics
# fail when the fallback learner - the stand-in that ignores all taxa and
# predicts the majority class after a crash - produced no probabilities.
#
# Binary measures take the FIRST factor level of `truth` as positive. The task
# chunk sets task$positive <- positive_class, which reorders the levels, so
# nothing is passed here; without it the wrong class would be scored.
# Consumed by score_prediction_metrics(), and by the internal-test chunk for a
# quick accuracy per method.
score_base_metrics <- function(pred, measures) {
  measures <- normalize_mlr_measures(measures)
  score_names <- vapply(measures, function(m) m$id, character(1))
  out <- stats::setNames(rep(NA_real_, length(score_names)), score_names)

  pred_dt <- tryCatch(
    data.table::as.data.table(pred),
    error = function(e) NULL
  )
  if (is.null(pred_dt) || !nrow(pred_dt)) {
    return(out)
  }

  # pred$score() normally returns a named number; some mlr3 versions return a
  # one-row data.frame, hence the unwrapping before picking the value by
  # measure id (or the first value if the name does not match).
  for (measure in measures) {
    out[[measure$id]] <- tryCatch({
      value <- pred$score(measure)
      if (is.data.frame(value)) {
        value <- unlist(value[1, , drop = TRUE], use.names = TRUE)
      }
      if (!is.null(value[[measure$id]])) {
        as.numeric(value[[measure$id]])
      } else {
        as.numeric(value[[1]])
      }
    }, error = function(e) NA_real_)
  }

  out
}

# Base metrics plus, when asked, the fairness gaps. Every evaluation goes
# through here - benchmark folds (via collect_benchmark_scores), the internal
# test split (<method>_pred_df, gathered into pred_df) and the external test set
# (external_metrics / external_group_metrics) - so the train-side and test-side
# tables carry identical columns.
# Inputs: see score_base_metrics() and compute_fairness_gaps().
# fairness_active comes from the "pre-process" chunk, TRUE only for a binary
# target with a PTA column; the external-test chunk leaves it FALSE, those
# samples have no PTA mapping.
# Output: one-row data.frame, one column per metric id plus the three fairness.*
# columns when active. A data.frame rather than a vector so callers can
# bind_rows()/bind_cols() it straight into their tables.
score_prediction_metrics <- function(pred,
                                     measures,
                                     task = NULL,
                                     positive_class = "",
                                     fairness_active = FALSE,
                                     pta_lookup = NULL) {
  measures <- normalize_mlr_measures(measures)
  base_scores <- score_base_metrics(pred, measures)
  if (fairness_active) {
    fairness_scores <- compute_fairness_gaps(pred, task, positive_class, pta_lookup = pta_lookup)
    base_scores <- c(base_scores, fairness_scores)
  }
  as.data.frame(as.list(base_scores))
}

# Score every resampling iteration of the outer evaluation.
#
# Input: bmr, outer_results from run_outer_evaluation() in the Benchmark chunk
# - every learner x every fold of outer_resampling on task_train; under LODO
# (leave-one-dataset-out) each fold is one held-out study. One row per learner
# x fold, with a `prediction` column whose cells hold that fold's whole
# Prediction object.
# Output: one row per learner x fold with learner_id, task_id, resampling_id,
# iteration, then one column per metric. Feeds the accuracy boxplot (one
# measure), fold_metrics.csv and the per-study LODO table (all measures plus
# group_lookup), and aggregate_benchmark_scores() below.
#
# group_lookup (optional): named character vector, task row id (as character)
# -> grouping label, e.g. the LODO study of each sample. When supplied, each
# row gains:
#   heldout_group – the group(s) tested in that fold, i.e. under LODO the one
#                   held-out study. This is what makes per-group LODO metrics
#                   possible: mlr3 shuffles fold order, so the iteration number
#                   alone does not say which group a fold tested.
#   n_test        – number of test samples in that fold.
collect_benchmark_scores <- function(bmr,
                                     measures,
                                     task,
                                     positive_class,
                                     fairness_active = FALSE,
                                     pta_lookup = NULL,
                                     group_lookup = NULL) {
  # `bmr` is the results table returned by run_outer_evaluation(): one row
  # per learner x fold with the columns learner_id, task_id, resampling_id,
  # iteration, prediction and resampling (the same columns
  # as.data.table(<BenchmarkResult>) gives).
  pred_dt <- data.table::as.data.table(bmr)
  if (!nrow(pred_dt)) {
    return(data.frame())
  }

  purrr::map_dfr(seq_len(nrow(pred_dt)), function(i) {
    scores <- score_prediction_metrics(
      pred = pred_dt$prediction[[i]],
      measures = measures,
      task = task,
      positive_class = positive_class,
      fairness_active = fairness_active,
      pta_lookup = pta_lookup
    )
    row <- tibble::tibble(
      learner_id = pred_dt$learner_id[[i]],
      task_id = pred_dt$task_id[[i]],
      resampling_id = pred_dt$resampling_id[[i]],
      iteration = pred_dt$iteration[[i]]
    )
    if (!is.null(group_lookup)) {
      # The resampling object still holds this benchmark's fold assignment, so
      # ask it which rows this fold tested, then map those row ids to group
      # labels.
      test_rows <- pred_dt$resampling[[i]]$test_set(pred_dt$iteration[[i]])
      fold_groups <- unique(stats::na.omit(group_lookup[as.character(test_rows)]))
      row$heldout_group <- paste(sort(fold_groups), collapse = ";")
      row$n_test <- length(test_rows)
    }
    row %>% dplyr::bind_cols(scores)
  })
}

# Average the fold-wise scores so each learner ends up with one summary row.
# Input: the same bmr and measures as collect_benchmark_scores().
# Output: one row per learner_id, the mean of each metric over folds (NA folds
# ignored; a metric NA in every fold stays NA rather than NaN). This becomes
# bench_df: the headline cross-validated / LODO table that is printed, exported
# and used to pick the best model (highest balanced accuracy, then lowest
# logloss) for the prediction overview and the SHAP chunk. Averaging hides the
# fold-to-fold spread - fold_metrics.csv keeps that.
aggregate_benchmark_scores <- function(bmr,
                                       measures,
                                       task,
                                       positive_class,
                                       fairness_active = FALSE,
                                       pta_lookup = NULL) {
  score_rows <- collect_benchmark_scores(
    bmr = bmr,
    measures = measures,
    task = task,
    positive_class = positive_class,
    fairness_active = fairness_active,
    pta_lookup = pta_lookup
  )
  if (!nrow(score_rows)) {
    return(data.frame())
  }

  metric_cols <- setdiff(
    names(score_rows),
    c("learner_id", "task_id", "resampling_id", "iteration",
      "heldout_group", "n_test")   # bookkeeping columns, never averaged
  )

  score_rows %>%
    dplyr::group_by(learner_id) %>%
    dplyr::summarise(
      dplyr::across(
        dplyr::all_of(metric_cols),
        ~ if (all(is.na(.x))) NA_real_ else mean(.x, na.rm = TRUE)
      ),
      .groups = "drop"
    )
}
