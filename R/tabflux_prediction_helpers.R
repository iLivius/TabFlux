# Helpers for summarising a "prediction set".
#
# A prediction set is one mlr3 prediction per method on samples the model never
# learned from. The notebook has three, summarised the same way so their tables
# and plots line up column by column:
#   out-of-fold – the Benchmark chunk's outer folds pooled: every training
#                 sample predicted by a model that did not see it (repeated
#                 designs: once per repeat that tested it);
#   internal    – the reserved test split (evaluation.test_split > 0),
#                 predicted by the final models (Prediction chunk);
#   external    – the independent test set (input.test_*), predicted by the
#                 final models (External Test chunk).
# For each: a metric table in the benchmark table's shape, a per-sample table,
# a per-class recall table, a bootstrap interval per metric, and a per-group
# table when the samples carry a group.
#
# Also here: the fold spread behind the benchmark table, ROC and calibration
# curve points, and the two plots every prediction set gets (right/wrong per
# class, train-vs-test dumbbell).
#
# Sourced by analysis/tabflux.qmd. Scoring goes through
# R/tabflux_scoring_helpers.R (score_prediction_metrics, score_base_metrics,
# label_measure_name, recode_method_labels), so a number here means the same
# as in the benchmark table.


# ── Pooling the outer folds ───────────────────────────────────────────────────

# Pool one method's outer-fold predictions into a single object.
# Input:  outer_results – run_outer_evaluation()'s table (one row per learner x
#                         fold, `prediction` holding that fold's mlr3
#                         prediction of its test part);
#         learner_id    – the method to pool ("ranger", "tabpfn", ...).
# Output: one PredictionClassif over all folds' test parts. Under cv / lodo /
#         loo each sample appears once, under repeated_cv / subsampling once
#         per repeat that tested it. Duplicates are kept: they are different
#         predictions from different models.
pool_outer_predictions <- function(outer_results, learner_id) {
  rows <- which(outer_results$learner_id == learner_id)
  if (!length(rows)) stop("No outer-fold predictions for learner '", learner_id, "'.")
  preds <- outer_results$prediction[rows]
  if (length(preds) == 1) return(preds[[1]])
  do.call(c, c(preds, list(keep_duplicates = TRUE)))
}


# ── Per-sample table ──────────────────────────────────────────────────────────

# Flatten one prediction into a plain table, one row per predicted sample.
# Input:  pred          – an mlr3 PredictionClassif;
#         method        – the method key, written into every row;
#         sample_lookup – data.frame(row_id, Sample) from the task chunk, to
#                         restore sample names (NULL = leave NA);
#         group_lookup  – named vector row id -> group (site), the task
#                         chunk's group_lookup (NULL = no group).
# Output: data.frame with method, row_id, Sample, group, truth, response, one
#         prob.<class> column per class, and match (TRUE = right). Written to
#         test_predictions.csv / oof_predictions.csv; read by the
#         right/wrong-per-class plot.
prediction_sample_table <- function(pred, method, sample_lookup = NULL, group_lookup = NULL) {
  dt <- as.data.frame(data.table::as.data.table(pred), check.names = FALSE)
  out <- data.frame(
    method = method,
    row_id = dt$row_ids,
    Sample = if (is.null(sample_lookup)) NA_character_ else
      sample_lookup$Sample[match(dt$row_ids, sample_lookup$row_id)],
    group = if (is.null(group_lookup)) NA_character_ else
      unname(group_lookup[as.character(dt$row_ids)]),
    truth = dt$truth,
    response = dt$response,
    stringsAsFactors = FALSE
  )
  prob_cols <- grep("^prob\\.", names(dt), value = TRUE)
  for (col in prob_cols) out[[col]] <- dt[[col]]
  out$match <- out$truth == out$response
  out
}


# ── Bootstrap interval for a single test set ──────────────────────────────────

