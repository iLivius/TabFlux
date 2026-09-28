# Helpers for building, tuning, and saving the learners used by the notebook.
#
# Place in the pipeline (analysis/tabflux.qmd, "Train models" chunk):
# task_train (depth-normalised taxa table, after optional feature selection)
# and preprocessing_pipe (robustify / filters / scaling / SMOTE, from the
# preprocessing chunk) come in. train_methods() tunes each selected method with
# an inner cross-validation, refits the best setting on all of task_train and
# saves <method>_tuned_learner.rds in save_dir: the final models, used on the
# test sets and for SHAP. The Benchmark chunk's outer folds do not score these
# files: each fold re-tunes (nested) or refits (non-nested) its own copy via
# run_outer_evaluation(). Nothing here scores a model.
#
# Terms used below (mlr3 vocabulary):
#   learner        - a classifier wrapper, e.g. lrn("classif.ranger").
#   pipeop / graph - one preprocessing step / a chain of steps ending in a
#                    learner. as_learner(graph) makes the chain act as one
#                    learner, so filters and SMOTE are refit inside every fold
#                    and never see that fold's test data.
#   hyperparameter - a model setting fixed before training (number of trees,
#                    features per split, learning rate); tuning = trying
#                    values and keeping the best-scoring ones.
#   search space   - the ranges of hyperparameters the tuner may try.
#   budget parameter - a knob (subsample fraction, number of trees) that makes
#                    a fit cheaper or dearer; Hyperband-style tuners try many
#                    settings at low budget and promote only the good ones.
#   R6 object      - mlr3 learners/tasks are references: changing one changes
#                    every variable pointing at it, hence clone(deep = TRUE).

# Build the base learner objects for the selected methods and apply the
# execution constraints some of them carry.
# Input: `methods`, the named list from the notebook (key = short id such as
# "ranger", value = display name), plus seed/num_jobs from the config.
# Output: a list with
#   learners         - one untuned mlr3 learner per method, all predicting
#                      class probabilities (needed for logloss/AUC).
#   num_jobs         - forced to 1 for TabPFN, see below.
#   force_sequential - TRUE tells the notebook to stay on future::plan(sequential).
# The five R-only learners (glmnet, kknn, ranger, svm, xgboost) are always
# built, which is cheap; mlp or tabpfn is added only when picked.
# train_methods() only touches the ones listed in `methods`.
build_classification_learners <- function(methods, seed, num_jobs) {
  learners <- list(
    glmnet = lrn("classif.glmnet", predict_type = "prob"),
    kknn = lrn("classif.kknn", predict_type = "prob"),
    ranger = lrn("classif.ranger", predict_type = "prob"),
    svm = lrn("classif.svm", type = "C-classification", predict_type = "prob"),
    # booster: "gbtree" is xgboost's own default, but mlr3 gates
    # colsample_bylevel and colsample_bynode on it with a dependency that is
    # only satisfied when the value is SET, not merely defaulted. Tuning either
    # column-sampling parameter without this line dies when mlr3 reassembles
    # the tuned learners to score them - hours in, after the tuning is done.
    xgboost = lrn("classif.xgboost", predict_type = "prob", booster = "gbtree")
  )

  force_sequential <- FALSE
  resolved_num_jobs <- num_jobs

  # The torch-backed MLP (mlr3torch): a small feed-forward neural net.
  #   validate = NULL here; configure_final_learner() sets it to 20%.
  #   measures_valid - mlr3torch's early stopping watches the FIRST measure
  #     only. Log-loss goes first: it is defined per row, so it does not care
  #     which classes the validation slice happens to contain. Balanced
  #     accuracy does: the slice is whole groups (set_validate in
  #     configure_final_learner keeps the group role) and most cFMD studies
  #     carry a single class, so a slice often lacks one and bacc silently
  #     averages over the rest.
  #   patience / min_delta / eval_freq - stop after 10 epochs without any
  #     improvement, checked every epoch. The epoch count itself is tuned
  #     internally (the "internal_tuning" tag in get_learner_search_params)
  #     and reused for the final refit in train_methods().
  #   num_threads = 1 - on nets this small more torch threads buy nothing
  #     (20 epochs of a 1 x 256 net on 600 x 175 samples: 0.9 s with one
  #     thread, 1.1 s with eighteen), and the tuning already runs num_jobs
  #     fits in parallel, so extra threads per fit only crowd the cores.
  #   jit_trace = TRUE - compile the network once for faster training.
  # The `else if` below keeps MLP and TabPFN apart: torch and the
  # reticulate/Python stack clash in one R session. The notebook already stops
  # with an error if both are selected.
  if ("mlp" %in% names(methods)) {
    learners <- c(
      learners,
      mlp = lrn(
        "classif.mlp",
        activation = nn_relu,
        loss = t_loss("cross_entropy"),
        # CPU on purpose: the image carries the CPU build of libtorch, so a
        # second CUDA runtime never loads beside the Python one TabPFN uses.
        device = "cpu",
        optimizer = t_opt("adamw"),
        # AdamW's decoupled decay, fixed: the second regulariser next to the
        # tuned dropout. Set here rather than left to the optimiser's default
        # so that the value is visible.
        opt.weight_decay = 0.01,
        measures_valid = msrs(c("classif.logloss", "classif.bacc")),
        measures_train = msrs(c("classif.logloss", "classif.bacc")),
        # "history" feeds internal_valid_scores, which the refit reads. "progress"
        # only prints, a block per validation round: with eval_freq 1 and up to 200
        # epochs it would bury every MLP run in the report and the console log,
        # so it is not attached.
        callbacks = list(t_clbk("history")),
        validate = NULL,
        eval_freq = 1,
        predict_type = "prob",
        patience = 10,
        min_delta = 0,
        num_threads = 1L,
        seed = seed,
        jit_trace = TRUE
      )
    )
  # TabPFN is pre-trained: it takes the training table and the samples to
  # classify as one input and predicts directly, with no training run of its
  # own. ignore_pretraining_limits skips TabPFN's size checks (TabPFN-3.5:
  # 1,000,000 rows and 20,000 features; v2.5: 50,000 rows and 2,000
  # features) and its CPU row cap (5,000 rows for 3.5, 1,000 for v2.x), so a
  # larger table runs instead of stopping with an error. The class limit
  # (160 for 3.5, 10 for v2.5) still applies.
  # device "auto" uses a GPU if visible. balance_probabilities is OFF: it
  # divides TabPFN's probabilities by the training class frequencies, a
  # correction no other learner receives, which would make the comparison
  # unequal. TabFlux applies that correction to every learner's decision
  # instead (evaluation.prior_correction, see apply_prior_correction()).
  # It runs through reticulate and Python, which is less reliable under
  # parallel tuning, so it stays single-process: num_jobs is forced to 1 for
  # the notebook's own plan, overriding the config value.
  # train_methods() still tunes the R learners with the requested workers
  # (its tuning_workers argument).
  } else if ("tabpfn" %in% names(methods)) {
    force_sequential <- TRUE
    resolved_num_jobs <- 1L

    learners <- c(
      learners,
      tabpfn = lrn(
        "classif.tabpfn",
        ignore_pretraining_limits = TRUE,
        device = "auto",
        balance_probabilities = FALSE,
        predict_type = "prob",
        n_jobs = 1
      )
    )
  }

  list(
    learners = learners,
    num_jobs = resolved_num_jobs,
    force_sequential = force_sequential
  )
}

