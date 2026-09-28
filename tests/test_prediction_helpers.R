# Tests for R/tabflux_prediction_helpers.R — plain script, no framework.
# Run from the repository root inside the tabflux-r environment:
#   Rscript tests/test_prediction_helpers.R
# Checks, on a toy grouped task with a deterministic learner:
#   1. pooling the outer folds gives one prediction per sample (cv/lodo) and
#      keeps repeats (repeated_cv);
#   2. the per-sample table carries names, groups and a correct match flag;
#   3. bootstrap intervals contain the point estimate and have the right shape;
#   4. summarise_prediction_set() returns benchmark-shaped metrics, a ci table,
#      per-group rows with n, and consistent sample counts;
#   5. fold_metric_spread(), ROC and calibration points, and both plots.
suppressMessages({
  library(mlr3); library(mlr3learners); library(mlr3pipelines); library(data.table); library(dplyr); library(tidyr)
})
lgr::get_logger("mlr3")$set_threshold("off")
source(file.path("R", "tabflux_scoring_helpers.R"))
source(file.path("R", "tabflux_evaluation_helpers.R"))
source(file.path("R", "tabflux_prediction_helpers.R"))
ok <- function(label, cond) { stopifnot(cond); cat("PASS:", label, "\n") }

# ── toy data: 4 sites, binary target with signal ─────────────────────────────
set.seed(3)
n_per <- c(siteA = 30, siteB = 24, siteC = 18, siteD = 12)
dt <- data.table(
  x1 = rnorm(sum(n_per)), x2 = rnorm(sum(n_per)),
  target = factor(sample(c("case", "control"), sum(n_per), TRUE), levels = c("case", "control")),
  lodo = factor(rep(names(n_per), times = n_per))
)
dt$x1 <- dt$x1 + ifelse(dt$target == "case", 1.5, 0)
backend <- as_data_backend(dt, primary_key = seq_len(nrow(dt)))
task <- as_task_classif(backend, target = "target", id = "toy")
task$set_col_roles("lodo", "group"); task$col_roles$feature <- setdiff(task$col_roles$feature, "lodo")
task$positive <- "case"
sample_lookup <- data.frame(row_id = seq_len(nrow(dt)), Sample = sprintf("s%03d", seq_len(nrow(dt))))
group_lookup <- setNames(as.character(dt$lodo), as.character(seq_len(nrow(dt))))
measures <- c("classif.acc", "classif.bacc", "classif.auc", "classif.logloss")

# outer results as run_outer_evaluation() produces them (nested = FALSE path)
learner <- lrn("classif.kknn", predict_type = "prob", k = 7)
make_results <- function(resampling) {
  resampling$instantiate(task)
  rows <- lapply(seq_len(resampling$iters), function(i) {
    l <- learner$clone(deep = TRUE)$train(task$clone(deep = TRUE)$filter(resampling$train_set(i)))
    data.table(learner_id = "kknn", task_id = "toy", resampling_id = resampling$id, iteration = i,
               prediction = list(l$predict(task$clone(deep = TRUE)$filter(resampling$test_set(i)))),
               resampling = list(resampling))   # the loop keeps it for the group lookup
  })
  rbindlist(rows)
}
res_lodo <- make_results(rsmp("loo"))
res_rep <- make_results(rsmp("repeated_cv", folds = 2, repeats = 3))

# ── 1. pooling ───────────────────────────────────────────────────────────────
pooled <- pool_outer_predictions(res_lodo, "kknn")
ok("pooled lodo prediction covers every sample once",
   inherits(pooled, "PredictionClassif") && setequal(pooled$row_ids, task$row_ids) && !anyDuplicated(pooled$row_ids))
pooled_rep <- pool_outer_predictions(res_rep, "kknn")
ok("pooled repeated_cv keeps one prediction per repeat", length(pooled_rep$row_ids) == 3 * task$nrow)
ok("unknown learner refused", inherits(try(pool_outer_predictions(res_lodo, "nope"), silent = TRUE), "try-error"))

# ── 2. per-sample table ──────────────────────────────────────────────────────
tab <- prediction_sample_table(pooled, "kknn", sample_lookup, group_lookup)
ok("sample table has names, groups, probabilities and match",
   all(c("method", "row_id", "Sample", "group", "truth", "response", "prob.case", "prob.control", "match") %in% names(tab)) &&
     all(tab$Sample == sample_lookup$Sample[tab$row_id]) && all(tab$group == group_lookup[as.character(tab$row_id)]) &&
     identical(tab$match, tab$truth == tab$response))

# ── 3. bootstrap ─────────────────────────────────────────────────────────────
ci <- bootstrap_prediction_metrics(pooled, measures, n_boot = 200, seed = 1)
ok("bootstrap: one row per measure, interval brackets the estimate",
   nrow(ci) == length(measures) && all(ci$ci_low <= ci$estimate + 1e-8) && all(ci$ci_high >= ci$estimate - 1e-8))
bounded <- ci$metric %in% c("classif.acc", "classif.bacc", "classif.auc")   # logloss is unbounded
ok("bootstrap: bounded metrics stay inside [0,1] with a non-trivial interval",
   all(ci$ci_low[bounded] >= 0 & ci$ci_high[bounded] <= 1) && all(ci$ci_high[bounded] - ci$ci_low[bounded] < 1))
ok("bootstrap: repeatable with the same seed",
   isTRUE(all.equal(ci, bootstrap_prediction_metrics(pooled, measures, n_boot = 200, seed = 1))))

# ── 4. summary of a prediction set ───────────────────────────────────────────
s <- summarise_prediction_set(list(kknn = pooled), measures, sample_lookup, group_lookup,
                              n_boot = 100, seed = 1, positive_class = "case")
