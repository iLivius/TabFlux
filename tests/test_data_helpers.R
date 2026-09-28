# Unit tests for R/tabflux_data_helpers.R — plain script, no test framework.
# Run from the repository root:  Rscript tests/test_data_helpers.R
# Every test stops the script on failure, so a clean run prints only PASS lines.
# These cover the properties the analysis depends on: stable sequence-derived
# feature IDs, strictly positional taxonomy parsing, placeholder cleaning,
# that every TSS-based normalization gives the same result whatever the
# sequencing depth, and feature alignment.
source(file.path("R", "tabflux_data_helpers.R"))

# Tiny assertion helper: `cond` must be TRUE, otherwise stopifnot() aborts
# the script showing the failing expression; on success print the label.
ok <- function(label, cond) { stopifnot(cond); cat("PASS:", label, "\n") }

# 1. sequence_based_feature_ids: deterministic, refuses duplicates
#    The notebook reads one counts table (merging several datasets happens
#    before TabFlux) and uses these IDs to line up the
#    EXTERNAL test set with the training features at ASV level ("external
#    test" chunk). So the same ASV sequence must always get the same ID
#    whatever a dataset's spelling (upper/lower case), and a table listing
#    one sequence twice must be caught: its counts would otherwise be split
#    over two identical columns.
ids1 <- sequence_based_feature_ids(c("ACGT", "TTTT"))
ok("hash deterministic", identical(ids1, sequence_based_feature_ids(c("acgt", "tttt"))))
ok("hash format", all(grepl("^ASV_[0-9a-f]{12}$", ids1)))
ok("duplicate sequences refused",
   inherits(try(sequence_based_feature_ids(c("ACGT", "acgt")), silent = TRUE), "try-error"))

# 2. looks_like_sequences: the notebook uses this to decide whether an input
#    table names its features by DNA sequence (then hash them, test 1) or by
#    an already-assigned ID. A wrong guess would either hash "ASV_1" or
#    leave 250-bp sequences as column names.
ok("detects sequences", looks_like_sequences(strrep("ACGT", 20)))
ok("rejects ASV ids", !looks_like_sequences(c("ASV_1", "ASV_2")))

# 3. taxon_from_taxonomy_string: species = genus + epithet; NA below depth;
#    strictly positional (an empty middle rank must NOT shift deeper ranks);
#    placeholder labels and QIIME prefixes cleaned per field.
#    These strings are what the aggregation step groups ASVs by, so a parsing
#    slip silently merges or splits taxa: if an empty phylum field shifted
#    the rest, "Gammaproteobacteria" would be filed as a phylum and every
#    level would be wrong for that study. Species is "Genus epithet" because
#    the bare epithet ("terricola") is shared across unrelated genera.
tx <- c("Bacteria;Pseudomonadota;Gamma;Lyso;Lysob;Luteimonas;terricola",
        "Bacteria;Actinomycetota;Actino;Micro;Microb;Salinibacterium",
        "Bacteria")
ok("genus extraction", identical(taxon_from_taxonomy_string(tx, "genus"),
                                 c("Luteimonas", "Salinibacterium", NA)))
ok("species = genus+epithet", identical(taxon_from_taxonomy_string(tx, "species"),
                                        c("Luteimonas terricola", NA, NA)))
tx_gap <- "Bacteria;;Gammaproteobacteria;Lysobacterales"
ok("empty middle rank stays positional",
   is.na(taxon_from_taxonomy_string(tx_gap, "phylum")) &&
   identical(taxon_from_taxonomy_string(tx_gap, "class"), "Gammaproteobacteria") &&
   identical(taxon_from_taxonomy_string(tx_gap, "order"), "Lysobacterales"))
tx_qiime <- "d__Bacteria;p__Pseudomonadota;c__Gamma;o__Lyso;f__Lysob;g__Luteimonas;s__"
ok("QIIME prefixes stripped", identical(taxon_from_taxonomy_string(tx_qiime, "genus"), "Luteimonas"))
ok("bare QIIME prefix = unassigned", is.na(taxon_from_taxonomy_string(tx_qiime, "species")))
ok("placeholders blocked", is.na(clean_taxon_labels("uncultured")) &&
                           is.na(clean_taxon_labels("Unassigned")) &&
                           identical(clean_taxon_labels("g__Bacillus"), "Bacillus"))

