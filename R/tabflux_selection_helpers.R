# Wrapper feature selection, packaged as one function so it can run once on
# the full training data (the final model) and again inside every outer
# evaluation fold (nested resampling), on that fold's training part only.
#
# Called by the notebook's "Feature Selection" chunk (final model) and by
# run_outer_evaluation() (every nested outer fold). Two modes: "simple" =
# information-gain prefilter + random forest RFE with the one-SE rule;
# "ensemble" = four learners x 50 subsamples, for tiny sample numbers only.
#
# Input:  task_train – an mlr3 task holding the candidate taxa (NOT yet
#                      reduced; the caller passes a fresh clone)
#         task_test  – optional companion task whose columns must stay
#                      identical to task_train's (NULL when there is none)
#         seed, num_threads – from the settings chunk
#         prior_correction – evaluation.prior_correction: rank subsets by the
#                      class-prior corrected balanced accuracy ("simple" mode)
#         out_dir    – where selected_features.csv (and, in ensemble mode,
#                      feature_selection_stability.csv) are written
#         num_col    – below this many columns RFE may shrink to 2 taxa
#                      instead of 10
#         num_row    – at or below this many samples the mode is "ensemble"
# Output: list(selected_feats = character vector,
#              task_train = the task reduced to those taxa,
#              task_test  = the companion task reduced the same way, or NULL)
#
# Runs sequentially: the CV folds of every selector are evaluated one after
# another. The only parallelism is the thread count given to ranger /
# xgboost via set_threads() inside.

# How many top-ranked taxa to keep before the wrapper step (used in "simple"
# mode below). p = number of taxa, n = number of samples. Keeps the largest
# of: min_keep, 5 x n, 1% of p — capped at max_keep and at p itself — so the
# wrapper never gets more candidates than it can evaluate in reasonable time.
make_fs_prefilter_budget <- function(p, n, min_keep = 500L, max_keep = 2500L,
                                     keep_frac = 0.01) {
  budget <- max(
    as.integer(min_keep),
    as.integer(ceiling(5 * n)),
    as.integer(ceiling(keep_frac * p))
  )
  as.integer(min(p, max_keep, budget))
}

# The ladder of subset sizes RFE (recursive feature elimination) steps down:
# coarse steps as fractions of `start` (the prefiltered taxa count), then a
# fixed fine-grained ladder from 400 down to `stop` (the minimum to keep).
# Output goes straight into fs("rfe", subset_sizes = ...).
make_fs_subset_sizes <- function(start, stop) {
  if (start <= stop) return(as.integer(stop))
  
  coarse <- unique(as.integer(round(start * c(1, 0.85, 0.70, 0.55, 0.40, 0.30, 0.22, 0.16))))
  fine <- c(400L, 300L, 250L, 200L, 175L, 150L, 125L, 100L,
            80L, 60L, 50L, 40L, 30L, 25L, 20L, 15L, 12L, 10L,
            8L, 6L, 5L, 4L, 3L, 2L)
  
  sizes <- sort(unique(c(coarse, fine, stop)), decreasing = TRUE)
  sizes[sizes <= start & sizes >= stop]
}