ok("metrics table is benchmark-shaped with readable names and n",
   nrow(s$metrics) == 1 && all(c("method", "learner_id", "n", "accuracy", "balanced accuracy", "auc", "logloss") %in% names(s$metrics)) &&
     s$metrics$n == task$nrow && s$metrics$method == "K-Nearest Neighbor")
ok("ci table is long with readable metric names", nrow(s$ci) == length(measures) && "balanced accuracy" %in% s$ci$metric)
ok("per-group rows: one per site with its n",
   nrow(s$by_group) == 4 && setequal(s$by_group$group, names(n_per)) &&
     all(s$by_group$n[match(names(n_per), s$by_group$group)] == n_per))
ok("samples table stacked per method", nrow(s$samples) == task$nrow && all(s$samples$method == "kknn"))
s0 <- summarise_prediction_set(list(kknn = pooled), measures, n_boot = 0)
ok("n_boot = 0 skips the interval and groups", is.null(s0$ci) && is.null(s0$by_group))

# ── 5. spread, curves, plots ─────────────────────────────────────────────────
fold_metrics <- collect_benchmark_scores(res_lodo, lapply(measures, msr), task = task,
                                         positive_class = "case", group_lookup = group_lookup)
fold_metrics$method <- recode_method_labels(fold_metrics$learner_id)
fold_metrics <- dplyr::rename_with(fold_metrics, label_measure_name)
sp <- fold_metric_spread(fold_metrics)
ok("fold spread: one row per method x metric with n_folds = sites",
   nrow(sp) == length(measures) && all(sp$n_folds == 4) && all(c("mean", "sd") %in% names(sp)))
roc <- roc_curve_points(pooled, "case")
ok("ROC runs from (0,0) to (1,1) and is monotone",
   roc$fpr[1] == 0 && roc$tpr[1] == 0 && tail(roc$fpr, 1) == 1 && tail(roc$tpr, 1) == 1 && !is.unsorted(roc$tpr))
rf <- roc_curves_by_fold(res_lodo, "kknn", "case")
ok("ROC by fold: 4 folds + pooled", setequal(unique(rf$fold), c("1", "2", "3", "4", "pooled")))
cal <- calibration_curve_points(pooled, "case", bins = 5)
ok("calibration bins are within [0,1] and sum to n", all(cal$obs_frac >= 0 & cal$obs_frac <= 1) && sum(cal$n) == task$nrow)
if (requireNamespace("ggplot2", quietly = TRUE)) {
  p <- plot_prediction_by_class(s$samples, class_levels = c("case", "control"), title = "toy")
  ok("right/wrong plot is a ggplot", inherits(p, "ggplot"))
  bench_df <- s$metrics   # any benchmark-shaped table works for the plot
  d <- plot_dumbbell(bench_df, sp, s$metrics, s$ci, test_label = "Internal test")
  ok("dumbbell returns two ggplots", inherits(d$by_method, "ggplot") && inherits(d$by_metric, "ggplot"))
  d0 <- plot_dumbbell(bench_df, sp, s$metrics, NULL, test_label = "External test")
  ok("dumbbell works without a ci table", inherits(d0$by_metric, "ggplot"))
}
# ── per_class_recall_table(): the benchmark number taken apart ───────────────
# Hand-built table with a known answer: method A gets every "case" and half the
# "control"s (recall 1.0 / 0.5); method B is the lazy majority-class predictor
# that never says "control" at all (1.0 / 0.0). Balanced accuracy is the mean
# of each recall column, which is what the last row must show.
pc <- data.frame(
  method = rep(c("ranger", "tabpfn"), each = 6),
  truth = rep(c(rep("case", 4), rep("control", 2)), 2),
  response = c("case", "case", "case", "case", "control", "case",
               "case", "case", "case", "case", "case", "case"),
  stringsAsFactors = FALSE
)
tab <- per_class_recall_table(pc)
stopifnot(nrow(tab) == 3, tab$class[nrow(tab)] == "mean (= balanced accuracy)")
cat("PASS: per_class_recall_table returns one row per class plus a mean row\n")
stopifnot(identical(tab$n[tab$class == "case"], 4L), identical(tab$n[tab$class == "control"], 2L))
cat("PASS: class sizes are counted once, not once per method\n")
rf <- tab[["Random Forest"]]; tp <- tab[["TabPFN"]]
stopifnot(rf[tab$class == "control"] == 0.5, tp[tab$class == "control"] == 0)
cat("PASS: recall per class and method is correct, including a never-predicted class\n")
stopifnot(abs(rf[nrow(tab)] - 0.75) < 1e-9, abs(tp[nrow(tab)] - 0.5) < 1e-9)
cat("PASS: the mean row equals balanced accuracy for each method\n")
# The reference method is the better one (ranger here), so the confusion column
# describes it: its one wrong "control" was called "case".
stopifnot(grepl("Random Forest", tab$confused_with[nrow(tab)]),
          tab$confused_with[tab$class == "control"] == "case",
          tab$confused_with[tab$class == "case"] == "-")
cat("PASS: confusions come from the best method, '-' when a class is never missed\n")
# Unlabelled rows (external controls) must not count as misses.
pc_na <- rbind(pc, data.frame(method = "ranger", truth = NA_character_, response = "case"))
stopifnot(identical(per_class_recall_table(pc_na)$n, per_class_recall_table(pc)$n))
cat("PASS: rows without a truth label are dropped\n")
stopifnot(is.null(per_class_recall_table(pc[0, ])), is.null(per_class_recall_table(NULL)))
cat("PASS: an empty or missing table gives NULL instead of failing\n")

cat("\nAll prediction-helper tests passed.\n")