# 4. taxon_assignments_at_rank: rank columns win; epithet paired with genus.
#    Some studies ship a parsed taxonomy table (Kingdom ... Species columns),
#    others only the semicolon string, some both. The parsed columns are the
#    trusted source when present; the string here deliberately disagrees
#    ("WRONG") to prove it is ignored. Row "c" has an epithet but no genus
#    and must come back NA, not "NA orphan".
taxa_df <- data.frame(
  feature_id = c("a", "b", "c"),
  Genus = c("Streptomyces", "Nocardia", NA),
  Species = c("niveus", NA, "orphan"),
  taxonomy = c("Bacteria;X;Y;Z;W;WRONG;wrongsp", "Bacteria;X", "Bacteria;X"),
  stringsAsFactors = FALSE
)
ok("rank column beats string", identical(taxon_assignments_at_rank(taxa_df, "genus"),
                                         c("Streptomyces", "Nocardia", NA)))
ok("species needs both parts", identical(taxon_assignments_at_rank(taxa_df, "species"),
                                         c("Streptomyces niveus", NA, NA)))
# string fallback when no rank columns
ok("string fallback", identical(
  taxon_assignments_at_rank(data.frame(taxonomy = tx), "phylum"),
  c("Pseudomonadota", "Actinomycetota", NA)))

# 5. aggregate_counts_by_taxon: sums by group, drops NA, preserves totals.
#    This is the step that turns the ASV table into a genus/family/... table
#    for the multi-level runs: rows 1 and 3 both belong to taxon "A" and are
#    summed per sample; the unassigned row (NA) is dropped and counted
#    (n_features_dropped) so the notebook can report the loss at that rank.
cnt <- data.frame(s1 = c(1, 2, 4, 8), s2 = c(0, 1, 0, 3))
agg <- aggregate_counts_by_taxon(cnt, c("A", "B", "A", NA))
ok("aggregation sums", identical(as.numeric(agg$counts["A", ]), c(5, 0)) &&
                       identical(as.numeric(agg$counts["B", ]), c(2, 1)))
ok("aggregation drop count", agg$n_features_dropped == 1)

# 6. normalize_abundance: core property — same composition at different depth
#    must give IDENTICAL rows after every TSS-based method.
#    Why it matters: studies are often sequenced to very different
#    depths, and an external test set to yet another. If depth leaked into
#    the features the classifier could learn "which study" instead of
#    the class label. Two samples with identical proportions, one 100x
#    deeper, are the minimal test of that. The remaining checks pin down
#    each method's definition (tss rows sum to 1, clr rows are centred,
#    "none" changes nothing) and that library sizes are kept for QC.
ab <- data.frame(t1 = c(10, 1000), t2 = c(30, 3000), t3 = c(60, 6000))
rownames(ab) <- c("shallow", "deep")   # deep = 100x the reads, same composition
for (m in c("tss", "tss_log", "tss_clr")) {
  nm <- normalize_abundance(ab, m)$data
  ok(paste("depth-invariance:", m), max(abs(as.numeric(nm[1, ]) - as.numeric(nm[2, ]))) < 1e-12)
}
ok("none is identity", identical(normalize_abundance(ab, "none")$data, ab))
ok("tss rows sum to 1", abs(sum(normalize_abundance(ab, "tss")$data[1, ]) - 1) < 1e-12)
ok("library sizes kept", identical(unname(normalize_abundance(ab, "tss")$library_sizes), c(100, 10000)))
# clr rows are centred (mean 0)
ok("clr centred", abs(mean(as.numeric(normalize_abundance(ab, "tss_clr")$data[1, ]))) < 1e-12)
# A sample with zero reads has no composition (0/0). The notebook finds these
# with find_empty_samples() and drops them; normalize_abundance() must refuse
# them rather than produce NaN rows that would train silently or crash later.
z <- rbind(ab, empty = c(0, 0, 0))
ok("empty sample detected", identical(find_empty_samples(z), "empty"))
ok("normalize refuses empty", inherits(try(normalize_abundance(z, "tss"), silent = TRUE), "try-error"))

# 7. align_features_to_reference: zero-fill, drop, order, coverage.
#    Used when the external test set (or any new sample) is pushed through a
#    trained model: its taxa must be laid out exactly like the training
#    columns A, B, C. Taxon D was never seen in training -> dropped; C is
#    absent here -> a zero column; column order fixed to the reference.
#    Coverage (share of a sample's reads inside the training feature space)
#    is exported next to the predictions as a warning sign: here half of
#    each sample's reads sit in the dropped taxon D, hence 50 %.
new <- data.frame(B = c(5, 0), D = c(5, 10), A = c(0, 10))   # D is novel; C missing
rownames(new) <- c("x", "y")
al <- align_features_to_reference(new, c("A", "B", "C"))
ok("aligned column order", identical(names(al$data), c("A", "B", "C")))
ok("novel dropped", identical(al$novel_features, "D"))
ok("missing zero-filled", identical(al$missing_features, "C") && all(al$data$C == 0))
ok("coverage math", identical(unname(al$pct_reads_covered), c(50, 50)))

cat("\nAll data-helper tests passed.\n")
