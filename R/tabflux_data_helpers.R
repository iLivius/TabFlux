# Helpers for preparing abundance tables before modeling: stable feature IDs,
# taxonomic aggregation, per-sample normalization, and alignment of a new
# dataset (e.g. an external test set) to the training feature space.
#
# Every function here is stateless: nothing is estimated on one set of samples
# and re-applied to another, so each sample is transformed on its own. The same
# code path therefore works for the training data, an external test set and any
# single sample that arrives later, and test samples cannot leak into training.
#
# Sourced by analysis/tabflux.qmd alongside the other R/tabflux_*_helpers.R files.
# Where each function is used in the notebook (chunk names in quotes):
#   "import"        – build_feature_matrix() calls taxon_assignments_at_rank()
#                     + aggregate_counts_by_taxon() when a rank is requested,
#                     or looks_like_sequences() + sequence_based_feature_ids()
#                     at ASV level. Same helper for the external test set.
#   "normalize"     – find_empty_samples() as a guard, then
#                     normalize_abundance() on the training table.
#   "external test" – align_features_to_reference(), then normalize_abundance()
#                     with the same method/pseudocount as training.
# tests/test_data_helpers.R exercises every function with tiny toy tables.


# ── Stable feature identifiers ────────────────────────────────────────────────

# Turn ASV nucleotide sequences into short, deterministic feature IDs.
#
# Why: IDs like "ASV_12" are numbered per dataset in input order, so the same
# name means a different organism in two independently processed datasets and
# joining on it silently matches unrelated features. The sequence is the only
# identity an ASV has, but too long for a column name.
#
# A hash (md5 here) is a fixed-length fingerprint computed from the text: the
# same sequence always gives the same fingerprint, and two different sequences
# almost never share one. So the ID is short and comes out the same in any
# dataset, with no coordination between them. Sequences are upper-cased and
# trimmed first, so "acgt" and "ACGT " give one ID.
#
# Input:  character vector of DNA sequences (one per feature), from the
#         'sequence' column of the taxa table or from feature names that are
#         themselves sequences (DADA2 style).
# Output: character vector like "ASV_3f9c1a8b0e2d" (12 hex chars of the md5).
#         12 hex chars = 48 bits: chance of any collision among ~400k sequences
#         is < 0.1%, and uniqueness is asserted anyway. These become the column
#         names of the modeling matrix (after sanitize_feature_names() in the
#         notebook) and are what an ASV-level external test set is aligned on.
sequence_based_feature_ids <- function(sequences, prefix = "ASV_", n_chars = 12L) {
  sequences <- toupper(trimws(as.character(sequences)))

  hashes <- vapply(
    sequences,
    function(s) digest::digest(s, algo = "md5", serialize = FALSE),
    character(1),
    USE.NAMES = FALSE
  )
  ids <- paste0(prefix, substr(hashes, 1L, n_chars))

  # Duplicates must never pass silently:
  #  * same sequence twice = malformed input (a denoiser emits each ASV once);
  #    keeping both splits its counts over two identical columns and
  #    double-counts it when another dataset is aligned to this one;
  #  * different sequences, same hash = a genuine collision.
  dup_ids <- unique(ids[duplicated(ids)])
  for (dup in dup_ids) {
    if (length(unique(sequences[ids == dup])) > 1L) {
      stop("Hash collision between different sequences for feature ID: ", dup,
           ". Increase n_chars.")
    }
    stop("The same sequence appears more than once in the input (feature ID ",
         dup, "). Deduplicate the table (sum the counts of identical ",
         "sequences) before running TabFlux.")
  }

  ids
}

