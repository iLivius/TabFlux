# Tests for R/tabflux_evaluation_helpers.R — plain script, no framework.
# Run from the repository root inside the tabflux-r environment:
#   Rscript tests/test_evaluation_helpers.R
# Takes about 12 minutes: part 3 tunes ranger with Hyperband, which runs its
# whole schedule (3 repetitions).
#
# What is checked:
#   1. build_test_split() reserves whole sites / a stratified draw, or nothing;
#      build_outer_resampling(): every outer strategy yields the expected
#      number of folds; grouped tasks split by whole groups; the fold cap.
#   2. The outer loop scores EXACTLY what mlr3's own nested resampling
#      (AutoTuner inside resample()) scores, on a case both can express:
#      one measure, grid search, a deterministic learner, identical folds.
#      This is the equivalence that makes the hand-written loop a faithful
#      implementation of nested resampling rather than a look-alike.
#   3. run_outer_evaluation() end to end on a toy task, nested = FALSE and
#      nested = TRUE, with resume-from-disk.
suppressMessages({
  library(mlr3); library(mlr3learners); library(mlr3tuning); library(mlr3pipelines)
  library(mlr3hyperband)   # train_methods() tunes ranger with tnr("hyperband")
  library(paradox); library(data.table); library(dplyr)
})
lgr::get_logger("mlr3")$set_threshold("off"); lgr::get_logger("bbotk")$set_threshold("off")
source(file.path("R", "tabflux_evaluation_helpers.R"))
source(file.path("R", "tabflux_training_helpers.R"))
source(file.path("R", "tabflux_selection_helpers.R"))
ok <- function(label, cond) { stopifnot(cond); cat("PASS:", label, "\n") }

# ── toy data: 4 sites of unequal size, binary target ─────────────────────────
# The grouping column must be called `group`: the notebook copies the column
# named in dataset.group into tab$group, and the helpers key off that name.
set.seed(1)
n_per <- c(siteA = 30, siteB = 24, siteC = 18, siteD = 12)
dt <- data.table(
  x1 = rnorm(sum(n_per)), x2 = rnorm(sum(n_per)), x3 = rnorm(sum(n_per)),
  target = factor(sample(c("case", "control"), sum(n_per), TRUE)),
  group = factor(rep(names(n_per), times = n_per))
)
dt$x1 <- dt$x1 + ifelse(dt$target == "case", 1.2, 0)   # some signal
make_task <- function(grouped) {
  backend <- as_data_backend(dt, primary_key = seq_len(nrow(dt)))
  t <- as_task_classif(backend, target = "target", id = "toy")
  if (grouped) t$set_col_roles("group", "group")
  t$col_roles$feature <- setdiff(t$col_roles$feature, "group")
  t
}
task_g <- make_task(TRUE); task_p <- make_task(FALSE)
min_count <- min(table(dt$target))

# ── 1. builder ────────────────────────────────────────────────────────────────
# internal test set (evaluation.test_split)
ok("test_split = 0 reserves nothing", is.null(build_test_split(task_g, 0, seed = 1)))
sp <- build_test_split(task_g, 0.25, seed = 1)
ok("grouped test split reserves whole sites, none shared with training",
   length(intersect(unique(dt$group[sp$train_ids]), unique(dt$group[sp$test_ids]))) == 0 &&
     setequal(c(sp$train_ids, sp$test_ids), seq_len(nrow(dt))))
task_s <- make_task(FALSE); task_s$set_col_roles("target", c("target", "stratum"))
sp <- build_test_split(task_s, 0.2, seed = 1)
ok("stratified test split keeps both classes on both sides, ~20 % reserved",
   length(unique(dt$target[sp$test_ids])) == 2 && length(unique(dt$target[sp$train_ids])) == 2 &&
     abs(length(sp$test_ids) / nrow(dt) - 0.2) < 0.05)
ok("test split repeatable with the same seed",
   identical(build_test_split(task_s, 0.2, seed = 1)$test_ids, sp$test_ids))
ok("test_split >= 0.5 refused", inherits(try(build_test_split(task_g, 0.5, seed = 1), silent = TRUE), "try-error"))
ok("'holdout' is no longer an outer strategy",
   inherits(try(build_outer_resampling("holdout", 10, 3, min_count, task_g), silent = TRUE), "try-error"))