# Pick the xgboost evaluation metrics that match the target type.
# Input: dataset_attr ("binary" or "multi-class"), set in the notebook's
# "pre-process" chunk from the number of target levels.
# Output: metric names xgboost itself understands. prepare_method_learner()
# uses them for early stopping on the validation split: stop adding trees when
# error/logloss on held-back rows stops improving. Only xgboost uses this;
# every other learner is scored with mlr3 measures.
get_eval_metrics <- function(dataset_attr) {
  if (dataset_attr == "binary") {
    c("error", "logloss")
  } else if (dataset_attr == "multi-class") {
    c("merror", "mlogloss")
  } else {
    stop("Unsupported dataset_attr for xgboost evaluation metrics: ", dataset_attr)
  }
}

# Task-level counts used later to choose resampling schemes and
# hyperparameter ranges.
# Input: task_train (the training split after normalisation and any feature
# selection). task$data() returns target + feature columns only, so the
# grouping column is not counted as a feature. Output list:
#   min_count - size of the rarest class; decides whether inner_folds folds are
#               possible (choose_tuning_resampling) and caps kknn's k
#               (get_learner_search_params).
#   num_feat  - number of taxa; passed on to get_learner_search_params(),
#               which does not use it to set any range.
#   num_obs   - number of training samples; bounds kknn's k and picks the
#               inner resampling (choose_tuning_resampling).
get_training_task_stats <- function(task_train, target_col = "target") {
  task_data <- task_train$data()
  list(
    min_count = task_data %>%
      dplyr::count(.data[[target_col]]) %>%
      dplyr::arrange(n) %>%
      dplyr::slice_head(n = 1) %>%
      dplyr::pull(n),
    num_feat = ncol(task_data) - 1L,
    num_obs = nrow(task_data)
  )
}

# Choose an inner resampling scheme the dataset can support: how each
# candidate hyperparameter setting is scored during tuning. (The outer
# benchmark loop is chosen in the Benchmark chunk.)
#   Grouped ("group" column in tab) - whole groups stay together, so tuning
#     rewards settings that transfer between groups (studies, sites), not just
#     between samples. Up to max(inner_folds, 10) groups: rsmp("loo") on a
#     task whose group column has the "group" role, i.e. leave-one-group-out;
#     above that, k-fold over the groups (inner_folds folds).
#   rare class (min_count <= inner_folds) - fewer folds, so every fold still
#     holds both classes; a fold missing one class leaves balanced accuracy
#     undefined.
#   big data or expensive learners (mlp, tabpfn, xgboost) - plain k-fold.
#   everything else - repeated k-fold, more stable scores for cheap models.
# Output: an mlr3 Resampling, handed to ti() in train_methods().
choose_tuning_resampling <- function(tab, min_count, inner_folds, inner_repeats, num_obs, method) {
  if ("group" %in% names(tab)) {
    # Grouped task: the inner loop must keep whole groups together, and mlr3
    # does that for any strategy once the task carries the group role. WHICH
    # strategy is a cost decision, because the inner loop only has to RANK the
    # candidate settings - its scores are never reported.
    #
    # Leave-one-group-out refits once per group. With many groups (e.g. the
    # 57 cFMD datasets) that multiplies the tuning cost, and k-fold over the
    # groups ranks the settings the same way for a fraction of the work.
    n_groups <- length(unique(stats::na.omit(tab$group)))
    if (n_groups <= max(as.integer(inner_folds), 10L)) rsmp("loo")
    else rsmp("cv", folds = as.integer(inner_folds))
  } else if (min_count <= inner_folds) {
    rsmp("cv", folds = max(2L, as.integer(min_count)))
  } else if (num_obs >= 500 || method %in% c("mlp", "tabpfn", "xgboost")) {
    rsmp("cv", folds = inner_folds)
  } else {
    rsmp("repeated_cv", repeats = inner_repeats, folds = inner_folds)
  }
}

# Apply per-method settings before the learner enters the preprocessing graph.
# Input: a deep copy of one base learner from build_classification_learners().
#   tabpfn  - encapsulate = run train/predict in a separate R process (callr),
#             so a crash on the Python side cannot kill the notebook. If it
#             does crash, the "featureless" fallback - a dummy model that
#             ignores the taxa and always predicts the majority class - gives
#             the tuning archive a (bad) score instead of an error.
#   xgboost - early stopping: watch eval_metrics on the validation split
#             (set_validate() in configure_final_learner) and stop adding
#             trees after 10 rounds without improvement. nrounds in the search
#             space is therefore an upper limit, not the number used.
# Output: the same learner, modified in place (R6 reference, see top of file).
# Next step: build_training_graph().
prepare_method_learner <- function(method, base_learner, eval_metrics) {
  if (method == "tabpfn") {
    base_learner$encapsulate(
      "callr",
      fallback = lrn("classif.featureless", predict_type = "prob")
    )
  } else if (method == "xgboost") {
    base_learner$param_set$set_values(
      eval_metric = eval_metrics,
      early_stopping_rounds = 10
    )
  }

  base_learner
}

# Add the step between preprocessing and the learner: row subsampling for the
# cheap learners in fast tuning.
# Input: preprocessing_pipe from the notebook (robustify, variance/correlation
# or info-gain filter, scaling, optional SMOTE) and the prepared learner.
#   po("subsample") - in fast-tuning mode the fraction of training rows is the
#     budget parameter (subsample.frac in the search space): cheap learners are
#     compared on 10% of the rows first, only the winners on all rows.
# Output: an mlr3 Graph; train_methods() wraps it with as_learner() so the
# whole chain is refit inside every resampling fold.
build_training_graph <- function(method, base_learner, preprocessing_pipe, fast_tuning) {
  # use_groups = FALSE, stratify = TRUE: po("subsample") honours the group role
  # by default, so on a grouped task a 10 % budget would draw whole studies -
  # e.g. two of twenty, possibly both of one class, which cannot be scored. The
  # budget has to be a class-balanced fraction of ROWS for the low rungs to
  # rank anything.
  sub <- po("subsample", use_groups = FALSE, stratify = TRUE)
  if (fast_tuning && method %in% c("glmnet", "kknn", "svm")) {
    preprocessing_pipe %>>% sub %>>% base_learner
    } else {
    preprocessing_pipe %>>% base_learner
  }
}