# Decide whether feature names are nucleotide sequences (canonical DADA2 output
# uses the sequence itself as the name) rather than short IDs like "ASV_12".
#
# Input:  the feature_id column of the counts table.
# Output: one TRUE/FALSE for the whole vector — every name must be at least
#         min_length letters long and contain only A/C/G/T/U/N (either case).
#         50 is well below any real amplicon length, well above any ID.
# Used by build_feature_matrix() ("import" chunk) when the taxa table has no
# 'sequence' column, to decide whether the names can be hashed into stable IDs
# or must stay dataset-local labels.
looks_like_sequences <- function(x, min_length = 50L) {
  x <- as.character(x)
  all(nchar(x) >= min_length & grepl("^[ACGTUNacgtun]+$", x))
}


# ── Taxonomic aggregation ─────────────────────────────────────────────────────

# Position of each rank in a semicolon-delimited taxonomy string
# ("Bacteria;Pseudomonadota;Gammaproteobacteria;...").
# Field 1 is called "kingdom" here although SILVA labels it Domain
# (Bacteria/Archaea); the position is what matters. The names double as the
# accepted rank keys (dataset.tax_level minus "asv"), which both taxon_*
# functions below validate against.
taxonomy_rank_positions <- c(
  kingdom = 1L, phylum = 2L, class = 3L, order = 4L,
  family = 5L, genus = 6L, species = 7L
)

# Turn placeholder taxon labels into NA and strip QIIME rank prefixes.
#
# Why: "uncultured", "unassigned" or a bare "g__" are not taxa — they mean the
# classifier could not name the organism. Kept as names, every unnamed genus in
# the dataset would pool into one fake taxon "uncultured". They become NA here,
# which the aggregation step drops and reports. Real prefixed names
# ("g__Bacillus") keep the name itself.
#
# Input:  character vector of labels — one rank column of the taxa table, or
#         one field of a taxonomy string.
# Output: same length; NA for placeholders, otherwise the cleaned name.
# Called only from taxon_from_taxonomy_string() and taxon_assignments_at_rank().
# Placeholders are matched case-insensitively; extend the list if a new
# classifier or database introduces another "no name" label.
clean_taxon_labels <- function(x) {
  x <- trimws(as.character(x))
  # QIIME-style prefixes: "g__Bacillus" -> "Bacillus"; a bare "g__" -> "".
  x <- sub("^[a-zA-Z]__", "", x)
  placeholder <- !nzchar(x) | tolower(x) %in% c(
    "na", "nan", "null", "none", "unknown", "unclassified", "unassigned",
    "uncultured", "unidentified", "metagenome", "uncultured bacterium",
    "uncultured organism", "uncultured soil bacterium"
  )
  x[placeholder] <- NA_character_
  x
}

# Extract the taxon name at one rank from taxonomy strings.
#
# Input:  character vector of semicolon-delimited taxonomy strings, and a rank
#         key ("phylum" ... "species").
# Output: character vector of taxon names; NA where the string does not reach
#         that rank. For "species" the result is "<Genus> <epithet>" (e.g.
#         "Streptomyces niveus"): field 7 holds only the epithet, and the same
#         epithet recurs in unrelated genera, so merging on it would pool
#         unrelated organisms.
# Called by taxon_assignments_at_rank() when the taxa table has no column for
# the REQUESTED rank, even if it has others: a table with a Genus but no Species
# column comes here at species level. Usually a legacy single-file layout with a
# trailing 'taxonomy' column, or a three-file taxa table carrying only that
# string.
taxon_from_taxonomy_string <- function(taxonomy_strings, rank_key) {
  rank_key <- tolower(rank_key)
  # Check the name before looking it up: `[[` on an unknown name aborts with
  # "subscript out of bounds", which says nothing about ranks.
  if (!rank_key %in% names(taxonomy_rank_positions)) {
    stop("Unknown taxonomic rank: ", rank_key)
  }
  depth <- taxonomy_rank_positions[[rank_key]]

  vapply(as.character(taxonomy_strings), function(s) {
    if (is.na(s) || !nzchar(s)) return(NA_character_)
    # Fields are indexed strictly by POSITION. Removing empty fields first
    # would silently shift every deeper rank up one slot
    # whenever a middle rank is blank (e.g. "Bacteria;;Gammaproteobacteria"),
    # aggregating counts under the wrong taxon. An empty field at the
    # requested rank simply means "unassigned there" -> NA.
    parts <- trimws(strsplit(s, ";", fixed = TRUE)[[1]])
    # field_at(i): the i-th field, cleaned; NA when the string is too short.
    field_at <- function(i) {
      if (length(parts) < i) return(NA_character_)
      value <- clean_taxon_labels(parts[[i]])
      value
    }
    if (rank_key == "species") {
      # Needs both the genus (field 6) and the epithet (field 7).
      genus <- field_at(6L)
      epithet <- field_at(7L)
      if (is.na(genus) || is.na(epithet)) return(NA_character_)
      return(paste(genus, epithet))
    }
    field_at(depth)
  }, character(1), USE.NAMES = FALSE)
}