r <- build_outer_resampling("lodo", 10, 3, min_count, task_g)
ok("lodo = one fold per site", r$iters == 4)
ok("lodo folds hold whole sites", all(sapply(1:4, function(i) length(unique(dt$group[r$test_set(i)])) == 1)))
r <- build_outer_resampling("cv", 10, 3, min_count, task_g)
ok("grouped cv capped at number of sites", r$iters == 4)
r <- build_outer_resampling("cv", 10, 3, min_count, task_p)
ok("plain cv keeps 10 folds when classes allow", r$iters == 10)
r <- build_outer_resampling("cv", 10, 3, 3, task_p)
ok("cv folds capped by rarest class", r$iters == 3)
r <- build_outer_resampling("repeated_cv", 5, 2, min_count, task_p)
ok("repeated cv = folds x repeats", r$iters == 10)
r <- build_outer_resampling("subsampling", 5, 4, min_count, task_p)
ok("subsampling = repeats splits, each testing 1/folds of the samples",
   r$iters == 4 && abs(length(r$test_set(1)) / nrow(dt) - 0.2) < 0.05)
r <- build_outer_resampling("loo", 5, 4, min_count, task_p)
ok("loo = one fold per sample", r$iters == nrow(dt))
ok("lodo without groups refused",
   inherits(try(build_outer_resampling("lodo", 5, 1, min_count, task_p), silent = TRUE), "try-error"))

# ── 2. equivalence with mlr3's nested resampling (AutoTuner in resample) ─────
# Same outer folds, same inner folds, same grid, a deterministic learner
# (kknn: no randomness once k is fixed). If our loop is a faithful nested
# resampling, both must produce identical outer predictions.
outer <- rsmp("cv", folds = 3); outer$instantiate(task_p)
inner <- rsmp("cv", folds = 3)
grid <- tnr("grid_search", resolution = 4)
lrn_k <- lrn("classif.kknn", predict_type = "prob", k = to_tune(3, 15))

at <- auto_tuner(tuner = grid, learner = lrn_k$clone(deep = TRUE), resampling = inner$clone(),
                 measure = msr("classif.bacc"), terminator = trm("none"))
set.seed(7); rr <- resample(task_p, at, outer, store_models = TRUE)
mlr3_scores <- rr$score(msr("classif.bacc"))$classif.bacc

loop_scores <- sapply(seq_len(outer$iters), function(i) {
  tr <- task_p$clone(deep = TRUE)$filter(outer$train_set(i))
  te <- task_p$clone(deep = TRUE)$filter(outer$test_set(i))
  set.seed(7)
  inst <- ti(tr, lrn_k$clone(deep = TRUE), inner$clone(), msr("classif.bacc"), trm("none"))
  grid$optimize(inst)
  l <- lrn_k$clone(deep = TRUE); l$param_set$values <- inst$result_learner_param_vals
  l$train(tr)$predict(te)$score(msr("classif.bacc"))
})
cat("  mlr3 nested:", round(mlr3_scores, 4), "| loop:", round(loop_scores, 4), "\n")
ok("hand-written loop == AutoTuner-in-resample (per-fold scores identical)",
   isTRUE(all.equal(unname(loop_scores), unname(mlr3_scores))))

# ── 3. run_outer_evaluation() end to end on the toy task ─────────────────────
tmp <- file.path(tempdir(), "outer_eval_test"); unlink(tmp, recursive = TRUE); dir.create(tmp)
methods <- list(ranger = "Random Forest")
setup <- build_classification_learners(methods, seed = 1, num_jobs = 1)
pipe <- po("scale", center = TRUE)
outer_g <- build_outer_resampling("lodo", 10, 3, min_count, task_g)

# nested = FALSE: a pre-tuned learner refit per fold
fixed <- as_learner(pipe %>>% setup$learners$ranger$clone(deep = TRUE)); fixed$id <- "ranger"
fixed$param_set$values$classif.ranger.num.trees <- 20L
fixed$train(task_g)
res_fixed <- run_outer_evaluation(
  task = task_g, outer_resampling = outer_g, methods = methods, nested = FALSE, selecting = FALSE,
  learners_best = list(ranger = fixed), selected_feats = NULL,
  train_args = list(), fs_args = list(seed = 1, num_threads = 1), save_dir = file.path(tmp, "fixed")
)
ok("nested=FALSE: one row per learner x fold", nrow(res_fixed$results) == 4)
ok("results carry the resampling for group lookup",
   inherits(res_fixed$results$resampling[[1]], "Resampling"))
ok("predictions cover exactly the fold's test rows",
   all(sapply(1:4, function(i) setequal(res_fixed$results$prediction[[i]]$row_ids, outer_g$test_set(i)))))