# Hyperparameter ranges for each learner. In fast-tuning mode the search space
# also includes budget parameters.
#
# Output: a named list of paradox definitions (p_int/p_dbl/p_fct), each named
# after the pipeop it belongs to inside the graph ("classif.ranger.mtry.ratio",
# "subsample.frac"). train_methods() merges them with the
# notebook's preprocessing parameters (filter fractions, SMOTE K) into one
# search space, so preprocessing and model are tuned together.
# Conventions:
#   logscale = TRUE   - sample on a log scale; a 1e-4..1e4 range would
#                       otherwise be dominated by the large values.
#   tags = "budget"   - the cheap-to-expensive knob for Hyperband /
#                       successive halving: subsample fraction for cheap
#                       learners, trees for ranger.
#   tags = "internal_tuning" (mlp epochs, xgboost nrounds) - not sampled by
#                       the tuner; the learner's own early stopping on the
#                       validation split finds the count, and `aggr`
#                       averages those counts across folds for the final refit.
#   depends = quote() - a parameter only exists for some values of another
#                       (SVM gamma only for polynomial/radial kernels).
#   tabpfn            - single-value ranges: TabPFN has no real
#                       hyperparameters, so "tuning" it is one fit per fold,
#                       kept in this code path for uniformity.
#   ranger num.trees  - the Hyperband budget, 100 to 1000 trees. Hyperband
#                       starts each bracket at the smallest budget, and forests
#                       of a few dozen trees give fold scores that are mostly
#                       noise, so the floor is 100. With eta = 2 this gives 35
#                       evaluations per repetition (22 distinct settings, 8 of
#                       them at 125 trees in the widest bracket).
#   xgboost           - random search over the ranges below; nrounds is
#                       internally tuned (early stopping, up to 1,000), not a
#                       budget. eta floor 1e-2: at a smaller learning rate
#                       1,000 rounds cannot move the model far from its
#                       starting score, and a log-scale draw from 1e-4 would
#                       put half the settings there.
#   mlp               - one width repeated n_layers times, see
#                       mlp_search_params(); fast mode searches a smaller box.
# The fast and full blocks below otherwise share these ranges; edit both.
#
# TabPFN's one fixed setting depends on the model generation in use
# (TABPFN_MODEL_VERSION, set by the notebook from runtime.tabpfn.model_version
# before Python starts):
#   v2.x  – n_estimators 4, softmax_temperature 0.9, fixed so that v2.5 runs
#           stay reproducible;
#   v3.x  – n_estimators 8 (the value stored in the 3.5 checkpoint) and NO
#           temperature: tabpfn (>= 9.0) reads 1.0 from the checkpoint when
#           the parameter is unset, and its docs warn against carrying 0.9
#           over from older code.
tabpfn_search_params <- function(model_version = Sys.getenv("TABPFN_MODEL_VERSION", unset = "v3.5")) {
  if (grepl("^v?3", tolower(model_version))) {
    list(classif.tabpfn.n_estimators = p_int(lower = 8, upper = 8))
  } else {
    list(
      classif.tabpfn.n_estimators = p_int(lower = 4, upper = 4),
      classif.tabpfn.softmax_temperature = p_dbl(lower = 0.9, upper = 0.9)
    )
  }
}

# The MLP search space: one architecture family (constant-width stacks, one
# dropout rate) in both modes; the mode changes how hard it is searched, not
# what is searched. Random search, not Hyperband: Hyperband promotes settings
# that score well at a low budget, and neither width (a 512-unit net costs 30 %
# more than a 32-unit one here, and their rankings do not agree) nor batch size
# (a larger batch is FEWER updates, i.e. cheaper) is a budget in that sense.
#   fast   - 40 settings over width 32-256, depth 1-2: 40 draws over a smaller
#            box cover it better, and the corners left out cannot work at this
#            size (512 x 3 is 617k parameters on ~700 training rows).
#   normal - 80 settings over width 32-512, depth 1-3.
# lr capped at 1e-2 (every setting above it in the cFMD archives was badly
# calibrated and none was ever chosen). Weight decay is not searched: AdamW's
# decoupled decay is fixed at 0.01 in the learner definition, dropout is the
# tuned regulariser. epochs is tuned internally by early stopping (see the
# learner definition) and its inner-fold mean is what the final refit trains
# for.
mlp_search_params <- function(fast_tuning = FALSE) {
  list(
    classif.mlp.neurons = p_int(32, if (fast_tuning) 256L else 512L, logscale = TRUE),
    classif.mlp.n_layers = p_int(1, if (fast_tuning) 2L else 3L),
    classif.mlp.batch_size = p_int(32, 32),
    classif.mlp.epochs = p_int(
      upper = 200,
      tags = "internal_tuning",
      aggr = function(x) as.integer(mean(unlist(x)))
    ),
    classif.mlp.p = p_dbl(0.1, 0.5),
    classif.mlp.opt.lr = p_dbl(1e-4, 1e-2, logscale = TRUE)
  )
}

# The class-prior correction. A learner's predicted category is normally the
# one with the largest probability. On unbalanced classes that decision serves
# plain accuracy: with dairy at two thirds of the samples, dairy wins most close
# calls. For calibrated probabilities the decision that maximises BALANCED
# accuracy - TabFlux's headline metric - is the category with the largest
# probability divided by its frequency in the training data. For tree
# ensembles, whose probabilities are only roughly calibrated, it is an
# approximation, and for very rare classes it also magnifies noise. mlr3 applies exactly that when a prediction's
# threshold is set to the class frequencies; the probabilities themselves are
# not changed, so log-loss and calibration are unaffected.
# Input: the true classes of the TRAINING rows the model was fitted on, and the
#   class names in the prediction's column order.
# Output: named thresholds for PredictionClassif$set_threshold(). A class absent
#   from the training rows gets 1: it is never pushed up (a 0 would let a model
#   that never saw the class predict it everywhere).
class_prior_threshold <- function(train_truth, class_names) {
  freq <- tabulate(factor(train_truth, levels = class_names), nbins = length(class_names)) / length(train_truth)
  freq[freq == 0] <- 1
  stats::setNames(freq, class_names)
}

# Apply the correction to a prediction in place and return it.
# Input: an mlr3 PredictionClassif with probabilities; the true classes of the
#   training rows of the model that made it.
# Used wherever a prediction becomes a label or a score: the outer folds
# (run_outer_evaluation), the internal test set and the external test set.
apply_prior_correction <- function(prediction, train_truth) {
  if (is.null(prediction$prob)) return(prediction)
  # ties_method "first": mlr3's default breaks a tie at random, which makes a label
  # depend on the random-number state; a tie goes to the first class instead.
  prediction$set_threshold(class_prior_threshold(train_truth, colnames(prediction$prob)), ties_method = "first")
  prediction
}