# Bootstrap percentile interval for one test set. A test set is scored once, so
# it has no fold-to-fold spread: resample its samples with replacement,
# rescore, take the 2.5 / 97.5 percentiles. This is uncertainty about the
# ESTIMATE on this test set, not about how the model would do on another group.
# Input:  pred     – an mlr3 PredictionClassif (any prediction set);
#         measures – the notebook's bmr_measures (ids or Measure objects);
#         n_boot   – resamples (1000 is plenty for a 95 % interval);
#         seed     – for repeatability.
# Output: data.frame(metric, estimate, ci_low, ci_high, n_boot_valid): the
#         estimate on the full set and its interval. n_boot_valid counts the
#         resamples where the metric was defined – one that drew a single
#         class has no AUC and is skipped.
bootstrap_prediction_metrics <- function(pred, measures, n_boot = 1000L, seed = 42L) {
  measures <- normalize_mlr_measures(measures)
  point <- score_base_metrics(pred, measures)
  dt <- data.table::as.data.table(pred)
  n <- nrow(dt)
  prob_cols <- grep("^prob\\.", names(dt), value = TRUE)
  prob_mat <- as.matrix(dt[, prob_cols, with = FALSE])
  colnames(prob_mat) <- sub("^prob\\.", "", prob_cols)

  set.seed(as.integer(seed))
  boot <- matrix(NA_real_, nrow = n_boot, ncol = length(point),
                 dimnames = list(NULL, names(point)))
  for (b in seq_len(n_boot)) {
    idx <- sample.int(n, n, replace = TRUE)
    if (length(unique(dt$truth[idx])) < 2) next   # one class only: AUC & co undefined
    pred_b <- mlr3::PredictionClassif$new(
      row_ids = seq_len(n),
      truth = dt$truth[idx],
      response = dt$response[idx],
      prob = prob_mat[idx, , drop = FALSE]
    )
    boot[b, ] <- score_base_metrics(pred_b, measures)
  }
  ci <- apply(boot, 2, stats::quantile, probs = c(0.025, 0.975), na.rm = TRUE)
  data.frame(
    metric = names(point),
    estimate = unname(point),
    ci_low = unname(ci[1, ]),
    ci_high = unname(ci[2, ]),
    n_boot_valid = unname(colSums(!is.na(boot))),
    stringsAsFactors = FALSE
  )
}


# ── One summary for any prediction set ────────────────────────────────────────

# Everything the notebook reports about a prediction set, for every method.
# Input:  preds          – named list, method key -> PredictionClassif;
#         measures       – bmr_measures;
#         sample_lookup, group_lookup – as in prediction_sample_table();
#         n_boot, seed   – bootstrap settings (n_boot = 0 skips the interval);
#         task, positive_class, fairness_active, pta_lookup – passed to
#                          score_prediction_metrics() for the fairness gaps;
#                          NA unless the rows resolve to at least two PTA
#                          groups.
# Output: list(
#   metrics  – one row per method: method, learner_id, n, then metrics under
#              readable names ("balanced accuracy", ...), in the benchmark
#              table's shape;
#   ci       – long: method, learner_id, metric, estimate, ci_low, ci_high
#              (NULL when n_boot = 0);
#   samples  – the per-sample tables of all methods stacked;
#   by_group – one row per method x group with n, the counterpart of the LODO
#              table (NULL without groups);
#   by_class – one row per true class with each method's recall and the
#              classes it is confused with, from per_class_recall_table()
#              on the stacked per-sample tables).
summarise_prediction_set <- function(preds, measures, sample_lookup = NULL, group_lookup = NULL,
                                     n_boot = 1000L, seed = 42L, task = NULL,
                                     positive_class = "", fairness_active = FALSE,
                                     pta_lookup = NULL) {
  measures <- normalize_mlr_measures(measures)
  metric_rows <- list(); ci_rows <- list(); sample_rows <- list(); group_rows <- list()

  for (method in names(preds)) {
    pred <- preds[[method]]
    n_pred <- length(pred$row_ids)

    scores <- score_prediction_metrics(
      pred, measures = measures, task = task, positive_class = positive_class,
      fairness_active = fairness_active, pta_lookup = pta_lookup
    )
    metric_rows[[method]] <- cbind(data.frame(learner_id = method, n = n_pred), scores)

    if (n_boot > 0) {
      ci <- bootstrap_prediction_metrics(pred, measures, n_boot = n_boot, seed = seed)
      ci$learner_id <- method
      ci_rows[[method]] <- ci
    }

    samples <- prediction_sample_table(pred, method, sample_lookup, group_lookup)
    sample_rows[[method]] <- samples

    # Per-group scores: fewer than two samples cannot support a metric; a group
    # with one class only gets accuracy-type numbers but no AUC (NA).
    if (!is.null(group_lookup)) {
      groups <- samples$group
      for (g in sort(unique(stats::na.omit(groups)))) {
        in_g <- which(groups == g)
        if (length(in_g) < 2) next
        pred_g <- mlr3::PredictionClassif$new(
          row_ids = seq_along(in_g),
          truth = samples$truth[in_g],
          response = samples$response[in_g],
          prob = as.matrix(samples[in_g, grep("^prob\\.", names(samples)), drop = FALSE]) |>
            (\(m) { colnames(m) <- sub("^prob\\.", "", colnames(m)); m })()
        )
        group_rows[[paste(method, g)]] <- cbind(
          data.frame(learner_id = method, group = g, n = length(in_g)),
          as.data.frame(as.list(score_base_metrics(pred_g, measures)))
        )
      }
    }
  }

  tidy <- function(df) {
    if (!length(df)) return(NULL)
    df <- dplyr::bind_rows(df)
    df$method <- recode_method_labels(df$learner_id)
    df <- dplyr::rename_with(df, label_measure_name)
    df <- dplyr::mutate(df, dplyr::across(dplyr::where(is.numeric), ~ round(.x, 4)))
    dplyr::relocate(df, method, learner_id)
  }

  ci_df <- if (length(ci_rows)) dplyr::bind_rows(ci_rows) else NULL
  if (!is.null(ci_df)) {
    ci_df$method <- recode_method_labels(ci_df$learner_id)
    ci_df$metric <- label_measure_name(ci_df$metric)
    ci_df <- dplyr::relocate(ci_df, method, learner_id, metric)
  }

  all_samples <- dplyr::bind_rows(sample_rows)
  list(
    metrics = tidy(metric_rows),
    ci = ci_df,
    samples = all_samples,
    by_group = tidy(group_rows),
    by_class = per_class_recall_table(all_samples)
  )
}


