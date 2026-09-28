# Every learner except TabPFN, end to end on one toy dataset.
#
# TabPFN is left out on purpose: it needs the Python side, a licence token and
# the downloaded weights, none of which belong in a unit test. LDA and naive
# Bayes are not offered at all: see docs/workflow/learners.md for why a taxa
# table breaks their assumptions.
#
# The toy table imitates the shape TabFlux is built for - a few hundred samples
# in study-sized groups, more taxa than a fold can afford, three unbalanced
# classes, sparse log-abundance-like values - so the checks below exercise the
# real path: build the learner, apply the per-method settings, wrap it in the
# preprocessing graph, tune it briefly (4 random-search settings on a fixed
# two-fold split, not the method's own tuner and terminator), and refit the
# chosen setting. What is asserted afterwards: the refit must use the TOP of
# any budget range (a budget is a fidelity knob, not a hyperparameter), the
# model must be the learner asked for and not the majority-class fallback, and
# it must return probabilities.
suppressMessages({
  library(mlr3); library(mlr3learners); library(mlr3pipelines); library(mlr3tuning)
  library(mlr3hyperband); library(mlr3filters); library(mlr3torch); library(paradox); library(data.table)
})
lgr::get_logger("mlr3")$set_threshold("warn")
lgr::get_logger("bbotk")$set_threshold("warn")
source(file.path("R", "tabflux_training_helpers.R"))

set.seed(42)
n_per_group <- 20L; n_groups <- 15L; n_feat <- 60L
n <- n_per_group * n_groups
group <- rep(sprintf("study%02d", seq_len(n_groups)), each = n_per_group)
# Three classes, deliberately unbalanced (7 : 4 : 4 studies), each spread over
# several studies so every fold can learn every class it is scored on. (A class
# confined to one or two studies can land entirely inside one fold, leaving the
# other fold's training part without it; that is a property of the split, not
# of the learner, and it is checked separately below.)
class_of_study <- c(rep("a", 7), rep("b", 4), rep("c", 4))
target <- factor(class_of_study[as.integer(sub("study", "", group))], levels = c("a", "b", "c"))
tab <- data.table(target = target, group = group)
for (j in seq_len(n_feat)) {
  shift <- if (j <= 6) as.numeric(target) * 0.9 else 0          # a few informative taxa
  tab[[sprintf("t%02d", j)]] <- round(pmin(0, rnorm(n, -3 + shift, 1)), 3)
}
task <- as_task_classif(tab, target = "target", id = "toy")
task$set_col_roles("group", "group")
preproc <- ppl("robustify") %>>%
  po("colapply", applicator = as.numeric, affect_columns = selector_type(c("integer", "logical", "numeric"))) %>>%
  po("scale", center = TRUE)

METHODS <- c(ranger = "Random Forest", xgboost = "XGBoost", glmnet = "glmnet",
             kknn = "kknn", svm = "SVM", mlp = "MLP")
stats <- get_training_task_stats(task)

# A fixed two-fold split over whole studies, chosen so that BOTH training
# parts contain all three classes. A random grouped split can put every study
# of a rare class in one fold, which leaves the other fold unable to learn it:
# ranger, kknn, svm and xgboost then never predict that class, glmnet stops
# with an error. That is a property of the split, not of the learner, so it is
# pinned here and reported separately by the workflow.
fold_test_studies <- list(c("study01", "study02", "study08", "study12"),
                          c("study03", "study04", "study09", "study13"))
rows_of <- function(st) which(group %in% st)
inner <- rsmp("custom")
inner$instantiate(task,
                  train_sets = lapply(fold_test_studies, function(st) setdiff(seq_len(n), rows_of(st))),
                  test_sets  = lapply(fold_test_studies, rows_of))
for (k in seq_len(inner$iters)) {
  seen <- unique(as.character(task$data(rows = inner$train_set(k), cols = "target")[[1]]))
  stopifnot(setequal(seen, task$class_names))
}
cat("PASS: both folds train on all three classes\n")