# Balanced accuracy of the corrected decision, as an mlr3 measure, so that the
# TUNER ranks settings by the same rule the outer folds are scored with. It
# keeps the id "classif.bacc": the tuning archive, the one-SE rule and every
# table read that column name. The scoring function is self-contained - base R
# and mlr3measures only - so that a tuning instance saved with saveRDS can be
# rescored after readRDS in a session that has not sourced these helpers
# (archive$best(), resample_result$score() on resume).
MeasureClassifBaccPrior <- R6::R6Class("MeasureClassifBaccPrior",
  inherit = mlr3::MeasureClassif,
  public = list(
    initialize = function() {
      super$initialize(
        id = "classif.bacc",
        range = c(0, 1),
        minimize = FALSE,
        predict_type = "prob",
        properties = c("requires_task", "requires_train_set"),
        packages = "mlr3measures",
        label = "Balanced accuracy, class-prior corrected decision"
      )
    }
  ),
  private = list(
    .score = function(prediction, task, train_set, ...) {
      cls <- levels(prediction$truth)
      y <- task$truth(train_set)
      freq <- tabulate(factor(y, levels = cls), nbins = length(cls)) / length(y)
      freq[freq == 0] <- 1
      p <- prediction$clone(deep = TRUE)
      p$set_threshold(stats::setNames(freq, cls), ties_method = "first")
      mlr3measures::bacc(p$truth, p$response)
    }
  )
)

# The measures the tuner optimises. With the correction on, balanced accuracy
# is the corrected one; log-loss is computed from the probabilities and needs
# no change.
tuning_measures <- function(ids, prior_correction = FALSE) {
  lapply(ids, function(id) {
    if (isTRUE(prior_correction) && identical(id, "classif.bacc")) MeasureClassifBaccPrior$new() else msr(id)
  })
}

get_learner_search_params <- function(method, fast_tuning, num_feat, num_obs, min_count = NULL) {
  # An upper bound computed on the whole training split is not what a learner
  # actually meets: the inner resampling takes a fraction of it, and in fast
  # mode the row-subsample budget takes a fraction of that (the lowest rung is
  # 0.1). kknn then errors with "k must be smaller than the number of
  # observations". k above the rarest class is useless anyway - that class can
  # never win a vote - so both bounds apply.
  sub_floor <- if (isTRUE(fast_tuning)) 0.1 else 1
  rarest <- if (is.null(min_count)) num_obs else as.integer(min_count)
  knn_k_upper <- max(1L, min(
    50L,
    as.integer(rarest * sub_floor) - 1L,
    as.integer(num_obs * 0.6 * sub_floor) - 1L
  ))
  if (fast_tuning) {
    switch(
      method,
      glmnet = list(
        subsample.frac = p_dbl(0.1, 1.0, tags = "budget"),
        classif.glmnet.s = p_dbl(1e-4, 1, logscale = TRUE),   # above 1 every grid point is the intercept-only model
        classif.glmnet.alpha = p_dbl(0, 1)
      ),
      kknn = list(
        subsample.frac = p_dbl(0.1, 1.0, tags = "budget"),
        classif.kknn.k = p_int(1, knn_k_upper, logscale = TRUE)   # see knn_k_upper above
      ),
      mlp = mlp_search_params(fast_tuning = TRUE),
      ranger = list(
        classif.ranger.num.trees = p_int(100, 1000, tags = "budget"),   # floor 100: see the ranger note above
        classif.ranger.mtry.ratio = p_dbl(0.1, 1),
        classif.ranger.sample.fraction = p_dbl(0.1, 1)
      ),
      svm = list(
        subsample.frac = p_dbl(0.1, 1.0, tags = "budget"),
        classif.svm.kernel = p_fct(levels = c("polynomial", "radial", "sigmoid")),
        classif.svm.cost = p_dbl(1e-2, 1e3, logscale = TRUE),
        # On standardised features a gamma far from 1/num_feat makes every
        # kernel entry 0 or 1, i.e. a constant prediction; 1e-4..1e4 spent most
        # of its grid there.
        classif.svm.gamma = p_dbl(
          1e-5,
          1e-1,
          logscale = TRUE,
          depends = quote(classif.svm.kernel %in% c("polynomial", "radial"))
        ),
        classif.svm.degree = p_int(
          1,
          5,
          depends = quote(classif.svm.kernel == "polynomial")
        )
      ),
      tabpfn = tabpfn_search_params(),
      xgboost = list(
        # Internally tuned, not a budget: xgboost early-stops on its own
        # validation slice, so a Hyperband promotion to a higher round cap
        # retrains the same model. mlr3learners already tags nrounds
        # "internal_tuning"; declaring it here with an aggregator makes the
        # inner folds' mean the number the final refit uses.
        classif.xgboost.nrounds = p_int(
          upper = 1000,
          tags = "internal_tuning",
          aggr = function(x) as.integer(mean(unlist(x)))
        ),
        classif.xgboost.eta = p_dbl(1e-2, 1, logscale = TRUE),   # below 1e-2, 1,000 rounds cannot fit a model
        classif.xgboost.max_depth = p_int(1, 20),
        classif.xgboost.colsample_bytree = p_dbl(0.1, 1),
        classif.xgboost.colsample_bylevel = p_dbl(0.1, 1),
        classif.xgboost.lambda = p_dbl(1e-3, 1e3, logscale = TRUE),
        classif.xgboost.alpha = p_dbl(1e-3, 1e3, logscale = TRUE),
        classif.xgboost.subsample = p_dbl(0.1, 1)
      ),
      stop(sprintf("No search space defined for method %s", method))
    )
  } else {
    switch(
      method,
      glmnet = list(
        classif.glmnet.s = p_dbl(1e-4, 1, logscale = TRUE),   # above 1 every grid point is the intercept-only model
        classif.glmnet.alpha = p_dbl(0, 1)
      ),
      kknn = list(
        classif.kknn.k = p_int(1, knn_k_upper, logscale = TRUE)   # see knn_k_upper above
      ),
      mlp = mlp_search_params(fast_tuning = FALSE),
      ranger = list(
        classif.ranger.num.trees = p_int(100, 1000, tags = "budget"),   # floor 100: see the ranger note above
        classif.ranger.mtry.ratio = p_dbl(0.1, 1),
        classif.ranger.sample.fraction = p_dbl(0.1, 1)
      ),
      svm = list(
        classif.svm.kernel = p_fct(levels = c("polynomial", "radial", "sigmoid")),
        classif.svm.cost = p_dbl(1e-2, 1e3, logscale = TRUE),
        # On standardised features a gamma far from 1/num_feat makes every
        # kernel entry 0 or 1, i.e. a constant prediction; 1e-4..1e4 spent most
        # of its grid there.
        classif.svm.gamma = p_dbl(
          1e-5,
          1e-1,
          logscale = TRUE,
          depends = quote(classif.svm.kernel %in% c("polynomial", "radial"))
        ),
        classif.svm.degree = p_int(
          1,
          5,
          depends = quote(classif.svm.kernel == "polynomial")
        )
      ),
      tabpfn = tabpfn_search_params(),
      xgboost = list(
        # Internally tuned, not a budget: xgboost early-stops on its own
        # validation slice, so a Hyperband promotion to a higher round cap
        # retrains the same model. mlr3learners already tags nrounds
        # "internal_tuning"; declaring it here with an aggregator makes the
        # inner folds' mean the number the final refit uses.
        classif.xgboost.nrounds = p_int(
          upper = 1000,
          tags = "internal_tuning",
          aggr = function(x) as.integer(mean(unlist(x)))
        ),
        classif.xgboost.eta = p_dbl(1e-2, 1, logscale = TRUE),   # below 1e-2, 1,000 rounds cannot fit a model
        classif.xgboost.max_depth = p_int(1, 20),
        classif.xgboost.colsample_bytree = p_dbl(0.1, 1),
        classif.xgboost.colsample_bylevel = p_dbl(0.1, 1),
        classif.xgboost.lambda = p_dbl(1e-3, 1e3, logscale = TRUE),
        classif.xgboost.alpha = p_dbl(1e-3, 1e3, logscale = TRUE),
        classif.xgboost.subsample = p_dbl(0.1, 1)
      ),
      stop(sprintf("No search space defined for method %s", method))
    )
  }
}