ok("per-fold prediction files written for resume",
   all(file.exists(file.path(tmp, "fixed", sprintf("outer_fold_%02d", 1:4), "predictions_ranger.rds"))))

# nested = TRUE: tuning inside every fold via train_methods() (tiny budget)
tab <- as.data.frame(dt)   # train_methods only reads names(tab); the "group" column puts inner tuning on leave-one-group-out
train_args <- list(
  methods = methods, learners = setup$learners, preprocessing_pipe = pipe, preproc_params = list(),
  tab = tab, train_measures = c("classif.bacc", "classif.logloss"), fast_tuning = FALSE,
  learner_fallback = FALSE, num_threads = 2, tuning_workers = 2L, inner_folds = 2L, inner_repeats = 1L,   # 2 workers: parallel path
  term_min = 0.05, selection_rule = "one_se", eval_metrics = c("error", "logloss"),
  inner_resampling = NULL
)
res_nested <- run_outer_evaluation(
  task = task_g, outer_resampling = outer_g, methods = methods, nested = TRUE, selecting = FALSE,
  train_args = train_args, fs_args = list(seed = 1, num_threads = 1), save_dir = file.path(tmp, "nested")
)
ok("nested=TRUE: one row per learner x fold", nrow(res_nested$results) == 4)
ok("each fold tuned separately (tuning instance per fold on disk)",
   all(file.exists(file.path(tmp, "nested", sprintf("outer_fold_%02d", 1:4), "ranger_tuned_instance.rds"))))
# resume: a second call must not retune (prediction files already there)
t0 <- Sys.time()
res_again <- run_outer_evaluation(
  task = task_g, outer_resampling = outer_g, methods = methods, nested = TRUE, selecting = FALSE,
  train_args = train_args, fs_args = list(seed = 1, num_threads = 1), save_dir = file.path(tmp, "nested")
)
ok("resume reuses saved predictions", as.numeric(Sys.time() - t0, units = "secs") < 10 &&
     identical(res_again$results$prediction[[1]]$row_ids, res_nested$results$prediction[[1]]$row_ids))

# ── call_by_name(): the recorded call must carry names, not values ──────────
# (a do.call() copy of a large fold task can exceed R's serialisation limit
# when sent to the workers)
probe <- function(task_train, k) list(call = sys.call(), n = k)
big_arg <- runif(1e6)
res <- call_by_name(probe, list(task_train = big_arg, k = 3L))
stopifnot(res$n == 3L); cat("PASS: call_by_name passes the arguments through\n")
stopifnot(is.name(res$call$task_train), object.size(res$call) < 1e5)
cat("PASS: call_by_name records symbols, not the argument values\n")
stopifnot(inherits(try(call_by_name(probe, list(big_arg, 3L)), silent = TRUE), "try-error"))
cat("PASS: call_by_name refuses unnamed arguments\n")

# ── choose_tuning_resampling(): the inner loop must not scale with the groups ─
# Leave-one-group-out up to max(inner_folds, 10) groups, k-fold over the
# groups above that.
mk <- function(g) data.frame(target = factor(rep(c("a", "b"), 60)),
                             group = rep(paste0("g", seq_len(g)), length.out = 120))
r10 <- choose_tuning_resampling(mk(10), min_count = 60, inner_folds = 5, inner_repeats = 3, num_obs = 120, method = "ranger")
stopifnot(inherits(r10, "ResamplingLOO"))
cat("PASS: few groups still get leave-one-group-out\n")
r57 <- choose_tuning_resampling(mk(57), min_count = 60, inner_folds = 5, inner_repeats = 3, num_obs = 120, method = "ranger")
stopifnot(inherits(r57, "ResamplingCV"), r57$param_set$values$folds == 5L)
cat("PASS: many groups fall back to k-fold at inner_folds, not one fold per group\n")
r_big <- choose_tuning_resampling(mk(57), min_count = 60, inner_folds = 8, inner_repeats = 3, num_obs = 120, method = "ranger")
stopifnot(r_big$param_set$values$folds == 8L)
cat("PASS: the fold count follows evaluation.inner_folds\n")
stopifnot(inherits(choose_tuning_resampling(data.frame(target = factor(rep(c("a","b"), 60))),
          60, 5, 3, 600, "ranger"), "ResamplingCV"))
cat("PASS: an ungrouped task is unaffected\n")

