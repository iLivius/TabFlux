# input/

Put your three files here, or point `input.counts_path`, `input.taxa_path` and
`input.meta_path` in `config.yaml` anywhere else:

- `counts.csv(.gz)` — one row per feature, raw counts per sample
- `taxa.csv(.gz)`   — one row per feature, taxonomy (rank columns or a string)
- `meta.csv`        — one row per sample, target and grouping columns

Only this README is tracked; the files you put here are ignored by git. The
layout is described in the documentation under *Getting started → Your own data*.
