# Evaluation design

Four choices, all in the `evaluation` block of the config.

## 1. Is there a test set?

`test_split` reserves part of the input *before* feature selection, tuning and the
outer folds see anything. With a grouping column set it reserves **whole groups**;
without one it draws a class-stratified sample. It is scored once, by the final
models, exactly like an external dataset.

`0` means none. On a few hundred samples a fifth is a test set of fifty or so, which
carries an uncertainty of roughly ±0.07 on balanced accuracy: too noisy to separate two
designs, and it withholds data from the model as well. Resampling scores every sample
instead.

## 2. How is the training data scored?

| `outer` | folds | when |
|---|---|---|
| `cv` / `repeated_cv` | `outer_folds` (× `outer_repeats`) | one population, exchangeable samples |
| `subsampling` | `outer_repeats` random splits | a cheaper middle ground |
| `loo` | one per sample | very small data |
| **`lodo`** | **one per group** | **samples come from several studies or sites** |

With `dataset.group` set, *every* strategy works on whole groups, because mlr3 keeps a
group together. So `cv` with ten folds over a hundred datasets is grouped
cross-validation, and `lodo` is its extreme case.

The fold count is capped whatever you ask for: never more folds than there are
groups on a grouped task, or than the rarest class has samples on an ungrouped
one, and never fewer than two.

### Choosing between them

**The folds must mimic how the model will meet new data**, which is what
[grouping](grouping.md#choosing-in-one-rule) decides. Random folds put samples of one
study on both sides of the split, so the model is partly scored on what it learned about
that study: its sequencing depth, its protocol, its sampling. The estimate is then
optimistic for a study that contributed nothing to training, and grouped folds are the
ones that measure that case.

!!! warning "Leave-one-dataset-out is not always available"

    It needs the held-out group to hold more than one of the classes being
    predicted. In the cFMD database, 96 of 109 datasets hold a single class — a
    cheese study contains only dairy samples — so holding one out gives a fold that
    measures one class only: balanced accuracy reduces to that class's recall, and
    ranking metrics are undefined. The fix is grouped cross-validation with several
    datasets per fold, or restricting the run to datasets that are internally mixed.
    The [case study](../cfmd/running.md) does the former: five grouped folds over 57
    datasets, whole studies kept together, several categories in every fold.

## 3. Nested, or not

`nested: true` repeats feature selection and tuning **inside every fold**: each
fold selects from the full feature space, on its training part alone, and tunes on
the same. `false` runs them once on everything and lets the folds only refit and
score.

The non-nested shortcut is optimistic: the held-out samples already influenced which
features and settings exist, so a fold handed a shortlist selected on all the training
data can only re-rank it.

On the [case study](../cfmd/results.md#which-taxa) the selection kept 125, 100, 550, 125
and 80 SGBs across the five folds, each chosen from the full 7,847, against 15 for the
final model fitted on all the training data. Nesting costs roughly *folds ×* the
selection and tuning time: on the case study the outer loop takes 37.5 minutes against
5.3 for the three final models (`metrics/timings.csv`).

## 4. The inner loop

`inner`, `inner_folds` and `inner_repeats` describe a second resampling, run
inside a fold's training part, whose only job is to **rank candidate
hyperparameter settings**. Its scores are never reported. The winning setting is
refit on the whole training part and scored by the outer fold.

`auto` picks a scheme the data can support. With a grouping column set the inner
splits stay grouped too, so tuning rewards settings that transfer between studies
rather than between samples. Which grouped scheme depends on how many groups
there are:

| groups | inner scheme | refits per evaluated setting |
|---|---|---|
| up to `max(inner_folds, 10)` | leave-one-group-out | one per group |
| more than that | k-fold over the groups | `inner_folds` |

Without a grouping column, `auto` uses k-fold with the folds capped by the rarest
class, or repeated k-fold on small runs with cheap learners, where the extra
repeats buy a steadier ranking. Setting `inner` to `cv`, `repeated_cv` or `loo`
overrides the choice and applies it to every learner.

!!! note "The bound on grouped tasks"

    On the 57 cFMD datasets, leave-one-group-out would need 57 refits per evaluated
    setting: about 2,000 fits for one tuning of the random forest (35 Hyperband
    evaluations), and the tuning runs again in every outer fold. Five folds over the
    groups need five refits per evaluated setting. Whole groups stay together under either
    rule. A learner with one candidate setting, such as TabPFN, has nothing to rank
    and is unaffected.

## The model you ship

The per-fold models exist only to produce the estimate; they are never combined. The
model reported and used for predictions is a **separate fit of the same procedure on
all the training data**.

## Which category is predicted

A learner returns a probability per category. The predicted category is the one with the
largest probability **divided by that category's frequency in the training rows**
(`evaluation.prior_correction`, on by default), for every learner alike. On unbalanced
classes the plain largest probability favours the majority class; the divided one is the
decision that maximises balanced accuracy, for calibrated probabilities. Probabilities are
not changed, so log-loss is the same either way. Each outer fold uses its own training
rows' frequencies.

Class balancing (`preprocessing.smote`) corrects for the same imbalance by resampling the
training rows. The two are not combined: with both, the small classes are over-predicted.
With the correction on, the automatic setting leaves balancing off, and an explicit
balancing method that the imbalance gate would apply stops the run
([class balancing](data-preparation.md#class-balancing)).

## What gets reported

Resampling results come with the mean over folds **and the standard deviation across
them**, plus the full per-group table. On the case study TabPFN reaches 0.662 ± 0.121
balanced accuracy over five folds, with single folds from 0.475 to 0.788
([results](../cfmd/results.md#per-fold)): a different claim from the same mean with a
spread of 0.02.

It is reported as a standard deviation, never a standard error, because folds share
training data and no unbiased variance estimator exists for cross-validation
(Bengio and Grandvalet, 2004).

A single test set has no folds, so its metrics carry a bootstrap 95 % interval over
its samples instead.

## Calibration

A model can rank samples correctly and still put its decision threshold in the wrong
place for a new population. Platt scaling, fitted on the out-of-fold predictions and
therefore on training data alone, corrects that shift.

It corrects a single positive-class probability, so it runs on binary tasks only.
On a multiclass run such as the cFMD case study the step is skipped and
`preprocessing.calibration` has no effect.

Platt scaling moves the threshold; it cannot repair a ranking that does not transfer to
the new population.