# Set the final learner's id, validation split, threading and optional
# fallback before tuning starts.
# Input: the GraphLearner (preprocessing + model) from build_training_graph().
#   id <- method         - the learner_id seen later in the benchmark tables;
#                          recode_method_labels() maps it to a display name.
#   keep_results         - keep each pipeop's output after training, so the
#                          Benchmark chunk can report which taxa survived the
#                          filters and the class balance after SMOTE.
#   set_validate(0.2)    - mlp/xgboost hold back 20% of the rows they are
#                          trained on for early stopping (epochs / boosting
#                          rounds). Taken inside each fold, so it never
#                          touches the fold's test rows.
#   set_threads          - ranger/xgboost use several cores per fit; give each
#                          of the num_jobs parallel fits an equal share of
#                          num_threads so they do not fight for cores.
#   encapsulate("callr") - optional (learner_fallback in the config): train in
#                          a separate R process and fall back to the
#                          "featureless" dummy model if a fit errors, so one
#                          bad setting does not abort hours of tuning. TabPFN
#                          already got this on its inner learner in
#                          prepare_method_learner().
# Output: the same learner, modified in place, ready for ti().
configure_final_learner <- function(final_learner,
                                    method,
                                    num_threads,
                                    num_jobs,
                                    learner_fallback) {
  final_learner$id <- method
  final_learner$graph$keep_results <- TRUE

  if (method %in% c("mlp", "xgboost")) {
    set_validate(final_learner, 0.2)
  }

  if (method %in% c("ranger", "xgboost")) {
    set_threads(final_learner, n = ceiling(num_threads / num_jobs))
  }

  if (learner_fallback && method != "tabpfn") {
    final_learner$encapsulate(
      "callr",
      fallback = lrn("classif.featureless", predict_type = "prob")
    )
  }

  final_learner
}

# Pick a tuner to match the expected cost of each learner. The tuner is the
# search strategy over the search space; the terminator (next function) says
# when to stop.
#   grid_search  - try every combination of `resolution` values per parameter
#                  (5^k settings for k parameters); exhaustive, so cheap
#                  learners only. For TabPFN, paradox collapses its
#                  single-value ranges to one grid point at any resolution, so
#                  the grid holds ONE setting = one fit per fold; the
#                  resolution = 3 below changes nothing there.
#   successive_halving / hyperband - start many random settings at low budget
#                  (small subsample, few trees), keep the best 1/eta of them
#                  and raise the budget, repeat; hyperband runs several such
#                  rounds with different starting budgets. Both need the
#                  "budget" tag in the search space.
#   batch_size   - settings evaluated in parallel per batch:
#                  floor(num_threads / num_jobs), the per-worker core share.
# Output: an mlr3tuning Tuner, used as tuner$optimize(instance).
get_tuner_for_method <- function(method, fast_tuning, num_threads, num_jobs) {
  batch_size <- max(1L, floor(num_threads / num_jobs))
  # Random search proposes batch_size settings per round and scores them as one
  # benchmark over the num_jobs workers. With the grid-search value above (1 on
  # an 18-worker box) the MLP's 40 settings would run one after another, each
  # using only its five inner folds' worth of workers. The batch is the
  # largest divisor of the evaluation count (40, or 80: see the terminator)
  # that fits the workers, so the tuner stops at exactly that count: whole
  # batches are always evaluated, and 18 workers with a batch of 18 would run
  # 54 settings for a limit of 40. Each setting is scored on every inner fold,
  # so a batch of 10 still keeps 18 workers busy.
  random_batch <- max(Filter(function(d) d <= max(1L, as.integer(num_jobs)), c(1L, 2L, 4L, 5L, 8L, 10L, 20L, 40L)))

  if (fast_tuning) {
    switch(
      method,
      glmnet = tnr("successive_halving", eta = 2, repetitions = 3),
      kknn = tnr("successive_halving", eta = 2, repetitions = 3),
      mlp = tnr("random_search", batch_size = random_batch),
      svm = tnr("successive_halving", eta = 2, repetitions = 3),
      tabpfn = tnr("grid_search", resolution = 3, batch_size = batch_size),
      ranger = tnr("hyperband", eta = 2, repetitions = 1),
      xgboost = tnr("random_search", batch_size = random_batch)
    )
  } else {
    switch(
      method,
      glmnet = tnr("grid_search", resolution = 5, batch_size = batch_size),
      kknn = tnr("grid_search", resolution = 5, batch_size = batch_size),
      mlp = tnr("random_search", batch_size = random_batch),
      svm = tnr("grid_search", resolution = 5, batch_size = batch_size),
      tabpfn = tnr("grid_search", resolution = 3, batch_size = batch_size),
      ranger = tnr("hyperband", eta = 2, repetitions = 3),
      xgboost = tnr("random_search", batch_size = random_batch)
    )
  }
}