select_features <- function(task_train, task_test = NULL, seed, num_threads, out_dir,
                            num_col = 100L, num_row = 10L, prior_correction = FALSE) {
  future::plan(sequential)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # Number of candidate taxa before any prefilter, kept for the messages.
  n_candidates <- task_train$ncol - 1L
  message("Feature selection starting from ", n_candidates, " candidate features.")

  # Reset the random seed here so rerunning just this chunk gives the same
  # resampling splits and the same learner randomness as a full render.
  fs_seed <- as.integer(seed + 1000L)
  # Pin the generator kind as well as the seed. set.seed() inherits whatever
  # generator is active, and parallel back ends switch R to "L'Ecuyer-CMRG".
  # With the same seed, the two generator kinds can select different numbers
  # of features, because the CV splits inside the elimination differ.
  # Naming the kind makes the result depend only on the data and the seed.
  set.seed(fs_seed, kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
  message("Feature selection RNG seed reset to ", fs_seed)
  
  # Smallest subset RFE is allowed to reach: 2 taxa for small feature
  # spaces, 10 otherwise.
  if (task_train$ncol < num_col) {
    n_features = 2
  } else {
    n_features = 10
  }
  # "simple": one random forest RFE with 5-fold CV. "ensemble": four
  # learners x 50 subsamples, only affordable on very small sample numbers.
  if (task_train$nrow > num_row) {
    fs_method = "simple"
  } else {
    fs_method = "ensemble" # Ensemble Feature Selection is computationally very demanding
  }
  message("Feature selection mode: ", fs_method)
  
  # Callbacks = small add-on routines that mlr3fselect calls at fixed points
  # during the search (after each ranking, at the end)
  # (https://mlr-org.com/gallery/technical/2025-01-12-efs/):
  #   svm_rfe         – rank taxa by the SVM's coefficient weights
  #   internal_tuning – let xgboost pick its number of boosting rounds by
  #                     early stopping on a 20% validation split (below)
  #   one_se_rule     – pick the smallest subset whose CV score is within one
  #                     standard error of the best
  svm_rfe = clbk("mlr3fselect.svm_rfe")
  
  # Search space for xgboost's internal tuning: nrounds up to max_nrounds,
  # decided by early stopping. aggr: early stopping gives a different best
  # nrounds in every CV fold; aggr says how to merge them into the single
  # value used for the final fit — here their mean.
  max_nrounds = 500
  internal_ss = ps(nrounds = p_int(
    upper = max_nrounds,
    aggr = function(x)
      as.integer(mean(unlist(x)))
  ))
  xgb_clbk = clbk("mlr3fselect.internal_tuning", internal_search_space = internal_ss)
  
  one_se_clbk = clbk("mlr3fselect.one_se_rule")
  
  # Learners that drive the elimination. RFE drops the taxa a learner ranks
  # least important, so each needs an importance measure: decision tree,
  # random forest, linear SVM (via svm_rfe), xgboost (gain). Simple mode uses
  # the random forest alone, ensemble mode all four, and the forest's measure
  # follows: "impurity" (how much splits on a taxon purify the tree nodes) is
  # fast; "permutation" (accuracy lost when that taxon's values are shuffled)
  # is slower but less biased toward abundant taxa.
  fs_rpart <- lrn("classif.rpart")
  fs_ranger <- lrn(
    "classif.ranger",
    importance = if (fs_method == "simple") "impurity" else "permutation",
    # probabilities, so subsets can be scored with the class-prior corrected
    # decision (evaluation.prior_correction) like everything downstream
    predict_type = if (isTRUE(prior_correction)) "prob" else "response"
  )
  fs_svm <- lrn("classif.svm", type = "C-classification", kernel = "linear")
  fs_xgboost <- lrn("classif.xgboost", nrounds = max_nrounds, early_stopping_rounds = 10)
  set_validate(fs_xgboost, 0.2) # validation ratio
  # ranger and xgboost each get a fifth of the cores. A fifth is a fixed
  # choice, not derived from anything in the data or the config. Under
  # plan(sequential) nothing else runs alongside, so it only caps how fast
  # this step goes.
  set_threads(fs_ranger, n = ceiling(num_threads / 5))
  set_threads(fs_xgboost, n = ceiling(num_threads / 5))
  
  # Give each learner a short id. These are plain lrn() learners (no
  # preprocessing graph attached in this function); the ids must match the
  # names of the callbacks list handed to ensemble_fselect() below.
  fs_rpart$id <- "rpart"
  fs_ranger$id <- "rf"
  fs_svm$id <- "svm"
  fs_xgboost$id <- "xgboost"
  
  learners = list(fs_rpart, fs_ranger, fs_svm, fs_xgboost)
  
  # "simple" mode: a light train-only prefilter, then random forest RFE.
  # The tasks are already numeric without missing values, so no imputation
  # or encoding is needed before the filter.
  if (fs_method == "simple") {
    # Five inner folds, but never more than the data can fill. On a GROUPED
    # task (dataset.group set) mlr3 splits by whole groups, so asking for five
    # folds when only three studies are present leaves empty folds and the
    # run dies later with "DataBackend did not return the queried rows
    # correctly". The same cap applies to the rarest class on an ungrouped
    # task. This mirrors cap_folds() in R/tabflux_evaluation_helpers.R.
    fs_group_count <- if (length(task_train$col_roles$group))
      length(unique(task_train$groups$group)) else NA_integer_
    fs_class_min <- min(table(task_train$truth()))
    fs_folds <- max(2L, min(5L, if (is.na(fs_group_count)) as.integer(fs_class_min) else fs_group_count))
    if (fs_folds < 5L) {
      message("Feature-selection resampling reduced to ", fs_folds,
              " folds (", if (is.na(fs_group_count)) "rarest class" else "number of groups", ").")
    }
    fs_resampling <- rsmp("cv", folds = fs_folds)
    fs_resampling$instantiate(task_train)

    # Prefilter by information gain (how much knowing a taxon's abundance
    # reduces uncertainty about the class) so RFE starts from at most a few
    # thousand candidates. Computed once on the whole training task, not
    # inside each CV fold; the budget comes from the sample size.
    fs_prefilter_max <- make_fs_prefilter_budget(
      p = task_train$ncol - 1L,
      n = task_train$nrow
    )

    fs_prefilter <- flt("information_gain")
    fs_prefilter$calculate(task_train)
    prefilter_scores <- sort(fs_prefilter$scores, decreasing = TRUE, na.last = NA)
    prefilter_feats <- head(names(prefilter_scores), fs_prefilter_max)
    task_train$select(prefilter_feats)
    if (!is.null(task_test)) task_test$select(prefilter_feats)  # keep train/test feature sets aligned
    
    fs_subset_sizes <- make_fs_subset_sizes(
      start = length(prefilter_feats),
      stop = n_features
    )
    
    # recursive = FALSE: importance is computed once on the full candidate
    # set and the ladder is walked down from it, instead of refitting and
    # re-ranking at every step (much faster on thousands of taxa).
    rfe = fs(
      "rfe",
      n_features = n_features,
      subset_sizes = fs_subset_sizes,
      recursive = FALSE
    )
    
    message(
      "Applied information-gain prefilter before RFE: keeping ",
      length(prefilter_feats), " of ", n_candidates,
      " features; subset sizes = ",
      paste(fs_subset_sizes, collapse = ", ")
    )
  } else {
    # Ensemble mode: classic recursive RFE, dropping 20% of the remaining
    # taxa per step and re-ranking after each fit.
    rfe = fs(
      "rfe",
      n_features = n_features,
      feature_fraction = 0.8,
      recursive = TRUE
    )
  }
  
  if (fs_method == "ensemble") {
    # Ensemble feature selection (EFS): 50 random 80% subsamples of the
    # training data; on each, every learner runs its own RFE with 5-fold
    # inner CV. Taxa that keep being selected across subsamples and learners
    # are the stable signal; those picked by one learner on one draw are not.
    fs_init_resampling <- rsmp("subsampling", repeats = 50, ratio = 0.8)
    fs_init_resampling$instantiate(task_train)
    
    # inner_measure (classif.ce = plain error rate) drives the RFE steps
    # inside each subsample; measure (balanced accuracy) scores each finished
    # run for the Pareto front and the vote weights below. The two may differ:
    # classif.ce is taken from the mlr3 gallery example linked above, and
    # measure is balanced accuracy, TabFlux's headline metric, where the
    # example uses plain accuracy. Both are fixed choices.
    # store_benchmark_result = FALSE: drop every fold's models and predictions
    # (50 subsamples x 4 learners x 5 folds); only the selected taxa sets and
    # their scores are used below.
    efs = ensemble_fselect(
      fselector = rfe,
      task = task_train,
      learners = learners,
      init_resampling = fs_init_resampling,
      inner_resampling = rsmp("cv", folds = 5),
      inner_measure = msr("classif.ce"),
      measure = msr("classif.bacc"),
      terminator = trm("none"),
      callbacks = list(
        rpart = list(one_se_clbk),
        rf = list(one_se_clbk),
        svm  = list(one_se_clbk, svm_rfe),
        xgboost  = list(one_se_clbk, xgb_clbk)
      ),
      store_benchmark_result = FALSE
    )
    
    # efs$result: one row per learner x subsample, with the selected taxa,
    # how many, and the balanced accuracy they reached. print(efs) shows the
    # subsample, learner and number of taxa of each row.
    print(efs)
    
    # Plots: score per learner, subset size per learner, and the Pareto front
    # = the best accuracy reachable for each number of taxa. The "estimated"
    # version smooths that front with a linear model on 1 / number of taxa.
    print(autoplot(efs, type = "performance", theme = theme_minimal(base_size = 14))) # performance scores of the different learners
    print(autoplot(efs, type = "n_features", theme = theme_minimal(base_size = 14))) # number of features selected by each learner
    print(autoplot(efs, type = "pareto", theme = theme_minimal(base_size = 14))) # Pareto: trade-off between number of features and performance
    print(
      autoplot(
        efs,
        type = "pareto",
        pareto_front = "estimated",
        theme = theme_minimal(base_size = 14)
      ) + scale_color_brewer(palette = "Set1") + labs(title = "Estimated Pareto front")
    ) # estimated Pareto front curve by fitting a linear model with the inverse of the number of selected features
    
    # Knee point of the Pareto front = the number of taxa beyond which adding
    # more buys almost no accuracy. Becomes the committee size below. If the
    # fit finds no knee it falls back to the median subset size across runs.
    kp = efs$knee_points(type = "estimated")
    if (is.na(kp$n_features)) {
      median_feats = median(efs$result$n_features, na.rm = TRUE)
      message("Estimated knee point is NA; using the median feature count = ",
              median_feats)
      n_feat = median_feats
    } else {
      n_feat = kp$n_features
      message("Estimated knee point: ", n_feat, " features")
    }
    
    # Stability: Jaccard overlap between the taxa sets selected in different
    # runs (1 = always the same taxa, 0 = never the same). Low stability
    # means the selection is chasing noise; the values are saved to
    # feature_selection_stability.csv for reporting.
    global_stab = efs$stability("jaccard", global = TRUE) # assess the stability across all resampling iterations and learners
    message("Global stability (Jaccard): ", global_stab)
    per_learner_stab = efs$stability("jaccard", global = FALSE) # or per each learner separately
    print(per_learner_stab) # Jaccard index -> the higher the better
    readr::write_csv(
      data.frame(scope = c("global", names(per_learner_stab)), jaccard = c(global_stab, unname(per_learner_stab))),
      file.path(out_dir, "feature_selection_stability.csv")
    )
    # Stability plot per learner. Inside a function a plot only appears in
    # the report when it is printed explicitly, like the four above.
    print(autoplot(efs, type = "stability", theme = theme_minimal(base_size = 14)) + scale_fill_brewer(palette = "Set1"))
    
    # Consensus ranking by approval voting: each run "approves" the taxa it
    # selected, weighted by that run's performance; the n_feat taxa with the
    # most approvals are the final set.
    consensus_av = efs$feature_ranking(
      method = "av",
      committee_size = n_feat,
      use_weights = TRUE
    )
    print(consensus_av)
    selected_feats = consensus_av$feature
  } else {
    # "simple" mode: random forest RFE, scored by balanced accuracy over the
    # fs_folds CV folds instantiated above. ties_method = "least_features" breaks
    # equal scores in favour of the smaller subset.
    fs = fselect(
      fselector = rfe,
      task = task_train,
      learner = fs_ranger,
      resampling = fs_resampling,
      # With the class-prior correction on, subsets are ranked by the decision rule
      # the models are scored with (MeasureClassifBaccPrior, training helpers; same
      # id, so the one-SE callback is unchanged). Ensemble mode, used only below
      # num_row samples, keeps the plain rule.
      measures = if (isTRUE(prior_correction)) MeasureClassifBaccPrior$new() else msr("classif.bacc"),
      terminator = trm("none"),
      callbacks = list(one_se_clbk),
      ties_method = "least_features"
    )
    
    # Print the one subset the one-SE callback kept and its CV balanced
    # accuracy; every subset tried is in fs$archive.
    # Fewer taxa at near-equal accuracy generalise better on microbiome data.
    print(as.data.table(fs$result)[, .(features, classif.bacc)])
    message(
      "One-SE rule selected ", fs$result$n_features[[1]],
      " features from the smallest subset within one standard error of the best score."
    )
    
    # Extract best features
    selected_feats = fs$result_feature_set
  }
  
  # Shrink both tasks to the selected taxa. From here on tuning, benchmarking
  # and the internal test use only these columns; the external-test chunk
  # aligns its table to task_train$feature_names, so it follows automatically.
  task_train$select(selected_feats)

  # Keep the test task's columns identical to the training task's.
  if (!is.null(task_test)) task_test$select(selected_feats)
  readr::write_csv(
    data.frame(feature = selected_feats),
    file.path(out_dir, "selected_features.csv")
  )

  list(
    selected_feats = selected_feats,
    task_train = task_train,
    task_test = task_test
  )
}