# ── Per-class recall ──────────────────────────────────────────────────────────

# Per-class recall, one column per method, plus what each class is mistaken for.
#
# Why this table exists: balanced accuracy IS the mean of the per-class recalls,
# so the single number hides which classes a model actually gets. On an
# unbalanced problem two learners can sit within a point of each other on plain
# accuracy while one of them never gets the smallest class right - it has
# learned to answer with the majority class, which is nearly free accuracy. This
# table shows that directly, and the confusion column says where the misses
# went, which is usually the biologically interesting part (a fermented food
# called by its unfermented neighbour, say).
#
# Input:  samples          - a per-sample prediction table with columns method,
#                            truth and response: summarise_prediction_set()$samples,
#                            or the External Test chunk's table. Rows without a
#                            truth label (prediction-only samples, controls) are
#                            dropped, so the external set can be passed whole.
#         reference_method - the method the `confused_with` column describes.
#                            Default: the method with the highest mean recall,
#                            i.e. the best on this set by balanced accuracy.
#         n_confusions     - how many wrong classes to name per row.
# Output: data.frame(class, n, one recall column per method named as the tables
#         label it, confused_with), ordered by the reference method's recall so
#         the classes it fails on are last, then a final "mean (= balanced
#         accuracy)" row.
#
#         That mean is computed on the POOLED predictions of this set. The
#         benchmark table averages the per-fold balanced accuracies instead, so
#         the two differ when the folds hold unequal numbers of samples; both
#         are right, they answer slightly different questions.
#
#         Written to metrics/per_class_recall_<set>.csv by the notebook.
per_class_recall_table <- function(samples, reference_method = NULL, n_confusions = 2L) {
  needed <- c("method", "truth", "response")
  if (is.null(samples) || !nrow(samples) || !all(needed %in% names(samples))) return(NULL)

  # Prediction-only samples (no label) cannot contribute to a recall.
  keep <- !is.na(samples$truth) & !is.na(samples$response)
  samples <- samples[keep, , drop = FALSE]
  if (!nrow(samples)) return(NULL)

  truth <- as.character(samples$truth)
  response <- as.character(samples$response)
  method <- as.character(samples$method)
  methods <- unique(method)
  classes <- sort(unique(truth))

  # Recall = of the samples that truly belong to this class, the fraction the
  # method put in it. One row per class, one column per method.
  recall <- matrix(NA_real_, nrow = length(classes), ncol = length(methods),
                   dimnames = list(classes, methods))
  for (m in methods) {
    for (cl in classes) {
      rows <- method == m & truth == cl
      if (any(rows)) recall[cl, m] <- mean(response[rows] == cl)
    }
  }

  # Class sizes are a property of the data, so take them from one method.
  n_class <- vapply(classes, function(cl) sum(method == methods[1] & truth == cl), integer(1))

  # The confusion column needs one method to describe; default to the strongest,
  # since "where does the best model still go wrong" is the useful question.
  if (is.null(reference_method) || !reference_method %in% methods) {
    reference_method <- methods[which.max(colMeans(recall, na.rm = TRUE))]
  }

  confused <- vapply(classes, function(cl) {
    rows <- method == reference_method & truth == cl & response != cl
    if (!any(rows)) return("-")
    wrong <- sort(table(response[rows]), decreasing = TRUE)
    paste(names(wrong)[seq_len(min(n_confusions, length(wrong)))], collapse = ", ")
  }, character(1))

  out <- data.frame(class = classes, n = as.integer(n_class),
                    stringsAsFactors = FALSE, check.names = FALSE)
  for (m in methods) out[[recode_method_labels(m)]] <- round(recall[classes, m], 3)
  out$confused_with <- unname(confused)

  # Best-handled classes first, so the ones the model loses are at the bottom.
  out <- out[order(-recall[classes, reference_method]), , drop = FALSE]
  rownames(out) <- NULL

  mean_row <- out[1, , drop = FALSE]
  mean_row$class <- "mean (= balanced accuracy)"
  mean_row$n <- sum(out$n)
  for (m in methods) mean_row[[recode_method_labels(m)]] <- round(mean(recall[, m], na.rm = TRUE), 3)
  mean_row$confused_with <- paste("confusions shown for", recode_method_labels(reference_method))
  out <- rbind(out, mean_row)
  rownames(out) <- NULL
  out
}