# When to stop tuning, per learner.
# Input: term_min (minutes) from the config.
#   trm("none")     - no extra limit; the tuner stops when its own schedule is
#                     exhausted: grid done (glmnet, kknn, and tabpfn - whose
#                     grid is a single setting), Hyperband finished (ranger).
#   trm("evals")    - a fixed number of settings for the random searches
#                     (mlp, xgboost): random search has no schedule of its own.
#   trm("run_time") - wall-clock cap, SVM only: its training time grows steeply
#                     with sample size. The only use of execution.term_min.
# Hyperband (ranger) gets no evaluation cap on purpose: it scores a whole
# bracket before it checks the terminator, so a cap smaller than the first
# bracket would stop tuning there, with every forest at the lowest budget.
# Output: a Terminator handed to ti() in train_methods().
get_terminator_for_method <- function(method, term_min, fast_tuning = TRUE) {
  switch(
    method,
    glmnet = trm("none"),
    kknn = trm("none"),
    # random search never stops on its own: 40 settings in fast mode, 80 in
    # full mode, each scored on the inner resampling
    mlp = trm("evals", n_evals = if (fast_tuning) 40L else 80L),
    svm = trm("run_time", secs = 60 * term_min),
    tabpfn = trm("none"),
    ranger = trm("none"),
    xgboost = trm("evals", n_evals = if (fast_tuning) 40L else 80L)
  )
}

