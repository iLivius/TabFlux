# Grouping and fold size

Two settings decide how performance is estimated.

| setting | what it means |
|---|---|
| `dataset.group` | **which column groups the samples.** Nothing more. |
| `evaluation.outer` | **how folds are built** from those groups. |

`dataset.group` does *not* switch leave-one-dataset-out on. It says "samples
that share this value belong together and must never be split across a fold
boundary". The key `dataset.lodo` is read as `dataset.group`, with a message
asking you to rename it.

## The menu

With a grouping column set, mlr3 assigns whole groups to folds. The fold count
is capped automatically by the number of groups.

| `evaluation.outer` | a fold holds | use it when |
|---|---|---|
| `lodo` | **exactly one group** | every group contains all classes, and you want the per-group table |
| `cv`, `outer_folds: 5` | roughly one fifth of the groups | groups are small, numerous, or class-poor |
| `repeated_cv` | the same, repeated | the fold assignment visibly moves the numbers |
| `subsampling` | `outer_repeats` random splits | a cheaper middle ground |

Leave-one-dataset-out is the extreme case of grouped cross-validation, where the
fold count equals the number of groups.

## Configuring a real leave-one-dataset-out

```yaml
dataset:
  group: "study"      # the grouping column, as it is named in the metadata
evaluation:
  outer: "lodo"       # one fold per group
  nested: true
```

With twelve studies that gives twelve folds, each study scored once on a model that
never saw it.

## When it does not work, and what to do instead

Leave-one-dataset-out needs **every held-out group to contain the classes you
are predicting**. If a group holds a single class, its fold measures only that
class: balanced accuracy reduces to that class's recall, and AUC and the other
ranking metrics are undefined (`NA`). When no other group carries that class,
holding the group out also asks the model to recognise a class absent from its
own training data.

In the [cFMD case study](../cfmd/running.md), 96 of the 109 datasets contain
exactly one food category.

!!! tip "The fix is fold size, not grouping"

    Keep `group` naming the study column, so studies are still never split, and
    change `outer` to `cv` with a small number of folds. Five folds over the 57
    datasets the case study keeps after its size and class filters puts about
    eleven studies in each ([how it is configured](../cfmd/running.md)), so each
    test fold carries most classes and no sample is tested by a model that saw
    its study.

The trade is coverage against strictness. Fewer folds mean more classes per
fold and a safer estimate; more folds mean a harder test and more of them. With
a rare class living in only three studies, ten folds would leave it absent from
seven of them.

## Choosing, in one rule

**The folds must mimic how the model will meet new data.** If your samples will
come from studies already represented, random folds are honest. If they will
come from a study that contributed nothing, only grouped folds tell the truth,
and the question left is how many groups you can hold out at once.
