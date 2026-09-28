# The database

The [curated Food Metagenomic Data](https://github.com/SegataLab/cFMD) (cFMD; Carlino et
al., 2024) is a public compilation of food metagenomes: release v1.3.2 lists 109
datasets and 4,125 samples, every one profiled with MetaPhlAn 4, which maps reads
against marker genes and reports an abundance per species-level genome bin (SGB). The
SGBs come from clustering assembled genomes, but that happened when the catalogue was
built; these samples are not assembled or binned. cFMD also distributes StrainPhlAn
strain profiles and HUMAnN functional profiles; TabFlux reads the taxonomic ones. It
ships one tab-separated profile per dataset plus one metadata table, on GitHub, under a
versioned tag. Two of the 109, `KawaiT_2012` and `RippF_2014`, have metadata but no
profile file, so `datasets: []` reads the 107 that have one.

## What a sample carries

| metadata column | example values |
|---|---|
| `dataset` | the study: `MASTER_WP4_CSIC_1`, `PasolliE_2020`, … |
| `macrocategory`, `category`, `type`, `subtype` | food → dairy → cheese → soft cheese |
| `fermented_non-fermented` | a curated fermentation flag, carried alongside the category columns |
| `country`, `sample_accession`, `run_accession` | provenance |

cFMD ships percentages: every sample sums to 100. The depth step
(`preprocessing.normalization`, `tss_log` here) divides each sample by its own total, so
on cFMD it rescales 100 to 1 before the log. The depth report shows 100 for every sample.

## How the categories are distributed

Among the 65 datasets with at least ten samples (3,886 samples), fifteen categories
occur, but seven of them hold fifty samples or more, and dairy alone is two thirds of
everything:

| category | samples | datasets |
|---|---:|---:|
| `dairy` | 2,467 | 38 |
| `fermented_beverages` | 422 | 4 |
| `fruits_and_vegetables` | 224 | 10 |
| `meat` | 197 | 7 |
| `fermented_meat` | 154 | 7 |
| `fish` | 141 | 4 |
| `fermented_grains` | 75 | 3 |

Those seven categories are what the case study predicts: 3,680 samples across 57
distinct datasets, 11 of which carry more than one of the seven.

The `datasets` column is the one that constrains the design: a category living in
three studies can lose all three to a single test fold, and is then missing from the
training data of that fold.

Two facts about the compilation drive the [design of the runs](running.md): 96 of the 109
datasets contain a single category, and the rare categories live in three or four datasets
each.

## Releases, and why the tag is pinned

The file format has moved between releases: v1.3.0 re-profiled every sample with a
newer database and left a stray header line in some files, v1.3.1 removed the metadata
rows that earlier profiles carried inside the table, v1.3.2 renamed the first column of
the 22 new datasets to `clade_name`. TabFlux reads by position and keeps only the lineage
rows, so all three parse; `input.cfmd.ref` is pinned to a tag so a run means one thing.

## How TabFlux reads it

One anonymous GitHub API call lists the release. Each profile is downloaded once and
cached by content hash under `input.cfmd.cache_dir`, so a rerun downloads nothing; when
the API is unreachable and the data are already cached, the module works from its
manifest. The profiles are merged on the lineage, samples and datasets below the size
filters are dropped, and three files are written in TabFlux's own layout: counts, taxa
(the lineage split into ranks, the SGB kept as the feature), metadata. Feature ids read
`Genus_species__SGB1234`.