# Tune each selected method, save the results, and return the fitted learners.
#
# The main loop of the "Train models" chunk. For each method in `methods`:
#   1. copy the base learner, apply per-method settings, wrap it in the
#      preprocessing graph and build the joint search space;
#   2. tune it on task_train with the inner resampling, scoring each setting
#      by train_measures (balanced accuracy, logloss);
#   3. refit the chosen setting on ALL of task_train and save it.
# Inputs come from the notebook: task_train (task chunk), preprocessing_pipe
# and preproc_params (preprocessing chunk), tab (only to detect a grouping column),
# eval_metrics/min_count/num_feat/num_obs (helpers above), the rest from the
# config. save_dir is the per-run, per-taxonomic-level output folder.
# Files written per method in save_dir:
#   <method>_tuned_instance.rds - the tuning archive (every setting tried and
#                                 its scores); lets a rerun skip tuning.
#   <method>_tuned_learner.rds  - the refit model that the Benchmark, test,
#                                 external and SHAP chunks reload.
# Also assigns <method>_tuned_learner into assign_env (the global environment),
# which the Benchmark chunk checks before the files.
# Returns learners_best: only the learners fitted in THIS call. Methods skipped
# because their files existed are missing from it, so the Benchmark chunk
# rebuilds its own list from memory + disk.
# Resume matters because scripts/run_multi_tax_levels.R renders the notebook
# once per taxonomic level; a crash halfway through must not force redoing
# finished methods - hence the file checks below.
train_methods <- function(methods,
                          learners,
                          preprocessing_pipe,
                          task_train,
                          tab,
                          preproc_params,
                          save_dir,
                          train_measures,
                          fast_tuning,
                          learner_fallback,
                          num_threads,
                          tuning_workers = 1L,
                          inner_folds,
                          inner_repeats,
                          term_min,
                          eval_metrics,
                          min_count,
                          num_feat,
                          num_obs,
                          assign_env = .GlobalEnv,
                          selection_rule = c("one_se", "max_bacc"),
                          inner_resampling = NULL,
                          prior_correction = FALSE) {
  # inner_resampling: an mlr3 Resampling used for tuning every method (config
  # evaluation.inner set explicitly). NULL = "auto": pick per method with
  # choose_tuning_resampling() below.
  # tuning_workers: parallel R processes for tuning the R learners (one
  # inner-fold fit per process); TabPFN always stays single-process. See the
  # "Parallel plan per method" block inside the loop. 1 = sequential.
  # selection_rule: which Pareto-front setting gets refit; see the block below.
  selection_rule <- match.arg(selection_rule)
  learners_best <- list()
  timing_rows <- list()   # one row per learner: how long tuning + the refit took
  fast_tuning_enabled <- isTRUE(fast_tuning)

  # fast_tuning arrives already resolved: the notebook decides it once, from
  # the task BEFORE feature selection, so every outer fold and the final model
  # tune under the same protocol. Deciding it here would mean reading each
  # fold's post-selection feature count, which differs from fold to fold.

  for (i in seq_along(methods)) {
    start_time <- Sys.time()
    cat("\n", "##### Method: ", methods[[i]], " ######", "\n")
    cat(" Start time: ", format(start_time, "%Y-%m-%d %H:%M:%S"), "\n")

    # Deep copy so the per-method settings below never leak into the shared
    # learner list (R6 objects are references, see top of file).
    method <- names(methods)[i]
    base_learner <- learners[[method]]$clone(deep = TRUE)
    base_learner <- prepare_method_learner(
      method = method,
      base_learner = base_learner,
      eval_metrics = eval_metrics
    )

    tuning_resampling <- if (!is.null(inner_resampling)) {
      inner_resampling$clone()   # explicit choice from the config, same for every method
    } else {
      choose_tuning_resampling(
        tab = tab,
        min_count = min_count,
        inner_folds = inner_folds,
        inner_repeats = inner_repeats,
        num_obs = num_obs,
        method = method
      )
    }

    learner_pipe <- build_training_graph(
      method = method,
      base_learner = base_learner,
      preprocessing_pipe = preprocessing_pipe,
      fast_tuning = fast_tuning_enabled
    )
    final_learner <- as_learner(learner_pipe)

    # A class that sits in few groups can land entirely inside one inner fold,
    # leaving the other folds' TRAINING parts without it. ranger, kknn, svm
    # and xgboost train anyway and never predict that class; glmnet
    # refuses to fit ("one multinomial or binomial class has 1 or 0
    # observations") and aborts the tuning run unless learner_fallback is on.
    # run_outer_evaluation() reports the same situation for the outer folds;
    # say it here too, because a learner that dies mid-tuning otherwise gives
    # no clue why.
    inner_missing <- tryCatch({
      all_classes <- task_train$class_names
      sum(vapply(seq_len(tuning_resampling$iters), function(k) {
        seen <- unique(as.character(
          task_train$data(rows = tuning_resampling$train_set(k), cols = task_train$target_names)[[1]]
        ))
        length(setdiff(all_classes, seen)) > 0
      }, logical(1)))
    }, error = function(e) 0L)
    if (isTRUE(inner_missing > 0)) {
      warning(sprintf("%s: %d of %d inner folds train without at least one class, so settings are ranked on folds that cannot predict it. Lower evaluation.inner_folds, or group by something the classes are spread over.",
                      method, inner_missing, tuning_resampling$iters), call. = FALSE)
    }

    learner_params <- get_learner_search_params(
      method = method,
      fast_tuning = fast_tuning_enabled,
      num_feat = num_feat,
      num_obs = num_obs,
      min_count = min_count
    )

    # One joint search space: preprocessing knobs from the notebook (filter
    # fractions, SMOTE K) + this learner's own ranges, so e.g. the best
    # filter fraction is chosen per learner rather than once for all.
    search_space <- do.call(ps, c(preproc_params, learner_params))

    print(search_space)

    # ── Parallel plan per method ─────────────────────────────────────────
    # TabPFN must run in one R process: its Python/GPU session cannot be
    # shared with workers. That must not hold the other learners back, so
    # each method sets its own plan: the R learners get `tuning_workers` R
    # processes (future multisession, one inner-fold fit each,
    # ceiling(num_threads / workers) ranger threads), TabPFN stays
    # sequential. The plan goes back to sequential after the loop.
    method_workers <- if (method == "tabpfn") 1L else max(1L, as.integer(tuning_workers))
    if (method_workers > 1) {
      future::plan(future::multisession, workers = method_workers)
    } else {
      future::plan(future::sequential)
    }
    cat(" Parallel workers for", method, ":", method_workers, "\n")

    final_learner <- configure_final_learner(
      final_learner = final_learner,
      method = method,
      num_threads = num_threads,
      num_jobs = method_workers,
      learner_fallback = learner_fallback
    )

    tuner <- get_tuner_for_method(
      method = method,
      fast_tuning = fast_tuning_enabled,
      num_threads = num_threads,
      num_jobs = method_workers
    )
    terminator <- get_terminator_for_method(
      method = method,
      term_min = term_min,
      fast_tuning = fast_tuning_enabled
    )

    instance_file <- file.path(save_dir, paste0(method, "_tuned_instance.rds"))
    learner_file <- file.path(save_dir, paste0(method, "_tuned_learner.rds"))

    # Reuse a tuning run already on disk instead of starting over. Three cases:
    #   archive + fitted learner present -> nothing to do, `next` (the model is
    #     NOT loaded here; the Benchmark chunk reads the .rds itself);
    #   archive present, learner missing -> skip tuning, refit the best setting
    #     from the saved archive below (no new tuning happens). This branch
    #     also catches an archive whose tuning did NOT finish (e.g. a crash
    #     mid-tuning): the best setting found so far is refit as if tuning
    #     were complete, not resumed. Delete <method>_tuned_instance.rds to
    #     tune that method from scratch.
    #   no archive -> tune from scratch. ti() bundles task, learner, inner
    #     resampling, measures, terminator and search space into a tuning
    #     instance; store_benchmark_result keeps every fold score in the
    #     archive, store_models = FALSE keeps the .rds file small.
    if (file.exists(instance_file)) {
      instance <- readRDS(instance_file)
      # $result, not $is_terminated: a terminator of trm("none") leaves
      # is_terminated FALSE even after Hyperband or the grid has run its whole
      # schedule, so a check on it would never pass and every re-render would
      # refit and overwrite the saved model. $result is set by the tuner when it finishes
      # and stays NULL after a crash, which is what "finished" has to mean here.
      if (!is.null(instance$result) && file.exists(learner_file)) {
        next
      } else {
        cat("Refit from saved tuning archive:", method, "\n")
      }
    } else {
      instance <- ti(
        task_train,
        final_learner,
        tuning_resampling,
        tuning_measures(train_measures, prior_correction),
        terminator,
        search_space = search_space,
        store_benchmark_result = TRUE,
        store_models = FALSE
      )
      tuner$optimize(instance)

      # Encapsulation (callr, always on for tabpfn and optional elsewhere via
      # learner_fallback) turns a failed fit into a score from the fallback
      # learner - classif.featureless, which ignores the taxa and answers the
      # majority class. That is a plausible-looking number on an unbalanced
      # problem, so a silent fallback would ship a dummy under the learner's
      # name. Count the failures and say so.
      n_err <- tryCatch(sum(instance$archive$data$errors, na.rm = TRUE), error = function(e) 0L)
      if (isTRUE(n_err > 0)) {
        msg <- sprintf("%s: %d of %d tuning evaluations failed and were scored by the fallback (majority-class) learner.",
                       method, n_err, nrow(instance$archive$data))
        if (method == "tabpfn") stop(msg, " TabPFN is the point of this run; fix the Python side rather than reporting a dummy.")
        warning(msg, call. = FALSE)
      }
      saveRDS(instance, instance_file)
    }

    # Pick one parameter set, refit it on the full training split, and save it.
    # ti() got TWO measures (balanced accuracy and logloss), so archive$best()
    # returns a Pareto front: the settings no other setting beats on both
    # measures at once. Several can tie, so a rule picks the trade-off.
    #
    # Two rules are available (config execution.tuning_selection):
    #   "one_se" (default) – the one-standard-error rule: among the settings
    #       whose balanced accuracy is within one PAIRED standard error of the
    #       best (each candidate's per-fold difference to the best setting on
    #       the same folds, see below), take the one with the LOWEST logloss.
    #       Under leave-one-group-out the fold scores vary a lot, so this
    #       prefers a well-calibrated setting over one that wins on accuracy by
    #       an amount the data cannot separate from noise. The external test
    #       set's probabilities depend on calibration.
    #   "max_bacc" – highest balanced accuracy, logloss as the tie-break.
    #       Sharper on the tuning folds, often overconfident.
    #
    # Either way the chosen setting's FULL parameter list for the graph is
    # looked up by its archive id (uhash) and refit on all of task_train; that
    # refit is what gets benchmarked and used on the test sets. The fold models
    # from tuning are discarded.
    front <- as.data.frame(instance$archive$best())
    if (nrow(front) > 0) {
      best <- which.max(front$classif.bacc)
      if (selection_rule == "one_se") {
        # The SE must be PAIRED. Taking the between-fold SE of the best
        # setting alone measures how much the FOLDS differ, which on grouped
        # data is far more than the settings differ: nearly every row would
        # qualify and the rule would quietly become "lowest logloss on the
        # front". Scoring each candidate against the best on the SAME folds
        # removes the fold-to-fold variation and leaves the difference
        # between settings.
        bacc_measure <- tuning_measures("classif.bacc", prior_correction)[[1]]   # the one the tuner used
        fold_bacc_of <- function(uh) {
          instance$archive$benchmark_result$resample_result(uhash = uh)$score(bacc_measure)$classif.bacc
        }
        best_folds <- fold_bacc_of(front$uhash[best])
        within_one_se <- vapply(seq_len(nrow(front)), function(i) {
          if (i == best) return(TRUE)
          d <- tryCatch(best_folds - fold_bacc_of(front$uhash[i]), error = function(e) NA_real_)
          if (length(d) < 2 || anyNA(d)) return(FALSE)
          se_d <- stats::sd(d) / sqrt(length(d))
          mean(d) <= se_d                      # no worse than the best by more than one paired SE
        }, logical(1))
        candidates <- which(within_one_se)
        chosen <- candidates[order(front$classif.logloss[candidates])][1]
        cat(sprintf(
          " Pareto front: %d setting(s). One-SE rule (paired): best bacc %.3f, %d within one SE; refitting bacc %.3f / logloss %.3f\n",
          nrow(front), front$classif.bacc[best], length(candidates),
          front$classif.bacc[chosen], front$classif.logloss[chosen]
        ))
      } else {
        chosen <- order(-front$classif.bacc, front$classif.logloss)[1]
        cat(sprintf(
          " Pareto front: %d setting(s). Max-bacc rule: refitting bacc %.3f / logloss %.3f\n",
          nrow(front), front$classif.bacc[chosen], front$classif.logloss[chosen]
        ))
      }
      best_params <- instance$archive$learner_param_vals(uhash = front$uhash[chosen])
      # learner_param_vals() returns the setting AS EVALUATED, which for an
      # internally tuned parameter is its cap (epochs = 200), not the value the
      # inner folds settled on. The tuned value (their mean, the `aggr` above)
      # sits in the archive's internal_tuned_values. Put it in, then switch off
      # the machinery that produced it: no validation slice, so the refit uses
      # every row, and no early stopping, so it trains exactly that many epochs
      # instead of a fresh stop on one grouped 20 % holdout. (Refit with
      # epochs = cap instead, the MLP would train past its own best epoch,
      # since mlr3torch keeps the last one.)
      # A "budget" parameter (Hyperband, successive halving) is a fidelity
      # knob, not a hyperparameter: the winning row may have been scored at a
      # low budget and learner_param_vals() carries that budget into the refit,
      # e.g. a forest of 125 trees, or a cheap learner fitted on a fraction of
      # the rows. Refit at the top of the range instead - more trees never
      # hurt a forest, and a full sample is what the model should ship with.
      budget_ids <- intersect(instance$search_space$ids(tags = "budget"), names(best_params))
      for (b in budget_ids) {
        top <- instance$search_space$upper[[b]]
        if (identical(instance$search_space$class[[b]], "ParamInt")) top <- as.integer(top)
        if (!isTRUE(all.equal(best_params[[b]], top))) {
          cat(sprintf(" Refit at the top budget: %s = %s (tuned at %s)\n", b, format(top), format(best_params[[b]])))
        }
        best_params[[b]] <- top
      }

      tuned <- if ("internal_tuned_values" %in% names(front)) front$internal_tuned_values[[chosen]] else NULL
      if (!is.null(best_params) && length(tuned)) {
        best_params[names(tuned)] <- tuned
        # The MLP's early stopping is its own machinery, not mlr3's internal
        # tuning, so disable_internal_tuning() below does not reach it.
        for (pn in c("patience", "measures_valid")) {
          id <- paste0("classif.", method, ".", pn)
          if (id %in% final_learner$param_set$ids()) {
            best_params[[id]] <- if (pn == "patience") 0L else list()
          }
        }
        cat(sprintf(" Refit with tuned %s\n", paste(names(tuned), "=", unlist(tuned), collapse = ", ")))
      }
      if (!is.null(best_params)) {
        final_learner$param_set$values <- as.list(best_params)
        if (length(tuned)) {
          # Switch off what produced the tuned value: no validation slice, so
          # the refit uses every row, and no early stopping, so it runs for
          # exactly the number the inner folds settled on. For xgboost
          # disable_internal_tuning() also clears early_stopping_rounds.
          set_validate(final_learner, NULL)
          try(final_learner$param_set$disable_internal_tuning(names(tuned)), silent = TRUE)
        }
        final_learner$train(task_train)

        # Marshal mlr3torch models before saving, then print the best network
        # topology for the record. Marshalling converts the torch network,
        # which lives in C++ memory and cannot be saved by saveRDS, into a
        # plain R object; the Benchmark chunk calls unmarshal() after loading.
        if (method == "mlp") {
          final_learner$marshal()
          chosen_x <- front$x_domain[[chosen]]
          cat(
            "Refit n_layers:", chosen_x$classif.mlp.n_layers, "\n",
            "Refit neurons: ", chosen_x$classif.mlp.neurons, "\n",
            "Balanced accuracy:", front$classif.bacc[chosen], "\n",
            "Logloss:", front$classif.logloss[chosen], "\n"
          )
        }

        saveRDS(final_learner, learner_file)
      } else {
        # The chosen row carries no parameter values, so there is no setting
        # to refit. Stop rather than go on with an untuned learner.
        stop(sprintf(
          "%s: tuning produced no usable setting (the chosen row of the tuning archive has no parameter values), so there is no tuned model to refit. Delete %s to tune %s again.",
          method, instance_file, method
        ), call. = FALSE)
      }
    } else {
      # An empty Pareto front means no tuning evaluation produced a score:
      # every setting tried failed. Refitting nothing and moving on would ship
      # an UNTUNED learner under this method's name - the Benchmark chunk would
      # train it with its default parameter values, and the tables would look
      # normal. Stop the run instead, naming the method.
      stop(sprintf(
        "%s: every tuning evaluation failed, so the tuning archive holds no scored setting and there is no tuned model to refit. Check the errors printed above for %s, fix the cause, then delete %s to tune it again.",
        method, method, instance_file
      ), call. = FALSE)
    }

    # Publish the refit model two ways: as <method>_tuned_learner in the
    # global environment (what the Benchmark chunk looks for first) and in the
    # returned list. Only reached after a successful refit: both failure
    # branches above stop the run.
    assign(paste(method, "tuned", "learner", sep = "_"), final_learner, envir = assign_env)
    learners_best[[method]] <- final_learner

    end_time <- Sys.time()
    cat(" End time:", format(end_time, "%Y-%m-%d %H:%M:%S"), "\n")
    time_diff <- difftime(end_time, start_time, units = "secs")
    if (time_diff < 60) {
      cat(" Time taken for algorithm", method, ":", time_diff, "seconds\n")
    } else {
      cat(" Time taken for algorithm", method, ":", round(time_diff / 60, 2), "minutes\n")
    }
    timing_rows[[method]] <- data.frame(
      method = method,
      seconds = round(as.numeric(time_diff), 1),
      started = format(start_time, "%Y-%m-%d %H:%M:%S"),
      finished = format(end_time, "%Y-%m-%d %H:%M:%S"),
      stringsAsFactors = FALSE
    )
  }

  # Wall-clock per learner for this call, next to the learners it produced. The
  # notebook gathers the copies from the run root (final models) and every
  # outer_fold_XX/ (nested folds) into metrics/timings.csv, so the cost of a
  # run is a table rather than something to scrape out of the report.
  if (length(timing_rows) > 0) {
    readr::write_csv(do.call(rbind, timing_rows), file.path(save_dir, "timings.csv"))
  }

  # Back to one process: the caller's own plan (the notebook stays sequential
  # while TabPFN is in the run) must not inherit the workers.
  future::plan(future::sequential)

  learners_best
}
