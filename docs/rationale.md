# Rationale

Why the workflow is shaped the way it is.

## One notebook, one configuration file

The whole analysis is a single Quarto notebook, `analysis/tabflux.qmd`, driven by a
plain-text `config.yaml`. The functions the notebook calls live in `R/` with plain-script
tests.

## The honest estimate is the default

Microbiome classifiers are usually scored by random cross-validation. When the samples
come from several studies, sites or batches, every test sample then has neighbours from
its own study in the training data, and a model can score well by recognising the study
rather than the biology. Name the grouping column in `dataset.group`, and every split
keeps whole groups together whatever fold design `evaluation.outer` asks for; leave
`nested: true`, and feature selection and tuning are repeated inside every fold, on that
fold's training part alone.

Grouped is not the same as leave-one-dataset-out. Both cFMD configurations group by
dataset and then split by k-fold cross-validation over those groups, because most cFMD
datasets hold a single food category: hold one dataset out and you hold out a whole
class, which cannot be scored. Leave-one-dataset-out is the right choice when the studies
are internally mixed, and one option among several otherwise. The
[evaluation design](workflow/evaluation.md) page walks through the choices; the
[grouping](workflow/grouping.md) page says which fold design a compilation can carry.

Nesting is what costs: selection and tuning run once per outer fold instead of once for
the whole run. The inner loop that ranks candidate settings — scores that are never
reported — is k-fold over the groups when there are many of them and leave-one-group-out
when there are few.

## Two learners in every shipped configuration

A random forest is the standard baseline of microbiome classification and gives
interpretable importances. TabPFN is a transformer pre-trained on synthetic tables. Its
weights are not updated on your data: the training samples are passed in as context at
prediction time, and each TabPFN-3.5 prediction averages eight forward passes. It has no
hyperparameters to search, so tuning it is a single evaluation on the inner folds; its
cost is paid at prediction time, on a GPU. On the cFMD run, nested tuning took about as
long for TabPFN as for the forest (11.1 and 10.1 min over five folds). A microbial table
after feature selection is far inside TabPFN-3.5's documented limits of 1,000,000 rows
and 20,000 features.

In the cFMD case study, with one decision rule for every learner, these two and XGBoost
are 0.036 apart in balanced accuracy (TabPFN 0.662, XGBoost 0.634, forest 0.626), against
a fold-to-fold standard deviation of 0.10–0.16. Within a fold they are at most 0.09
apart; across folds each spans 0.23–0.40. Which studies are held out moves the score more
than which learner is used ([comparing learners](cfmd/comparison.md)).

## Per-sample depth normalisation, nothing fitted

Sequencing depth varies between samples and systematically between studies. Every
transform TabFlux applies (relative abundance, then a log) is computed sample by sample,
from that sample alone. Nothing is fitted on the training data, so the same function
applies to an external sample, with no route for training information to leak into it.

## Container first

An R workflow that calls Python through `reticulate` has two runtimes to reproduce. The
image pins both, installs every R package as a precompiled binary from a date-pinned
repository, and carries its own CUDA libraries inside the PyTorch wheel. Continuous
integration builds that image from scratch on a clean runner, runs the R unit tests
inside it, then renders a three-dataset cut of the public demo on CPU with the random
forest — on every push to `main` and every pull request. A clean runner has no TabPFN
licence token, so this check does not exercise the TabPFN path.

## No data in the repository

TabFlux ships code and a public case study. The data it was developed on belong to a
separate, unpublished study; the tool does not depend on them.

## What TabFlux is not

It does not assign taxonomy: it starts from a table that already has one. It is not an
AutoML service: the learners and their search spaces are fixed and documented. And it
does not promise that a microbiome predicts your outcome.