# Extract the taxon name at one rank from a taxon table.
#
# Input:  a data.frame from the three-file input layout. It may carry explicit
#         rank columns (Kingdom ... Species, as MetaFlux writes them), a
#         "taxonomy" string column, or both. Rank columns win: they are already
#         parsed and unambiguous.
# Output: character vector of taxon names (NA = unassigned at that rank), one
#         per row of the table. Species is always "<Genus> <epithet>". Row order
#         must match the counts table; the notebook lines the two up by
#         feature_id before calling build_feature_matrix(), which passes this
#         vector straight into aggregate_counts_by_taxon().
taxon_assignments_at_rank <- function(taxa_df, rank_key) {
  rank_key <- tolower(rank_key)
  if (!rank_key %in% names(taxonomy_rank_positions)) {
    stop("Unknown taxonomic rank: ", rank_key)
  }

  # Case-insensitive lookup of the rank columns so "Genus" and "genus" both work.
  find_col <- function(name) {
    hit <- which(tolower(names(taxa_df)) == tolower(name))
    if (length(hit)) taxa_df[[hit[1]]] else NULL
  }

  rank_col <- find_col(rank_key)

  if (!is.null(rank_col)) {
    if (rank_key == "species") {
      # The Species column holds only the epithet; pair it with the genus.
      genus_col <- clean_taxon_labels(find_col("genus"))
      epithet <- clean_taxon_labels(rank_col)
      out <- ifelse(is.na(genus_col) | is.na(epithet), NA_character_,
                    paste(genus_col, epithet))
      return(out)
    }
    return(clean_taxon_labels(rank_col))
  }

  # No rank columns: fall back to parsing the taxonomy string
  # (which applies clean_taxon_labels to each field itself).
  tax_col <- find_col("taxonomy")
  if (is.null(tax_col)) {
    stop("Taxon table has neither a '", rank_key, "' column nor a 'taxonomy' column.")
  }
  taxon_from_taxonomy_string(tax_col, rank_key)
}

# Sum feature counts into taxon counts at one rank.
#
# Input:  counts    – data.frame/matrix, rows = features, cols = samples,
#                     raw integer counts.
#         taxon     – character vector, one taxon name per feature row (from
#                     taxon_assignments_at_rank); NA = unassigned.
# What it does: drops unassigned features — their reads are lost here, and the
#         caller reports how many — then sums the counts of all features
#         sharing a taxon name.
# Output: list(counts = data.frame rows = taxa, cols = samples;
#              n_features_used, n_features_dropped)
#         build_feature_matrix() ("import" chunk) turns `counts` into the
#         samples x taxa modeling matrix and uses the counters plus the read
#         totals for the "% of reads retained" message. The external test set
#         takes the same path, so both tables lose reads to "unassigned at this
#         rank" in exactly the same way, which keeps the two figures comparable.
aggregate_counts_by_taxon <- function(counts, taxon) {
  counts <- as.data.frame(counts)
  taxon <- as.character(taxon)
  if (length(taxon) != nrow(counts)) {
    stop("aggregate_counts_by_taxon: 'taxon' must have one entry per feature row.")
  }

  keep <- !is.na(taxon)
  n_dropped <- sum(!keep)
  counts <- counts[keep, , drop = FALSE]
  taxon <- taxon[keep]

  if (!nrow(counts)) {
    stop("No features carry a taxonomic assignment at the requested rank.")
  }

  # rowsum() sums rows by group in one pass; the result has one row per taxon.
  # na.rm so a stray NA count (e.g. from coercing a malformed cell) does not
  # poison a whole taxon's total.
  aggregated <- rowsum(counts, group = taxon, na.rm = TRUE)

  list(
    counts = as.data.frame(aggregated),
    n_features_used = sum(keep),
    n_features_dropped = n_dropped
  )
}