# ── Spread across the outer folds ─────────────────────────────────────────────

# Mean and SD of every metric across the outer folds, per method: the spread
# behind the benchmark table. The SD is fold-to-fold spread (group to group
# under LODO), reported as such and not as a standard error – folds share
# training data, so cross-validation has no unbiased variance estimate
# (Bengio & Grandvalet 2004).
# Input:  fold_metrics – the Benchmark chunk's labelled per-fold table
#                        (method, iteration, metric columns with readable
#                        names, plus bookkeeping columns).
# Output: long data.frame(method, metric, mean, sd, n_folds).
fold_metric_spread <- function(fold_metrics) {
  bookkeeping <- c("method", "learner_id", "task_id", "resampling_id", "iteration",
                   "n_test", "class_counts", "heldout_group", "heldout_dataset")
  metric_cols <- setdiff(names(fold_metrics)[vapply(fold_metrics, is.numeric, logical(1))], bookkeeping)
  long <- tidyr::pivot_longer(fold_metrics[, c("method", metric_cols)], -method,
                              names_to = "metric", values_to = "value")
  dplyr::summarise(
    dplyr::group_by(long, method, metric),
    mean = mean(value, na.rm = TRUE),
    sd = stats::sd(value, na.rm = TRUE),
    n_folds = sum(!is.na(value)),
    .groups = "drop"
  )
}


# ── Curves ────────────────────────────────────────────────────────────────────

# ROC curve points of one prediction (binary tasks).
# Input:  pred, positive_class. Output: data.frame(fpr, tpr) from (0,0) to
# (1,1), samples ranked by P(positive). Tied probabilities keep their row
# order, so a block of ties is drawn as a staircase, not the diagonal chord.
roc_curve_points <- function(pred, positive_class) {
  dt <- data.table::as.data.table(pred)
  p <- dt[[paste0("prob.", positive_class)]]
  y <- dt$truth == positive_class
  ord <- order(p, decreasing = TRUE)
  y <- y[ord]
  n_pos <- sum(y); n_neg <- sum(!y)
  if (n_pos == 0 || n_neg == 0) return(data.frame(fpr = c(0, 1), tpr = c(0, 1)))
  data.frame(fpr = c(0, cumsum(!y) / n_neg), tpr = c(0, cumsum(y) / n_pos))
}

