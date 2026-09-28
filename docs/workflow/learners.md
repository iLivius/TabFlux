# Learners and tuning

## The graph every learner sits behind

Each learner picked in `methods.pick` gets its own mlr3 graph: filters → z-score scaling
→ (class balancing) → learner. The whole graph is tuned together, and it is fitted
inside every resampling fold rather than once on the full data, so no preprocessing
step ever sees a test sample.

| learner | what it is | needs |
|---|---|---|
| `ranger` | random forest: an ensemble of decision trees, each grown on a bootstrap sample and a random subset of features | — |
| `tabpfn` | a transformer pre-trained on synthetic tables (v2.5's default classifier checkpoint is further fine-tuned on real data); the training table is passed as context at prediction time, and its weights are not updated | the Python environment and the model weights; a GPU for reasonable run times (CPU works, much slower) |
| `glmnet`, `kknn`, `svm` | penalised regression, nearest neighbours, support vector machine | — |
| `xgboost` | gradient-boosted trees | — |
| `mlp` | a small feed-forward network through R `torch` | CPU only, and cannot share a run with `tabpfn`: both load a libtorch runtime, and one R session holds one. The container carries the CPU backend; on the conda route install it with `CUDA=cpu Rscript -e 'torch::install_torch()'` |

The template `config.yaml` and the cFMD demo pick `tabpfn` and `ranger`; the full cFMD
run (`config_cfmd_category.yaml`) adds `xgboost`. The others are selected the same way,
through `methods.pick`.

!!! note "Why there is no LDA or naive Bayes"

    Both assume something a taxa table does not provide. Linear discriminant
    analysis estimates one covariance matrix per class and needs more samples
    per class than features; a profile has hundreds to thousands of taxa and
    tens of samples in the rarest class, so it only runs on PCA scores, and
    even then the number of components has to stay below the rarest class.
    Naive Bayes assumes the features are independent given the class, but
    relative abundances sum to a constant, so they are negatively correlated by
    construction; its Gaussian density also fits a zero-inflated distribution
    badly, since most taxa are absent from most samples. Both can be made to
    run only by constraining them until little is left.

## Tuning

| learner | tuner, default / `fast_tuning: true` |
|---|---|
| `glmnet`, `kknn`, `svm` | grid search, resolution 5 / successive halving on row subsamples |
| `tabpfn` | grid search over single-value ranges, so one setting per model generation, see below |
| `ranger` | Hyperband with 3 repetitions / 1 repetition |
| `xgboost`, `mlp` | random search, 80 settings / 40 settings |

**Hyperband** trains many candidate settings cheaply on a small budget, keeps the best
half and doubles their budget, and repeats. For the random forest the budget is the
number of trees, 100 to 1,000, tuned alongside the `mtry` ratio and the sample
fraction. The schedule always runs to the end: a cap that stops inside the first
Hyperband round would leave every forest at the smallest budget.

**XGBoost** is tuned by random search over the learning rate `eta` (0.01–1, log scale),
tree depth (1–20), row and column subsampling, and the L1 and L2 penalties (`alpha`,
`lambda`, 1e-3 to 1e3). The number of boosting rounds is not searched: each fit
early-stops on a 20 % validation slice once log-loss has not improved for 10 rounds, up
to 1,000, and the final model is refit on every row for the mean of the inner folds'
stopping rounds. Below `eta` = 0.01, 1,000 rounds cannot move the model far from its
starting score; a log-scale range reaching down to 1e-4 would spend half the draws there.

**The MLP** is tuned by random search over width, depth, dropout (0.1–0.5) and learning
rate (1e-4 to 1e-2); weight decay is fixed at 0.01. Every network is a stack of equal-width
layers. Under `fast_tuning` the search is 40 settings over width 32–256 and depth 1–2;
otherwise 80 settings over width 32–512 and depth 1–3. Its epoch count is not searched:
each fit early-stops on log-loss over a 20 % validation slice of whole groups, and the
final model is refit on every row for the mean of the inner folds' stopping epochs.

**TabPFN** has nothing to search: every range holds a single value, so the grid collapses
to one setting and tuning is one fit per inner fold. Which setting depends on the model
generation (`runtime.tabpfn.model_version`): four estimators and a softmax temperature of
0.9 for v2.x; for 3.x, eight estimators (the count stored in the 3.5 checkpoint) with the
temperature left unset, so the library reads it from the checkpoint (1.0 for 3.5).

`execution.term_min` is a wall-clock cap used by the SVM only; every other learner stops
when its own schedule is done. `preprocessing.fast_tuning` switches to the cheaper
tuners and is forced off below 500 samples or 25 features, where the shortcuts would
save nothing.

### Two measures and one rule

Candidates are scored on balanced accuracy and log-loss at the same time. The tuning
archive returns the settings that no other setting beats on both counts, and
`execution.tuning_selection` picks one of them:

- `one_se` (default): among the settings whose balanced accuracy is within one standard
  error of the best, the one with the lowest log-loss.
- `max_bacc`: the highest balanced accuracy outright, log-loss breaking ties.

### The resampling inside the tuning

`evaluation.inner` names the scheme used to score candidate settings inside a fold:
`auto` picks one per learner, `cv`, `repeated_cv` or `loo` force it.

With `dataset.group` set, whole groups stay together whichever scheme runs. The inner
loop only has to **rank** the candidates — its scores are never reported:

- at most `max(inner_folds, 10)` groups: leave-one-group-out, one refit per group;
- more than that: k-fold over the groups, `evaluation.inner_folds` of them.

The cFMD category analysis has 57 datasets, so it ranks candidates on five folds of whole
datasets. Leave-one-group-out there would mean 57 refits per evaluated setting, about
2,000 fits for one tuning of the random forest (35 Hyperband evaluations).

Without a grouping column: k-fold (`inner_folds`), or repeated k-fold
(`inner_repeats × inner_folds`) for cheap learners below 500 samples. The fold count drops
to the size of the rarest class when that is smaller than `inner_folds`, so no fold loses
a class and leaves balanced accuracy undefined.

### Parallelism

`execution.num_threads` (`auto` = all cores) is what one learner may use internally;
`execution.num_jobs` is how many R processes tune in parallel (`auto` = one worker per
inner fold, or per group when `dataset.group` is set, capped by the cores). TabPFN
always runs in one process, on the GPU when one is visible; the R learners are still
tuned with `num_jobs` workers when TabPFN is in the same run.

## What is cached, and how to retune

A re-render reuses the saved tuning archive and model in the run folder. To retune from
scratch, delete `<method>_tuned_instance.rds` and `<method>_tuned_learner.rds`, or bump
`dataset.version`. Deleting only the learner file refits the best setting from the saved
archive without a new search. Give every test run its own version, or a later full run
will silently reuse the cheap models.

`preprocessing.learner_fallback: true` runs each fit inside a safety net: an error is
logged, a majority-class stand-in scores that setting, and the run carries on with a
warning that counts the failed tuning evaluations. TabPFN always runs inside this safety
net, and any failed tuning evaluation of TabPFN stops the run. If no tuning evaluation of
a learner produces a score, there is no tuned model to refit: the run stops and names
the learner.
