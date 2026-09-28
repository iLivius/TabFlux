# Case study: cFMD

TabFlux ships a worked example that needs no data of your own: the
[curated Food Metagenomic Data](https://github.com/SegataLab/cFMD) repository (cFMD), a
public compilation of food metagenomes, profiled from reads with MetaPhlAn 4. The
feature is the species-level genome bin (SGB).

One question runs through the four pages below. **Which food category did this sample
come from** — dairy, meat, fish, fermented_beverages and so on — given nothing but its
SGB profile.

## Which counts mean what

Release v1.3.2 lists 109 datasets and about 4,000 samples, 107 of which ship a profile
table. The case study uses a filtered subset of that: drop the datasets with fewer than
ten samples, keep the categories with fifty samples or more, and **3,680 samples across
57 datasets in 7 categories** remain. Every result on these pages is measured on those
3,680.

## Why this example

- **Public.** Every number on this site can be reproduced from a versioned tag.
- **Grouped.** Samples arrive in study-sized blocks: whole studies stay together in the
  five outer folds, so nothing is scored on a study it was also trained on.
- **Unbalanced.** Dairy alone is 2,467 of the 3,680 samples, the smallest category 75.
  Answering "dairy" to everything already scores 0.67 plain accuracy, so balanced
  accuracy — chance level 1/7 = 0.143 — is the column to read. TabPFN reaches 0.662
  there, XGBoost 0.634, the random forest 0.626.

## The four pages

- [The database](database.md) — what cFMD is, how releases differ, how TabFlux reads it.
- [Running it](running.md) — the configuration, and why the design is what it is.
- [Results](results.md) — what TabFlux finds, and what the honest design costs.
- [Comparing learners](comparison.md) — TabPFN, random forest and XGBoost under one
  decision rule.