# ROC points per outer fold plus the pooled folds, for one method.
# Output: data.frame(fold, fpr, tpr) with fold = "pooled" for the pooled set;
# the notebook draws the folds in grey behind the pooled curve.
roc_curves_by_fold <- function(outer_results, learner_id, positive_class) {
  rows <- which(outer_results$learner_id == learner_id)
  per_fold <- lapply(rows, function(i) {
    pts <- roc_curve_points(outer_results$prediction[[i]], positive_class)
    pts$fold <- as.character(outer_results$iteration[[i]])
    pts
  })
  pooled <- roc_curve_points(pool_outer_predictions(outer_results, learner_id), positive_class)
  pooled$fold <- "pooled"
  out <- dplyr::bind_rows(c(per_fold, list(pooled)))
  out[, c("fold", "fpr", "tpr")]
}

# Calibration (reliability) curve points: predicted probability binned, and
# the observed fraction of positives in each bin. A well-calibrated model
# lies on the diagonal; the Platt correction in the Benchmark chunk is a fit
# to exactly this relationship.
# Input:  pred, positive_class, bins (equal-width on [0, 1]).
# Output: data.frame(bin, p_mean, obs_frac, n) for the non-empty bins.
calibration_curve_points <- function(pred, positive_class, bins = 10L) {
  dt <- data.table::as.data.table(pred)
  p <- dt[[paste0("prob.", positive_class)]]
  y <- as.numeric(dt$truth == positive_class)
  edges <- seq(0, 1, length.out = bins + 1)
  bin <- pmin(pmax(findInterval(p, edges, rightmost.closed = TRUE), 1L), bins)
  out <- dplyr::summarise(
    dplyr::group_by(data.frame(bin = bin, p = p, y = y), bin),
    p_mean = mean(p), obs_frac = mean(y), n = dplyr::n(), .groups = "drop"
  )
  as.data.frame(out)
}


# ── Plots ─────────────────────────────────────────────────────────────────────

# Right / wrong per true class, one facet row per method. Works for any
# prediction set.
# Input:  samples – the stacked per-sample table (summarise_prediction_set()$samples,
#                   columns method, truth, match); class_levels – class order;
#         title.
# Output: a ggplot; bars are percent of each true class's samples.
plot_prediction_by_class <- function(samples, class_levels, title) {
  method_label <- recode_method_labels(samples$method)
  plot_df <- data.frame(
    method = method_label,
    truth = factor(as.character(samples$truth), levels = class_levels),
    match = factor(ifelse(samples$match, "TRUE", "FALSE"), levels = c("TRUE", "FALSE"))
  )
  plot_df <- dplyr::count(plot_df, method, truth, match, name = "n")
  plot_df <- dplyr::mutate(dplyr::group_by(plot_df, method, truth),
                           pct = 100 * n / sum(n), label = paste0(round(pct, 1), "%"))
  plot_df <- dplyr::ungroup(plot_df)

  ggplot2::ggplot(plot_df, ggplot2::aes(x = truth, y = pct, fill = match)) +
    ggplot2::geom_col(width = 0.9) +
    ggplot2::geom_text(ggplot2::aes(label = label), position = ggplot2::position_stack(vjust = 0.5),
                       color = "white", size = 3) +
    ggplot2::facet_grid(method ~ ., scales = "free_x", space = "free_x") +
    ggplot2::scale_fill_manual(values = c("TRUE" = "dodgerblue3", "FALSE" = "red3"), name = "Correct") +
    ggplot2::scale_y_continuous(labels = function(x) paste0(x, "%"),
                                expand = ggplot2::expansion(mult = c(0, 0.05))) +
    ggplot2::labs(x = "Class", y = "Percent of predictions", title = title) +
    ggplot2::theme_bw() +
    ggplot2::theme(strip.text.y = ggplot2::element_text(angle = 0),
                   axis.text.x = ggplot2::element_text(angle = 45, hjust = 1),
                   panel.grid.major.x = ggplot2::element_blank())
}

