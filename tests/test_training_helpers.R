# Tests for R/tabflux_training_helpers.R: the MLP tuning setup, the
# class-prior correction, and the stop when tuning produced no usable setting.
# Run from the project root: Rscript tests/test_training_helpers.R
suppressMessages({library(mlr3); library(mlr3tuning); library(mlr3torch); library(mlr3pipelines)
                  library(mlr3learners); library(mlr3hyperband); library(paradox); library(data.table)})
source(file.path("R", "tabflux_training_helpers.R"))
# call a helper with only the arguments it declares, so the test does not
# depend on argument order
call_declared <- function(f, ...) { a <- list(...); do.call(f, a[intersect(names(a), names(formals(f)))]) }

# ── one search space in both modes, and no Hyperband budget in it ────────────
sp_fast <- call_declared(get_learner_search_params, method = "mlp", fast_tuning = TRUE,  num_feat = 100, num_obs = 900)
sp_full <- call_declared(get_learner_search_params, method = "mlp", fast_tuning = FALSE, num_feat = 100, num_obs = 900)
stopifnot(identical(names(sp_fast), names(sp_full)))
cat("PASS: the MLP search space is the same in fast and full mode\n")
ss_fast <- do.call(ps, sp_fast)            # tags live on the ParamSet, not on the domains
stopifnot(length(ss_fast$ids(tags = "budget")) == 0)
cat("PASS: no parameter is tagged as a Hyperband budget\n")
stopifnot(sp_fast$classif.mlp.opt.lr$upper <= log(1e-2) + 1e-9)     # logscale ranges are stored as logs
stopifnot(is.null(sp_fast$classif.mlp.opt.weight_decay))
# one family, two boxes: fast searches a smaller width x depth box than normal
stopifnot(sp_fast$classif.mlp.n_layers$upper == 2L, sp_full$classif.mlp.n_layers$upper == 3L)
stopifnot(sp_fast$classif.mlp.neurons$upper < sp_full$classif.mlp.neurons$upper)
cat("PASS: fast mode searches width 32-256 x depth 1-2, normal 32-512 x depth 1-3\n")
cat("PASS: learning rate capped at 1e-2, no weight-decay dimension\n")
stopifnot(identical(ss_fast$ids(tags = "internal_tuning"), "classif.mlp.epochs"))
cat("PASS: epochs stay internally tuned\n")

# ── random search with a fixed evaluation count ──────────────────────────────
for (fm in c(TRUE, FALSE)) {
  tn <- get_tuner_for_method(method = "mlp", fast_tuning = fm, num_threads = 4L, num_jobs = 4L)
  stopifnot(inherits(tn, "TunerBatchRandomSearch") || grepl("RandomSearch", class(tn)[1]))
  tm <- call_declared(get_terminator_for_method, method = "mlp", term_min = 20, fast_tuning = fm)
  stopifnot(inherits(tm, "TerminatorEvals"), tm$param_set$values$n_evals == if (fm) 40L else 80L)
}
cat("PASS: random search, 40 settings in fast mode and 80 in full mode\n")

# ── the learner stops on log-loss, checks every epoch, one torch thread ──────
lr <- build_classification_learners(methods = c(mlp = "MLP"), num_jobs = 8L, seed = 1L)$learners[["mlp"]]
stopifnot(identical(lr$param_set$values$opt.weight_decay, 0.01))
cat("PASS: weight decay is set explicitly on the learner\n")
pv <- lr$param_set$values
stopifnot(pv$measures_valid[[1]]$id == "classif.logloss", pv$eval_freq == 1, pv$patience == 10, pv$min_delta == 0, pv$num_threads == 1L)
cat("PASS: early stopping watches log-loss first; one torch thread per fit\n")


# ── the class-prior correction ───────────────────────────────────────────────
# Predicted category = largest probability divided by the class's training
# frequency, the decision that maximises balanced accuracy. It must change the
# labels only, never the probabilities, and treat a class absent from training
# as never boosted.
th <- class_prior_threshold(c("a", "a", "a", "b"), c("a", "b", "c"))
stopifnot(isTRUE(all.equal(unname(th), c(0.75, 0.25, 1))), identical(names(th), c("a", "b", "c")))
cat("PASS: thresholds are the training frequencies, 1 for an unseen class\n")