# ── nested selection must search the FULL feature space in every fold ────────
# Handed a task that feature selection had already reduced, each fold would
# choose from a shortlist drawn with the held-out samples in view. This
# asserts the loop reports the feature count of the task it is GIVEN.
set.seed(1)
n <- 60; p_feat <- 40
dt_leak <- data.table::data.table(target = factor(rep(c("a","b"), n/2)),
                                  group = rep(paste0("g", 1:4), length.out = n))
for (j in seq_len(p_feat)) dt_leak[[paste0("f", j)]] <- rnorm(n)
tsk_full <- mlr3::as_task_classif(dt_leak, target = "target")
tsk_full$set_col_roles("group", "group")
rs <- mlr3::rsmp("cv", folds = 2); rs$instantiate(tsk_full)
res <- run_outer_evaluation(
  task = tsk_full, outer_resampling = rs, methods = c(featureless = "Featureless"),
  nested = FALSE, selecting = FALSE, learners_best = list(featureless = mlr3::lrn("classif.featureless", predict_type = "prob")),
  selected_feats = NULL, train_args = list(), fs_args = list(seed = 1, num_threads = 1),
  save_dir = file.path(tempdir(), "leaktest"))
stopifnot(all(res$fold_info$n_features == p_feat))
cat("PASS: the outer loop sees every feature of the task it is handed\n")

# ── a class held out with the only group that carries it must be reported ────
# Group g4 is the only group with class "c"; leave-one-group-out therefore has one
# fold whose test part contains a class the training part never saw.
dt_u <- data.table::data.table(
  target = factor(c(rep("a", 20), rep("b", 20), rep("c", 10))),
  group  = c(rep(c("g1", "g2", "g3"), length.out = 40), rep("g4", 10)))
for (j in 1:5) dt_u[[paste0("f", j)]] <- rnorm(50)
tsk_u <- mlr3::as_task_classif(dt_u, target = "target"); tsk_u$set_col_roles("group", "group")
rs_u <- mlr3::rsmp("loo"); rs_u$instantiate(tsk_u)
res_u <- withCallingHandlers(
  run_outer_evaluation(task = tsk_u, outer_resampling = rs_u, methods = c(featureless = "Featureless"),
    nested = FALSE, selecting = FALSE,
    learners_best = list(featureless = mlr3::lrn("classif.featureless", predict_type = "prob")),
    selected_feats = NULL, train_args = list(), fs_args = list(seed = 1, num_threads = 1),
    save_dir = file.path(tempdir(), "untrainable")),
  warning = function(w) { if (grepl("not in the training part", conditionMessage(w))) invokeRestart("muffleWarning") })
stopifnot(sum(res_u$fold_info$classes_untrainable == "c") == 1,
          sum(res_u$fold_info$classes_untrainable == "") == 3)
cat("PASS: a test class absent from training is recorded per fold\n")

# ── outer folds: the correction uses each fold's OWN training frequencies ─────
set.seed(11)
dt_p <- data.table::data.table(target = factor(c(rep("a", 60), rep("b", 20), rep("c", 10))),
                               group = rep(paste0("g", 1:6), length.out = 90))
for (j in 1:6) dt_p[[paste0("f", j)]] <- rnorm(90) + ifelse(j <= 2, as.integer(dt_p$target), 0)
tsk_p <- mlr3::as_task_classif(dt_p, target = "target"); tsk_p$set_col_roles("group", "group")
rs_p <- mlr3::rsmp("cv", folds = 3); rs_p$instantiate(tsk_p)
rf <- mlr3::lrn("classif.ranger", predict_type = "prob", num.trees = 100)
res_p <- run_outer_evaluation(task = tsk_p, outer_resampling = rs_p, methods = c(ranger = "RF"),
  nested = FALSE, selecting = FALSE, learners_best = list(ranger = rf), selected_feats = NULL,
  train_args = list(), fs_args = list(seed = 1, num_threads = 1),
  save_dir = file.path(tempdir(), "priorcorr"), prior_correction = TRUE)
for (i in seq_len(rs_p$iters)) {
  pr <- res_p$results$prediction[[i]]
  pri <- prop.table(table(factor(tsk_p$truth(rs_p$train_set(i)), levels = colnames(pr$prob))))
  pri[pri == 0] <- 1
  want <- colnames(pr$prob)[max.col(sweep(pr$prob, 2, as.numeric(pri), "/"), ties.method = "first")]
  stopifnot(identical(as.character(pr$response), want))
}
cat("PASS: outer-fold labels use each fold's training class frequencies\n")

cat("\nAll evaluation-helper tests passed.\n")