# ── Per-sample normalization ──────────────────────────────────────────────────

# Report samples whose total read count is zero.
# Such a sample carries no community information: its relative abundance would
# be 0/0. The notebook drops these with a message before calling
# normalize_abundance(), which refuses them outright.
#
# Input:  data.frame/matrix, rows = samples, cols = features, raw counts
#         (feature columns only — no Sample/target/group/pta columns).
# Output: character vector, the row names of the offending samples (empty when
#         none) — row POSITIONS ("1", "5") when the table has no row names, as
#         in the "normalize" chunk.
# Used in the "normalize" chunk as a guard that only fires if chunks were run
# out of order; the "pre-process" chunk already removes such samples.
find_empty_samples <- function(abundance) {
  totals <- rowSums(as.matrix(abundance))
  rownames(abundance)[totals == 0]
}

# Normalize raw counts for sequencing depth, one sample at a time.
#
# Input:  abundance – data.frame/matrix, rows = samples, cols = features,
#                     raw counts (the aggregated table from the import step).
#         method    – "none"    keep raw counts (no depth correction)
#                     "tss"     total-sum scaling: divide each sample's counts
#                               by that sample's total = relative abundance
#                     "tss_log" log10(relative abundance + pseudocount)  [default]
#                     "tss_clr" centred log-ratio on the relative abundances
#         pseudocount – small constant added before logs so zeros are defined.
#                     On the *proportion* scale, and fixed rather than estimated
#                     from the data: a data-derived value would depend on which
#                     samples are present and break the stateless rule above.
#
# Why TSS always comes first: dividing by the sample total removes sequencing
# depth exactly. Logs afterwards make a doubling the same size step for rare and
# abundant taxa alike. CLR (on the proportions) also subtracts each sample's
# mean log-abundance, giving log-ratios to that sample's "average taxon" — the
# usual transform for sequencing data, which is compositional: the total is set
# by depth, not by the community, so only ratios between taxa carry information.
# CLR on sparse raw *counts* is a trap: the pseudocount then dominates the
# geometric mean and most of the depth effect survives.
#
# Output: list(data = data.frame, same shape and dimnames as the input;
#              library_sizes = named numeric, reads per sample — kept for QC,
#              depth being a sample property worth reporting).
#
# Called twice in the notebook with the same method/pseudocount (both from
# config preprocessing.*): "normalize" chunk on the training table (the result
# replaces the raw counts in `tab`; library_sizes feed the depth report and the
# per-group depth comparison), and "external test" chunk on the aligned test
# counts. Method and pseudocount also go to normalization.json so a future
# sample can be transformed identically.
normalize_abundance <- function(abundance,
                                method = c("tss_log", "none", "tss", "tss_clr"),
                                pseudocount = 1e-6) {
  method <- match.arg(method)
  mat <- as.matrix(abundance)
  if (!is.numeric(mat)) stop("normalize_abundance: abundance table must be numeric.")
  if (any(mat < 0, na.rm = TRUE)) stop("normalize_abundance: negative counts found.")

  library_sizes <- rowSums(mat)
  if (any(library_sizes == 0)) {
    stop("normalize_abundance: sample(s) with zero total reads: ",
         paste(rownames(mat)[library_sizes == 0], collapse = ", "),
         ". Drop them first (see find_empty_samples()).")
  }

  if (method == "none") {
    out <- mat
  } else {
    # TSS: divide every count by its sample's total -> relative abundance.
    proportions <- sweep(mat, 1, library_sizes, "/")

    if (method == "tss") {
      out <- proportions
    } else if (method == "tss_log") {
      out <- log10(proportions + pseudocount)
    } else { # tss_clr
      log_props <- log(proportions + pseudocount)
      # Subtract each sample's mean log-proportion (= divide by the sample's
      # geometric mean on the raw scale).
      out <- sweep(log_props, 1, rowMeans(log_props), "-")
    }
  }

  # Put the original sample/feature names back: the model and the SHAP export
  # match columns by name, so the output must carry exactly the input names.
  out <- as.data.frame(out)
  dimnames(out) <- dimnames(abundance)
  list(data = out, library_sizes = library_sizes)
}