for (fast in c(TRUE, FALSE)) {
  for (m in names(METHODS)) {
    label <- sprintf("%s (%s tuning)", m, if (fast) "fast" else "full")
    built <- build_classification_learners(methods = setNames(METHODS[m], m), num_jobs = 1L, seed = 1L)
    lrn_m <- prepare_method_learner(m, built$learners[[m]]$clone(deep = TRUE), c("mlogloss"))
    graph <- build_training_graph(m, lrn_m, preproc$clone(deep = TRUE), fast)
    gl <- configure_final_learner(as_learner(graph), m, num_threads = 1L, num_jobs = 1L, learner_fallback = FALSE)

    sp <- get_learner_search_params(m, fast_tuning = fast, num_feat = stats$num_feat, num_obs = stats$num_obs,
                                    min_count = stats$min_count)
    ss <- do.call(ps, sp)
    # Tuned on the corrected balanced accuracy, as a run with evaluation.prior_correction does.
    inst <- ti(task, gl, inner$clone(deep = TRUE), tuning_measures(c("classif.bacc", "classif.logloss"), prior_correction = TRUE),
               trm("evals", n_evals = 4L), search_space = ss, store_benchmark_result = TRUE)
    tnr("random_search", batch_size = 1L)$optimize(inst)

    # No evaluation may have fallen back to the majority-class dummy.
    n_err <- tryCatch(sum(inst$archive$data$errors, na.rm = TRUE), error = function(e) 0L)
    stopifnot(isTRUE(n_err == 0))

    # Refit the chosen setting the way train_methods() does, budget at the top.
    front <- as.data.frame(inst$archive$best())
    pars <- inst$archive$learner_param_vals(uhash = front$uhash[1])
    for (b in intersect(ss$ids(tags = "budget"), names(pars))) {
      top <- ss$upper[[b]]
      if (identical(ss$class[[b]], "ParamInt")) top <- as.integer(top)
      pars[[b]] <- top
    }
    tuned <- if ("internal_tuned_values" %in% names(front)) front$internal_tuned_values[[1]] else NULL
    if (length(tuned)) {
      pars[names(tuned)] <- tuned
      for (pn in c("patience", "measures_valid")) {
        id <- paste0("classif.", m, ".", pn)
        if (id %in% gl$param_set$ids()) pars[[id]] <- if (pn == "patience") 0L else list()
      }
    }
    gl$param_set$values <- pars
    if (length(tuned)) {
      set_validate(gl, NULL)
      try(gl$param_set$disable_internal_tuning(names(tuned)), silent = TRUE)
    }
    gl$train(task)

    # An internally tuned parameter must reach the refit at the value the inner
    # folds settled on, not at the cap it was searched under.
    if (length(tuned)) {
      for (id in names(tuned)) stopifnot(isTRUE(all.equal(gl$param_set$values[[id]], tuned[[id]])))
    }

    # A budget must not survive the refit below its ceiling, and the row
    # subsample must be gone: the shipped model is fit on every row.
    for (b in intersect(ss$ids(tags = "budget"), names(gl$param_set$values))) {
      stopifnot(isTRUE(all.equal(gl$param_set$values[[b]], if (identical(ss$class[[b]], "ParamInt")) as.integer(ss$upper[[b]]) else ss$upper[[b]])))
    }
    if ("subsample.frac" %in% names(gl$param_set$values)) {
      stopifnot(isTRUE(all.equal(gl$param_set$values$subsample.frac, 1)))
    }

    # The fitted model is the learner that was asked for, not the fallback.
    fitted <- gl$graph_model$pipeops[[paste0("classif.", m)]]$learner_model
    stopifnot(!inherits(fitted, "LearnerClassifFeatureless"))

    pred <- gl$predict(task)
    raw <- pred$prob
    pred <- apply_prior_correction(pred, task$truth())
    pri <- prop.table(table(task$truth()))[colnames(raw)]
    stopifnot(identical(as.character(pred$response),
                        colnames(raw)[max.col(sweep(raw, 2, as.numeric(pri), "/"), ties.method = "first")]),
              isTRUE(all.equal(pred$prob, raw)))
    stopifnot(inherits(pred, "PredictionClassif"),
              !is.null(pred$prob), nrow(pred$prob) == task$nrow,
              all(is.finite(pred$prob)),
              all(abs(rowSums(pred$prob) - 1) < 1e-6),
              identical(sort(colnames(pred$prob)), sort(task$class_names)))
    cat(sprintf("PASS: %-26s bacc %.2f\n", label, pred$score(msr("classif.bacc"))))
  }
}

# The row-subsample budget must sample rows, not whole studies: honouring the
# group role, a low budget would draw one or two studies, often of a single
# class, and the low rungs of successive halving would rank nothing.
sub <- po("subsample", use_groups = FALSE, stratify = TRUE, frac = 0.2)
small <- sub$train(list(task))[[1]]
stopifnot(length(unique(small$data(cols = small$target_names)[[1]])) == length(task$class_names))
cat("PASS: the row-subsample budget keeps every class\n")

cat("\nAll learner tests passed.\n")
