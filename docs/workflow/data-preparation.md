# From table to features

What happens to the counts between the input files and the first model.

## Aggregation to a taxonomic level

Counts are summed into taxon counts at the level named in `dataset.tax_level`:
`phylum`, `class`, `order`, `family`, `genus`, `species`, or `asv` for no aggregation,
where the features are the sequence-hashed ASV ids. MetaPhlAn profiles add `SGB`, the
species-level genome bins the profiler reports, again without aggregation. Each level is
modelled independently; the wrapper runs the list and stacks the results.

Placeholder labels ("uncultured", "unassigned", a bare rank prefix) are treated as
unassigned and their reads dropped at that level, with the lost fraction printed in the
report. Species are always formed as *Genus epithet*.

!!! note "Why not model ASVs across studies"

    ASVs are comparable between datasets only through their sequences, and only within
    one amplicon region. In a multi-study compilation most ASVs occur in a single study,
    so ASV-level features cannot support a cross-study claim. The price is paid at
    species level, which keeps only a small share of the reads.

## Depth normalisation

Library size varies between samples and systematically between studies; a model trained
on raw counts learns sequencing depth instead of biology. `preprocessing.normalization`
picks the transform:

| value | meaning |
|---|---|
| `tss_log` *(default)* | log10(relative abundance + `pseudocount`) |
| `tss` | relative abundance: count / sample total |
| `tss_clr` | centred log-ratio on the relative abundances |
| `none` | raw counts |

Every transform is computed per sample; nothing is fitted on the training data, so the
identical function applies to the external test set and to any future sample. Relative
abundance always comes first: dividing by the sample total removes depth, and only then
are logs taken. There is no plain `clr` option: a log-ratio on sparse counts leaves most
of the depth effect in the zeros. The settings and the full pre-selection feature
space are saved next to the models (`normalization.json`, `reference_features.csv`), so
new data can be aligned later.

## Class filter and subsampling

Classes with fewer than `preprocessing.min_samples_per_class` samples are dropped before
anything is fitted, and the report names them. `samples_to_keep < 1` keeps a random
fraction of each class and exists for quick test runs only.

## Filtering and feature selection

Two mechanisms, and the second replaces the first.

**Filtering** (`preprocessing.filtering`) is a cheap filter inside every learner's
preprocessing graph: constant-feature removal at minimum, variance, correlation or
information-gain filters when asked. It is ignored while `selecting: true`, when the
notebook forces `"minimal"`.

**Selection** (`preprocessing.selecting: true`) runs on the training data alone, and
with `nested: true` again inside every outer fold:

1. an information-gain filter reduces the features to a budget — the largest of 500,
   five times the sample size, and 1% of the taxa — capped at 2,500;
2. recursive feature elimination, driven by a random forest's impurity importance, steps
   down a ladder of subset sizes, scoring each by cross-validation on balanced accuracy
   (five folds, or fewer where the number of groups — the rarest class when there is no
   grouping — cannot carry five);
3. the one-standard-error rule stops at the smallest subset whose score is within one
   standard error of the best.

The kept taxa go to `metrics/selected_features.csv`. With ten training samples or fewer,
an ensemble mode (four learners, fifty repetitions) replaces the single forest; it is
far more expensive.

## Class balancing

`preprocessing.smote` controls class balancing inside the learner graph, so it happens
after the split and never touches test data. One gate governs every setting: nothing is
resampled unless the majority/minority ratio exceeds `smote_imbalance_threshold` **and**
every class has at least `min_samples_per_class` samples. A named method chooses *how* to
balance, not *whether* to.

With `evaluation.prior_correction: true` (the default), `""` resolves to `none`. An
explicit method that the imbalance gate would apply stops the run: the
[decision rule](evaluation.md#which-category-is-predicted) already corrects for the class
frequencies, and the two together over-predict the small classes. The table applies
with `prior_correction: false`.

| value | meaning |
|---|---|
| `""` *(default)* | `none` under the default decision rule; otherwise `smote` on two classes, `balance` on more |
| `none` | never balance |
| `smote` | interpolate new minority samples anywhere in the minority class |
| `blsmote` | the same, only near the boundary with the majority |
| `adasyn` | the same, concentrated where the minority class is sparsest |
| `balance` | `classbalancing`: copy rows until every class matches the largest |

The report prints the method actually used, as `Final SMOTE decision`.

!!! warning "SMOTE is binary only"

    The SMOTE family interpolates towards one minority class. On a multi-class target it
    closes the biggest gap and leaves the small classes as they were. `smote`, `blsmote`
    and `adasyn` are therefore replaced by `balance` on such a target, and `""` picks
    `balance` there to begin with.

    `balance` duplicates rows, so closing a wide gap means copying the smallest class
    many times over. Where the majority dominates — dairy is two thirds of the samples in
    `config_cfmd_category.yaml` — `none` with the default decision rule, scored on
    balanced accuracy, which weights every class equally, is the better answer.