# ── Aligning new data to the training feature space ───────────────────────────

# Reshape a new dataset (external test set, future samples) onto the feature
# space the model was trained on.
#
# Input:  abundance          – data.frame, rows = samples, cols = features,
#                              RAW counts, feature names on the same naming
#                              scheme as the reference (taxon names at the
#                              modeled rank, or sequence-derived ASV IDs).
#         reference_features – character vector: every feature of the TRAINING
#                              data at that rank, before feature selection.
#
# What it does:
#   * features in the reference but absent here  -> added as zero columns
#     (the model expects the column; no evidence means a zero count)
#   * features here but not in the reference     -> dropped
#     (the model has no coefficient/split for them, and they would only distort
#     the normalization denominator)
#   * columns reordered to match the reference exactly.
# Alignment runs BEFORE normalization, so TSS/CLR denominators cover the same
# feature space as in training, and BEFORE subsetting to the selected features,
# so the denominator does not depend on which features survived selection.
#
# Output: list(
#   data                 – aligned raw counts (samples x reference features)
#   novel_features       – dropped feature names
#   missing_features     – reference features that were zero-filled
#   reads_total          – per sample: raw reads before alignment
#   reads_covered        – per sample: reads falling inside the reference space
#   pct_reads_covered    – per sample: 100 * covered / total. LOW VALUES ARE A
#                          WARNING SIGN: the model then sees only part of that
#                          sample's community and predicts on thin evidence.
#                          Exported next to the predictions as QC.
# )
#
# Called once, in the notebook "external test" chunk. `abundance` comes from
# build_feature_matrix() on the test files; `reference_features` are the
# training feature names saved to reference_features.csv in the "normalize"
# chunk, translated back to original taxon names through feature_name_map. The
# aligned counts then get the model's sanitized column names, go through
# normalize_abundance(), and are predicted; the three read counters go into the
# per-sample QC table.
align_features_to_reference <- function(abundance, reference_features) {
  abundance <- as.data.frame(abundance)
  reference_features <- as.character(reference_features)

  novel <- setdiff(names(abundance), reference_features)
  missing <- setdiff(reference_features, names(abundance))

  reads_total <- rowSums(as.matrix(abundance))
  shared <- intersect(names(abundance), reference_features)
  reads_covered <- if (length(shared)) {
    rowSums(as.matrix(abundance[, shared, drop = FALSE]))
  } else {
    stats::setNames(rep(0, nrow(abundance)), rownames(abundance))
  }

  # Keep the shared columns, add a zero column for every reference feature
  # this dataset never observed, then impose the reference column order.
  aligned <- abundance[, shared, drop = FALSE]
  for (feature in missing) {
    aligned[[feature]] <- 0
  }
  aligned <- aligned[, reference_features, drop = FALSE]

  list(
    data = aligned,
    novel_features = novel,
    missing_features = missing,
    reads_total = reads_total,
    reads_covered = reads_covered,
    # pmax(..., 1) avoids 0/0 for a sample with no reads at all; such samples
    # get 0% here and are flagged separately by the caller.
    pct_reads_covered = 100 * reads_covered / pmax(reads_total, 1)
  )
}