# Train-vs-test dumbbells with error bars.
# Two dots per metric and method: the benchmark mean over the outer folds (bar:
# +/- 1 SD across folds) and the test-set value (bar: bootstrap 95 % interval).
# A short segment means the test value agrees with the resampling estimate, not
# that either is good; a long one with the test dot to the left is optimism, or
# a shift between the training and the test population.
# Input:  bench_df    – benchmark table (method, learner_id, metrics);
#         fold_spread – fold_metric_spread() output (method, metric, sd);
#         test_df     – a prediction-set metric table of the same shape;
#         test_ci     – its ci table (method, metric, ci_low, ci_high), or NULL;
#         test_label  – "Internal test", "External test", ...
# Output: list(by_method, by_metric): two ggplots, one panel per method and
#         one panel per metric.
plot_dumbbell <- function(bench_df, fold_spread, test_df, test_ci = NULL, test_label = "Test") {
  id_cols <- c("method", "learner_id", "n")
  metric_cols <- setdiff(intersect(names(bench_df), names(test_df)), id_cols)

  bench_long <- tidyr::pivot_longer(bench_df[, c("method", metric_cols)], -method,
                                    names_to = "metric", values_to = "train")
  test_long <- tidyr::pivot_longer(test_df[, c("method", metric_cols)], -method,
                                   names_to = "metric", values_to = "test")
  df <- dplyr::inner_join(bench_long, test_long, by = c("method", "metric"))
  df <- dplyr::left_join(df, fold_spread[, c("method", "metric", "sd")], by = c("method", "metric"))
  if (!is.null(test_ci)) {
    df <- dplyr::left_join(df, test_ci[, c("method", "metric", "ci_low", "ci_high")],
                           by = c("method", "metric"))
  } else {
    df$ci_low <- NA_real_; df$ci_high <- NA_real_
  }
  df$metric <- factor(df$metric, levels = rev(sort(unique(df$metric))))
  x_min <- min(c(df$train - df$sd, df$test, df$ci_low), na.rm = TRUE)

  base <- function(p, y_var) {
    p +
      ggplot2::geom_segment(ggplot2::aes(x = train - sd, xend = train + sd, yend = .data[[y_var]]),
                            colour = "green3", alpha = 0.35, linewidth = 2.5, na.rm = TRUE) +
      ggplot2::geom_segment(ggplot2::aes(x = ci_low, xend = ci_high, yend = .data[[y_var]]),
                            colour = "magenta3", alpha = 0.35, linewidth = 2.5, na.rm = TRUE) +
      ggplot2::geom_segment(ggplot2::aes(x = train, xend = test, yend = .data[[y_var]]),
                            colour = "gray50", linewidth = 1, alpha = 0.8) +
      ggplot2::geom_point(ggplot2::aes(x = train, colour = "Benchmark (outer folds)"), size = 3) +
      ggplot2::geom_point(ggplot2::aes(x = test, colour = test_label), size = 3) +
      ggplot2::scale_colour_manual(values = stats::setNames(c("green3", "magenta3"),
                                                            c("Benchmark (outer folds)", test_label))) +
      ggplot2::scale_x_continuous(limits = c(min(0, x_min), 1)) +
      ggplot2::labs(x = "Score (bars: +/- 1 SD across folds; bootstrap 95 % interval)",
                    colour = "Prediction set") +
      ggplot2::theme_minimal(base_size = 14) +
      ggplot2::theme(plot.title = ggplot2::element_text(face = "bold", hjust = 0.5),
                     legend.position = "bottom")
  }
  by_method <- base(ggplot2::ggplot(df, ggplot2::aes(y = metric)), "metric") +
    ggplot2::facet_wrap(~method, ncol = 1) +
    ggplot2::labs(title = paste("Benchmark vs", tolower(test_label), "by method"), y = "Metric")
  by_metric <- base(ggplot2::ggplot(df, ggplot2::aes(y = method)), "method") +
    ggplot2::facet_wrap(~metric, scales = "free_x") +
    ggplot2::labs(title = paste("Benchmark vs", tolower(test_label), "by metric"), y = "Method") +
    ggplot2::theme(panel.border = ggplot2::element_rect(colour = "grey70", fill = NA, linewidth = 0.6))
  list(by_method = by_method, by_metric = by_metric)
}
