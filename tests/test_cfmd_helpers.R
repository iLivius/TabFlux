# Tests for R/tabflux_cfmd_helpers.R — plain script, no framework, no network.
# Run from the repository root inside the tabflux-r environment:
#   Rscript tests/test_cfmd_helpers.R
# The network part (listing and downloading a release) is exercised only when
# TABFLUX_CFMD_NETWORK_TESTS=1 is set; everything else runs on small fixtures
# written here, one per profile-file variant seen in cFMD releases up to
# v1.3.2: the plain "sample" header, the "clade_name" header of v1.3.2, the
# leftover metadata rows of HeilCS_2018 / pre-1.3.1 files, and the spurious
# extra header line of v1.3.0.
suppressMessages({ library(data.table); library(jsonlite) })
source(file.path("R", "tabflux_cfmd_helpers.R"))
ok <- function(label, cond) { stopifnot(cond); cat("PASS:", label, "\n") }
tmp <- file.path(tempdir(), "cfmd_fixtures"); dir.create(tmp, showWarnings = FALSE)

lin1 <- "k__Bacteria|p__Firmicutes|c__Bacilli|o__Lactobacillales|f__Streptococcaceae|g__Lactococcus|s__Lactococcus_lactis|t__SGB7985"
lin2 <- "k__Bacteria|p__Pseudomonadota|c__Gammaproteobacteria|o__Enterobacterales|f__Erwiniaceae|g__Pantoea|s__Pantoea_dispersa|t__SGB10172"
lin3 <- "k__Bacteria|p__Firmicutes|c__Bacilli|o__Lactobacillales|f__Lactobacillaceae|g__GGB1234|s__GGB1234_SGB5678|t__SGB5678"

# ── 1. profile variants ──────────────────────────────────────────────────────
write_profile <- function(path, header, extra_top = NULL, meta_rows = NULL) {
  lines <- c(extra_top,
             paste(c(header, "dsA__S1", "dsA__S2"), collapse = "\t"),
             meta_rows,
             paste(c(lin1, "60.5", "0.0"), collapse = "\t"),
             paste(c(lin2, "39.5", "100.0"), collapse = "\t"))
  writeLines(lines, path); path
}
p_plain <- write_profile(file.path(tmp, "dsA_taxonomic_profiles.tsv"), "sample")
p_clade <- write_profile(file.path(tmp, "dsB_taxonomic_profiles.tsv"), "clade_name")
p_meta  <- write_profile(file.path(tmp, "dsC_taxonomic_profiles.tsv"), "sample",
                         meta_rows = c("macrocategory\tfood\tfood", "category\tdairy\tdairy", "country\tITA\tITA"))
p_130   <- write_profile(file.path(tmp, "dsD_taxonomic_profiles.tsv"), "sample", extra_top = "\tdsD\tdsD")

a <- cfmd_read_profile(p_plain, "dsA")
ok("plain header: two lineage rows, numeric sample columns",
   nrow(a) == 2 && identical(names(a), c("lineage", "dsA__S1", "dsA__S2")) && is.numeric(a$dsA__S1) && a$dsA__S1[1] == 60.5)
b <- cfmd_read_profile(p_clade, "dsB")
ok("clade_name header read by position, same result", identical(b$lineage, a$lineage) && identical(b$dsA__S2, a$dsA__S2))
m <- suppressMessages(cfmd_read_profile(p_meta, "dsC"))
ok("embedded metadata rows dropped, lineages kept", nrow(m) == 2 && all(startsWith(m$lineage, "k__")))
d <- suppressMessages(cfmd_read_profile(p_130, "dsD"))
ok("v1.3.0 extra header line survives as a dropped row", nrow(d) == 2 && identical(d$lineage, a$lineage))
writeLines("sample\tdsE__S1\nmacrocategory\tfood", file.path(tmp, "dsE_taxonomic_profiles.tsv"))
ok("file with no lineage rows gives NULL", is.null(suppressMessages(cfmd_read_profile(file.path(tmp, "dsE_taxonomic_profiles.tsv"), "dsE"))))

# ── 2. lineage -> taxa table ─────────────────────────────────────────────────
tx <- cfmd_lineage_to_taxa(c(lin1, lin2, lin3, "k__Bacteria|p__Firmicutes"))
ok("rank columns filled from the lineage", tx$Phylum[1] == "Firmicutes" && tx$Genus[2] == "Pantoea" && tx$Kingdom[4] == "Bacteria")
ok("species column holds the epithet only (genus prefix stripped)", tx$Species[1] == "lactis" && tx$Species[2] == "dispersa")
ok("unnamed species keeps its label", tx$Species[3] == "SGB5678" && tx$Genus[3] == "GGB1234")
ok("feature ids are <Genus>_<species>__<SGB>, unique",
   identical(tx$feature_id[1:3], c("Lactococcus_lactis__SGB7985", "Pantoea_dispersa__SGB10172", "GGB1234_SGB5678__SGB5678")) && !anyDuplicated(tx$feature_id))
ok("truncated lineage leaves deeper ranks empty and gets a lineage id",
   tx$Class[4] == "" && tx$Species[4] == "" && startsWith(tx$feature_id[4], "lineage_"))
# Count the ";" separators rather than split: strsplit() drops trailing empty
# fields, so "Bacteria;Firmicutes;;;;;" would look like two fields.
ok("taxonomy string has seven fields (six separators), also when truncated",
   all(nchar(gsub("[^;]", "", tx$taxonomy)) == 6L))
dup <- cfmd_lineage_to_taxa(c(lin1, lin1))
ok("duplicate lineages get distinct ids", !anyDuplicated(dup$feature_id))

# ── 3. network (optional) ────────────────────────────────────────────────────
if (identical(Sys.getenv("TABFLUX_CFMD_NETWORK_TESTS"), "1")) {
  files <- cfmd_list_release_files("SegataLab/cFMD", "v1.3.2")
  ok("release listing has the root metadata and per-dataset profiles",
     "cFMD_metadata.tsv" %in% files$path && sum(grepl("_taxonomic_profiles\\.tsv$", files$path)) >= 100)
  out <- cfmd_prepare_inputs(ref = "v1.3.2", datasets = c("AlmeidaO_2020", "HeilCS_2018"),
                             min_samples_per_dataset = 1L, cache_dir = file.path(tmp, "cache"))
  ok("two small datasets produce the three files", all(file.exists(c(out$counts_path, out$taxa_path, out$meta_path))) && out$n_datasets == 2)
}
cat("\nAll cFMD-helper tests passed.\n")