set.seed(3)
tk <- mlr3::tsk("iris")$filter(c(1:50, 51:66, 101:106))          # 50 / 16 / 6: unbalanced
lr <- mlr3::lrn("classif.ranger", predict_type = "prob", num.trees = 150); lr$train(tk)
pr <- lr$predict(tk); before <- pr$prob
pr2 <- apply_prior_correction(pr$clone(deep = TRUE), tk$truth())
prior <- prop.table(table(tk$truth()))[colnames(before)]
manual <- colnames(before)[max.col(sweep(before, 2, as.numeric(prior), "/"), ties.method = "first")]
stopifnot(identical(as.character(pr2$response), manual), isTRUE(all.equal(pr2$prob, before)))
cat("PASS: apply_prior_correction() = argmax(prob / prior), probabilities untouched\n")

m <- MeasureClassifBaccPrior$new()
stopifnot(identical(m$id, "classif.bacc"))
rr <- mlr3::resample(tk, lr, mlr3::rsmp("holdout", ratio = 0.7))
got <- rr$aggregate(m)[["classif.bacc"]]
pred <- rr$predictions()[[1]]; tr <- rr$resampling$train_set(1)
want <- mlr3measures::bacc(pred$truth, apply_prior_correction(pred$clone(deep = TRUE), tk$truth(tr))$response)
stopifnot(isTRUE(all.equal(unname(got), want)))
cat("PASS: the tuning measure scores the corrected decision with the training rows' frequencies\n")

ms <- tuning_measures(c("classif.bacc", "classif.logloss"), prior_correction = TRUE)
stopifnot(inherits(ms[[1]], "MeasureClassifBaccPrior"), identical(ms[[2]]$id, "classif.logloss"))
ms0 <- tuning_measures(c("classif.bacc", "classif.logloss"), prior_correction = FALSE)
stopifnot(!inherits(ms0[[1]], "MeasureClassifBaccPrior"))
cat("PASS: tuning_measures() swaps in the corrected balanced accuracy only when asked\n")

suppressMessages(library(mlr3extralearners))   # registers classif.tabpfn; Python is not started
tp <- build_classification_learners(methods = c(tabpfn = "TabPFN"), num_jobs = 1L, seed = 1L)$learners$tabpfn
stopifnot(isFALSE(tp$param_set$values$balance_probabilities))
cat("PASS: TabPFN does not correct its own probabilities (balance_probabilities off)\n")


# ── a tuning run in which every evaluation failed stops the run ──────────────
# When tuning produces no scored setting, train_methods() must stop and name
# the method, not publish an untuned learner that the Benchmark chunk would
# then train with its default settings. A saved tuning archive whose Pareto
# front is empty stands in for such a run: train_methods() finds it on disk
# (the "archive present, learner missing" resume path), goes straight to the
# refit, and must stop there. glmnet on iris keeps the set-up cheap; nothing
# is tuned.
failed_dir <- file.path(tempdir(), "failed_tuning")
dir.create(failed_dir, showWarnings = FALSE)
empty_archive <- list(
  result = NULL,                                            # tuner never finished
  archive = list(best = function() data.table::data.table())  # no scored setting
)
saveRDS(empty_archive, file.path(failed_dir, "glmnet_tuned_instance.rds"))

iris_task <- mlr3::tsk("iris")
iris_stats <- get_training_task_stats(iris_task, target_col = "Species")
published <- new.env()
tuning_error <- tryCatch({
  capture.output(train_methods(
    methods = c(glmnet = "glmnet"),
    learners = build_classification_learners(methods = c(glmnet = "glmnet"), seed = 1L, num_jobs = 1L)$learners,
    preprocessing_pipe = mlr3pipelines::po("nop"),
    task_train = iris_task,
    tab = data.frame(target = iris_task$truth()),
    preproc_params = list(),
    save_dir = failed_dir,
    train_measures = c("classif.bacc", "classif.logloss"),
    fast_tuning = FALSE, learner_fallback = FALSE,
    num_threads = 1L, tuning_workers = 1L,
    inner_folds = 3L, inner_repeats = 1L, term_min = 1L,
    eval_metrics = get_eval_metrics("multi-class"),
    min_count = iris_stats$min_count, num_feat = iris_stats$num_feat, num_obs = iris_stats$num_obs,
    assign_env = published
  ))
  NULL
}, error = function(e) conditionMessage(e))
stopifnot(!is.null(tuning_error))
cat("PASS: an archive with no scored setting stops train_methods()\n")
stopifnot(startsWith(tuning_error, "glmnet:"), grepl("every tuning evaluation failed", tuning_error))
cat("PASS: the error names the method and says every tuning evaluation failed\n")
stopifnot(!exists("glmnet_tuned_learner", envir = published, inherits = FALSE),
          !file.exists(file.path(failed_dir, "glmnet_tuned_learner.rds")))
cat("PASS: no untuned learner is published or saved\n")

cat("\nAll training-helper tests passed.\n")
