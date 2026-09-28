# Your own data

TabFlux reads three plain files. Gzipped files (`.csv.gz`) are read transparently.

| file (config key) | required | contents |
|---|---|---|
| `input.counts_path` | yes | one row per feature: `feature_id`, then one **raw count** column per sample. Never normalised, never rarefied. |
| `input.taxa_path` | yes | one row per feature: `feature_id`, optional `sequence` (the ASV nucleotide sequence), then rank columns (`Kingdom` … `Species`) and/or a semicolon-delimited `taxonomy` string. Rank columns win when both are present. |
| `input.meta_path` | yes | one row per sample: sample ids in the **first column**, matching the count columns; the target column; any grouping columns. |
| `input.test_counts_path`, `test_taxa_path`, `test_meta_path` | no | the same three files for an independent external test set |

The layout mirrors DADA2 and [MetaFlux](https://github.com/iLivius/MetaFlux) output.
MetaPhlAn profiles fit the same shape with SGBs as features; percentages are fine, the
depth step turns them back into proportions.

```text
# counts.csv
feature_id,S1,S2,S3
ASV_1,0,12,3
ASV_2,45,0,7

# taxa.csv
feature_id,sequence,Kingdom,Phylum,Class,Order,Family,Genus,Species
ASV_1,ACGAAGGGTGCAAGCG...,Bacteria,Actinobacteriota,Actinobacteria,Streptomycetales,Streptomycetaceae,Streptomyces,niveus
ASV_2,TACGGAGGGTGCAAGC...,Bacteria,Firmicutes,Bacilli,Bacillales,Bacillaceae,Bacillus,NA

# meta.csv
sample,study,outcome
S1,study_A,case
S2,study_A,control
S3,study_B,case
```

## What the import step enforces

- **Feature identity at ASV level comes from the sequence, never from the id.**
  `ASV_12` is assigned per dataset in input order, so the same id names different
  organisms in different datasets. With sequences available (a `sequence` column, or
  sequences used as feature names, as DADA2 emits them) TabFlux derives a stable hashed
  id, `ASV_<12 hex>`, identical for the same sequence anywhere. Without sequences,
  ASV-level external prediction is refused.
- **Species = genus + epithet.** A bare `Species` column holds the epithet (`niveus`);
  TabFlux pairs it with the genus (`Streptomyces niveus`), so unrelated genera sharing
  an epithet are never merged.
- Placeholder labels (`uncultured`, `unassigned`, a bare `g__`) count as unassigned and
  are dropped at aggregation; the report says how many reads that costs at each level.
- Each class needs at least `preprocessing.min_samples_per_class` samples (default 5);
  smaller classes are dropped, and the report names them.
- Sample ids are intersected between counts and metadata. A sample present in only one
  file is dropped silently; an empty overlap is an error.
- *Not checked:* one amplicon region per table. ASVs from different primer pairs never
  match, whatever their names.

## The settings that matter

```yaml
dataset:
  target: "outcome"     # the metadata column with the class labels
  group: "study"        # the grouping column, or "" for random folds
  tax_level: [phylum, class, order, family, genus, species]
input:
  counts_path: "input/counts.csv.gz"
  taxa_path:   "input/taxa.csv.gz"
  meta_path:   "input/meta.csv"
methods:
  pick: [ranger, tabpfn]
```

`dataset.group` names which column groups the samples; how those groups become folds is
`evaluation.outer`. Read the [grouping](../workflow/grouping.md) page before choosing.
Every key is listed in the [configuration reference](../reference/configuration.md).

!!! tip "Do a cheap run first"

    `methods.pick: [ranger]`, one `tax_level`, `preprocessing.samples_to_keep: 0.3`,
    `importance.method: "none"` — and its own `dataset.version`, because tuned models
    are cached per run folder and a later full run with the same version would
    silently reuse the cheap ones.

## The external test set

The test files go through the identical preparation as the training data: the same
aggregation, alignment to the training feature space, the same normalisation. Every
sample with at least one read in that feature space gets class probabilities. A sample
without any, including one whose reads all fall in taxa the training data never had, is
skipped and keeps a quality-control row with empty predictions. Metrics are computed
only for samples whose label is one of the training classes, overall and per
`input.test_group`; controls, unlabelled samples and extra conditions flow through with
probabilities. Each row of `metrics/external_predictions.csv` carries `reads_at_rank`,
`pct_reads_in_reference` and `below_training_min_depth`: a low `pct_reads_in_reference`
means the model saw only a fraction of that sample's community.

!!! note "Metagenomic taxonomic profiles"

    In this release, support for metagenomic taxonomic profiles is at the demo stage:
    the [cFMD case study](../cfmd/index.md) runs them at SGB level with cross-validation.
    An external test set at SGB level is not supported yet, and the run stops at that
    step. Fuller support for these profiles comes with the next release.

## Legacy single-file layout

`input.asv_path` accepts a sample × feature table, or a BIOM-style feature × sample
table with a trailing `taxonomy` column. Leave it empty when using the three files.
