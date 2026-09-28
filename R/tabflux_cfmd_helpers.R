# cFMD input module: download a release of the curated Food
# Metagenomic Data (SegataLab/cFMD on GitHub) and write TabFlux's three input
# files (counts, taxa, metadata), so the notebook runs on public data with
# nothing changed downstream.
#
# cFMD: ~4,000 food metagenomes from >100 studies, profiled with MetaPhlAn 4
# into species-level genome bins (SGBs). One folder per dataset holds
# <dataset>_taxonomic_profiles.tsv (taxa in rows, samples in columns,
# relative abundances in percent, one row per full lineage
# "k__|p__|c__|o__|f__|g__|s__|t__SGBnnnn"). The root holds cFMD_metadata.tsv,
# one row per sample (dataset_name, sample_id, category, type, subtype,
# country, ...).
#
# Release formats differ. Handled up to v1.3.2 (checked 2026-09-15):
#   - first column named "sample" (most datasets) or "clade_name" (datasets
#     added in v1.3.2): taken by position, not by name;
#   - v1.3.0 shipped a spurious extra header line (empty first cell): any
#     non-lineage row is dropped, so it does no harm;
#   - up to v1.3.0 the profiles carried six metadata rows (category, type,
#     ...); v1.3.1 removed them, except in HeilCS_2018. Labels therefore
#     ALWAYS come from cFMD_metadata.tsv, never from the profiles;
#   - KawaiT_2012 and RippF_2014 have metadata but no profile file: skipped
#     (with a message only when `datasets` names them);
#   - v1.3.0 re-profiled everything with a newer database (vJan25): taxon
#     names differ from v1.2.1, so never mix releases. Pin `ref` to a tag.
#
# Data flow:
#   config input.cfmd  ->  cfmd_prepare_inputs()
#     1. one GitHub "git trees" API call lists every file of the release with
#        its blob SHA (no token needed for one call);
#     2. profiles and cFMD_metadata.tsv are downloaded from
#        raw.githubusercontent.com into cache_dir/<ref>/, skipped when the
#        cached copy carries the same SHA (manifest.rds);
#     3. profiles are parsed (lineage rows only), merged on the lineage,
#        samples below the completeness threshold dropped, datasets with too
#        few samples dropped;
#     4. three files are written to cache_dir/<ref>/subsets/<key>/, one
#        folder per dataset selection (<key> is a hash of the selection;
#        selection.txt inside the folder says what it was):
#          cfmd_<ref>_counts.csv.gz  feature_id + one column per sample
#                                    (relative abundance, percent)
#          cfmd_<ref>_taxa.csv.gz    feature_id, Kingdom ... Species, taxonomy
#          cfmd_<ref>_meta.csv       sample, dataset, category, type, ...
#        Their paths go to the notebook's settings chunk, which uses them like
#        input.counts_path / taxa_path / meta_path.
# "Counts" are percentages, not reads: the notebook's TSS step turns them back
# into proportions (idempotent - running it twice changes nothing).
# Set dataset.target = "category" (or "type", "subtype", "country") and
# dataset.group = "dataset", so that one dataset's samples are never split
# across a fold boundary.
#
# Sourced by analysis/tabflux.qmd ("sourcing pkgs" chunk) on every run;
# cfmd_prepare_inputs() is called from the settings chunk only when
# input.source = "cfmd". Uses base R + jsonlite + data.table + rlang (the
# hash that names a selection's folder), all installed with the notebook's
# packages.


# ── GitHub access ─────────────────────────────────────────────────────────────

# List every file of one release with its blob SHA.
# Input:  repo ("SegataLab/cFMD"), ref (tag / branch / commit), token
#         (optional; lifts the anonymous limit of 60 API calls per hour,
#         which one call per run never reaches).
# Output: data.frame(path, sha, size) for blobs only. The download step
#         compares against the SHA, so a re-tagged file is fetched again.
cfmd_list_release_files <- function(repo, ref, token = "") {
  url <- sprintf("https://api.github.com/repos/%s/git/trees/%s?recursive=1", repo, utils::URLencode(ref, reserved = TRUE))
  fetch_tree <- function(with_token) {
    headers <- c(Accept = "application/vnd.github+json")
    if (with_token) headers <- c(headers, Authorization = paste("Bearer", token))
    con <- url(url, headers = headers)
    on.exit(close(con), add = TRUE)
    jsonlite::fromJSON(paste(suppressWarnings(readLines(con, warn = FALSE)), collapse = "\n"))
  }
  # A stale or revoked GITHUB_TOKEN must not stop a public download: try the
  # token first (higher rate limit), fall back to an anonymous call.
  tree <- tryCatch(fetch_tree(nzchar(token)), error = function(e) {
    if (nzchar(token)) {
      message("cFMD: GitHub refused the GITHUB_TOKEN (", conditionMessage(e), "); retrying anonymously.")
      tryCatch(fetch_tree(FALSE), error = function(e2) {
        stop("Could not list the cFMD release '", ref, "' from GitHub (", conditionMessage(e2), ").")
      })
    } else {
      stop("Could not list the cFMD release '", ref, "' from GitHub (", conditionMessage(e), ").")
    }
  })
  if (isTRUE(tree$truncated)) stop("GitHub truncated the file list of '", ref, "'; the release is larger than the API allows in one call.")
  files <- tree$tree[tree$tree$type == "blob", c("path", "sha", "size"), drop = FALSE]
  rownames(files) <- NULL
  files
}

# Download one file of the release into the cache, unless the cached copy
# already carries the same SHA (manifest = named character vector path -> sha,
# kept as manifest.rds in the cache folder).
# Output: the local path.
cfmd_download_file <- function(repo, ref, path, sha, cache_dir, manifest, token = "") {
  local <- file.path(cache_dir, basename(path))
  if (file.exists(local) && identical(unname(manifest[path]), sha)) return(local)
  raw_url <- sprintf("https://raw.githubusercontent.com/%s/%s/%s", repo, ref, path)
  tmp <- paste0(local, ".part")
  # raw.githubusercontent.com serves public files without authentication and
  # has no API rate limit, so no token is sent here (a bad one would only hurt).
  # failure = "" when the download worked, otherwise R's own reason.
  failure <- tryCatch({
    utils::download.file(raw_url, tmp, quiet = TRUE, mode = "wb")
    ""
  }, error = function(e) conditionMessage(e), warning = function(w) conditionMessage(w))
  if (!nzchar(failure) && !file.exists(tmp)) failure <- "no file was written"
  if (nzchar(failure)) {
    if (file.exists(tmp)) unlink(tmp)
    # A cache folder that cannot be written fails here exactly like a network
    # problem, and needs a different fix, so say which one it is.
    # file.access() mode 2 tests write permission (0 = allowed).
    if (file.access(cache_dir, 2) != 0) failure <- paste0("the cache folder is not writable: ", cache_dir)
    stop("Download failed: ", raw_url, " (", failure, ")")
  }
  file.rename(tmp, local)
  local
}


# ── Parsing ───────────────────────────────────────────────────────────────────

# Read one profile file: lineage rows only, samples as columns, numeric.
# Input:  local TSV path, dataset name (for messages).
# Output: data.frame with column `lineage` (the full MetaPhlAn string) and one
#         numeric column per sample, named as in the file
#         ("<dataset>__<sample_id>"); NULL if the file holds no lineage row.
#         cfmd_prepare_inputs() merges these tables on `lineage`.
# The first column is taken by POSITION ("sample" or "clade_name", depending on
# the release). Rows not starting with "k__" are metadata rows or stray header
# lines, and are dropped.
cfmd_read_profile <- function(local_tsv, dataset) {
  dt <- data.table::fread(local_tsv, sep = "\t", header = TRUE, check.names = FALSE,
                          showProgress = FALSE, colClasses = "character")
  if (!ncol(dt) || !nrow(dt)) return(NULL)
  first <- names(dt)[1]
  lineage <- as.character(dt[[first]])
  keep <- startsWith(lineage, "k__")
  if (!any(keep)) {
    message("cFMD: no lineage rows in ", dataset, " (", basename(local_tsv), "); skipped.")
    return(NULL)
  }
  dropped <- sum(!keep)
  if (dropped) message("cFMD: ", dataset, ": ", dropped, " non-lineage row(s) dropped (metadata rows or stray header).")
  dt <- dt[keep]
  out <- data.frame(lineage = lineage[keep], stringsAsFactors = FALSE)
  for (col in setdiff(names(dt), first)) {
    out[[col]] <- suppressWarnings(as.numeric(dt[[col]]))
  }
  out
}

# Turn MetaPhlAn lineages into TabFlux's taxa table.
# Input:  character vector of lineages "k__Bacteria|p__Firmicutes|...|s__Lactococcus_lactis|t__SGB7985",
#         the row names of the merged abundance matrix.
# Output: data.frame(feature_id, Kingdom, Phylum, Class, Order, Family, Genus,
#         Species, sgb, taxonomy, lineage), one row per lineage; feature_id
#         names the counts rows. Only feature_id, the seven ranks and taxonomy
#         are written to the taxa file; sgb and lineage are returned but not
#         written out.
#   - feature_id = "<Genus>_<species>__<SGB label>", made unique; examples
#     below, at the assignment;
#   - Species = the EPITHET only, as TabFlux expects (the notebook pairs it
#     with Genus): "s__Lactococcus_lactis" with genus Lactococcus -> "lactis";
#     an unnamed species "s__GGB1234_SGB5678" keeps its full label;
#   - taxonomy = the seven cleaned fields joined by ";", which the data helpers
#     parse when a taxa table has no rank columns.
# Ranks missing from a lineage are left empty; clean_taxon_labels() in
# R/tabflux_data_helpers.R treats empty strings as unassigned.
cfmd_lineage_to_taxa <- function(lineages) {
  ranks <- c(k = "Kingdom", p = "Phylum", c = "Class", o = "Order", f = "Family", g = "Genus", s = "Species")
  parts <- strsplit(lineages, "|", fixed = TRUE)
  get_rank <- function(p, letter) {
    hit <- p[startsWith(p, paste0(letter, "__"))]
    if (length(hit)) sub("^[a-z]__", "", hit[1]) else ""
  }
  tab <- data.frame(lineage = lineages, stringsAsFactors = FALSE)
  for (letter in names(ranks)) tab[[ranks[[letter]]]] <- vapply(parts, get_rank, character(1), letter = letter)
  tab$sgb <- vapply(parts, get_rank, character(1), letter = "t")
  # Species: strip the leading "<Genus>_" so only the epithet remains.
  genus_prefix <- paste0("^", gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", tab$Genus), "_")
  has_genus <- nzchar(tab$Genus) & nzchar(tab$Species)
  tab$Species[has_genus] <- mapply(function(sp, pat) sub(pat, "", sp), tab$Species[has_genus], genus_prefix[has_genus])
  tab$taxonomy <- apply(tab[, unname(ranks), drop = FALSE], 1, paste, collapse = ";")
  # Feature id: the SGB code is MetaPhlAn 4's own identifier for the bin, so it
  # means the same organism in any profile from the same database version - but
  # "SGB7985" alone is unreadable in a SHAP plot, so prefix it with the finest
  # name available:
  #   Lactococcus_lactis__SGB7985   (named species)
  #   Pantoea__SGB10172             (genus only)
  #   SGB5678                       (unnamed at both ranks)
  name_part <- ifelse(nzchar(tab$Genus) & nzchar(tab$Species), paste0(tab$Genus, "_", tab$Species),
                ifelse(nzchar(tab$Genus), tab$Genus, ""))
  base_id <- ifelse(nzchar(tab$sgb), tab$sgb, paste0("lineage_", seq_along(lineages)))
  tab$feature_id <- make.unique(ifelse(nzchar(name_part), paste0(name_part, "__", base_id), base_id), sep = "_dup")
  tab[, c("feature_id", unname(ranks), "sgb", "taxonomy", "lineage")]
}


# ── Entry point ───────────────────────────────────────────────────────────────

# Download (or reuse) one cFMD release and write TabFlux's three input files.
# Input:  repo, ref, data_path ("cFMD_data"), datasets (dataset folder names to
#         keep; NULL / empty = all), completeness_threshold (minimum per-sample
#         abundance sum, percent), min_samples_per_dataset (smaller datasets
#         cannot support a held-out fold and are dropped), cache_dir
#         (downloads land in cache_dir/<ref>/), token (optional).
# Output: list(counts_path, taxa_path, meta_path, n_samples, n_features,
#         n_datasets, datasets), read by the notebook's settings chunk.
#         The three files go to cache_dir/<ref>/subsets/<key>/, one folder per
#         dataset selection. Re-running with the same ref reuses the
#         downloads and rewrites that selection's files (cheap); a run with
#         other settings writes to its own folder.
cfmd_prepare_inputs <- function(repo = "SegataLab/cFMD", ref = "v1.3.2", data_path = "cFMD_data",
                                datasets = NULL, completeness_threshold = 99, min_samples_per_dataset = 10L,
                                cache_dir = "input/cfmd_cache", token = Sys.getenv("GITHUB_TOKEN")) {
  ref_dir <- file.path(cache_dir, gsub("[^A-Za-z0-9._-]", "_", ref))
  dir.create(ref_dir, recursive = TRUE, showWarnings = FALSE)
  manifest_path <- file.path(ref_dir, "manifest.rds")
  manifest <- if (file.exists(manifest_path)) readRDS(manifest_path) else character(0)

  # Listing the release needs one GitHub API call (60 per hour anonymously). A
  # rate limit or no connection must not break a run whose files are already
  # cached: fall back to the manifest, which holds the same path -> hash pairs
  # the listing would return, so nothing is re-downloaded.
  files <- tryCatch(cfmd_list_release_files(repo, ref, token), error = function(e) {
    if (length(manifest)) {
      message("cFMD: GitHub is unreachable (", conditionMessage(e),
              "). Continuing from the cached release in ", ref_dir, ".")
      data.frame(path = names(manifest), sha = unname(manifest),
                 size = NA_integer_, stringsAsFactors = FALSE)
    } else {
      stop(conditionMessage(e), "\nNo cached copy of '", ref, "' exists in ", ref_dir,
           ", so there is nothing to fall back on. Wait for the rate limit to reset ",
           "(60 anonymous calls per hour) or set GITHUB_TOKEN.")
    }
  })
  profile_paths <- files$path[grepl(paste0("^", data_path, "/[^/]+/[^/]+_taxonomic_profiles\\.tsv$"), files$path)]
  meta_path_remote <- "cFMD_metadata.tsv"
  if (!meta_path_remote %in% files$path) stop("cFMD release '", ref, "' has no cFMD_metadata.tsv at the root.")
  dataset_of <- function(p) basename(dirname(p))
  available <- dataset_of(profile_paths)
  if (length(datasets)) {
    missing <- setdiff(datasets, available)
    if (length(missing)) message("cFMD: requested dataset(s) without a profile file, skipped: ", paste(missing, collapse = ", "))
    profile_paths <- profile_paths[available %in% datasets]
  }
  if (!length(profile_paths)) stop("cFMD: no profile files selected for release '", ref, "'.")
  message(sprintf("cFMD %s: %d dataset profile(s) to load (%d in the release).", ref, length(profile_paths), length(available)))

  # Downloads (cached by SHA); manifest saved after each file so an interrupted
  # run resumes where it stopped.
  local_of <- function(path) {
    sha <- files$sha[files$path == path]
    local <- cfmd_download_file(repo, ref, path, sha, ref_dir, manifest, token)
    manifest[path] <<- sha
    saveRDS(manifest, manifest_path)
    local
  }
  meta_local <- local_of(meta_path_remote)
  profiles <- list()
  for (p in profile_paths) {
    ds <- dataset_of(p)
    prof <- cfmd_read_profile(local_of(p), ds)
    if (!is.null(prof)) profiles[[ds]] <- prof
  }
  if (!length(profiles)) stop("cFMD: no profile could be read.")

  # Merge on the lineage: a taxon absent from a dataset is 0 there.
  merged <- Reduce(function(a, b) merge(a, b, by = "lineage", all = TRUE), profiles)
  sample_cols <- setdiff(names(merged), "lineage")
  merged[sample_cols][is.na(merged[sample_cols])] <- 0
  abundance <- as.matrix(merged[, sample_cols, drop = FALSE])
  rownames(abundance) <- merged$lineage

  # Completeness: profiles of recent releases sum to 100 per sample; older
  # ones carried an UNCLASSIFIED share that is not in the file.
  sums <- colSums(abundance)
  keep_sample <- sums >= completeness_threshold
  if (any(!keep_sample)) message("cFMD: ", sum(!keep_sample), " sample(s) below the completeness threshold dropped.")
  abundance <- abundance[, keep_sample, drop = FALSE]

  # Metadata: one row per sample, keyed as "<dataset_name>__<sample_id>", the
  # column names of the profiles. Only samples present in both are kept.
  meta <- data.table::fread(meta_local, sep = "\t", header = TRUE, check.names = FALSE,
                            showProgress = FALSE, colClasses = "character")
  meta <- as.data.frame(meta, stringsAsFactors = FALSE)
  if (!all(c("dataset_name", "sample_id") %in% names(meta))) stop("cFMD_metadata.tsv lacks dataset_name / sample_id columns.")
  meta_key <- paste0(meta$dataset_name, "__", meta$sample_id)
  common <- intersect(colnames(abundance), meta_key)
  no_meta <- setdiff(colnames(abundance), meta_key)
  if (length(no_meta)) message("cFMD: ", length(no_meta), " profiled sample(s) without a metadata row dropped.")
  abundance <- abundance[, common, drop = FALSE]
  meta <- meta[match(common, meta_key), , drop = FALSE]

  # Drop small datasets (a held-out fold needs enough samples to be scored).
  n_by_ds <- table(meta$dataset_name)
  small <- names(n_by_ds)[n_by_ds < min_samples_per_dataset]
  if (length(small)) {
    message("cFMD: dataset(s) with fewer than ", min_samples_per_dataset, " samples dropped: ", paste(small, collapse = ", "))
    keep <- !(meta$dataset_name %in% small)
    abundance <- abundance[, keep, drop = FALSE]
    meta <- meta[keep, , drop = FALSE]
  }
  # Taxa never seen in the kept samples are dropped.
  abundance <- abundance[rowSums(abundance) > 0, , drop = FALSE]

  # Output tables in TabFlux's three-file layout.
  taxa <- cfmd_lineage_to_taxa(rownames(abundance))
  counts <- data.frame(feature_id = taxa$feature_id, abundance, check.names = FALSE, stringsAsFactors = FALSE)
  names(meta) <- gsub("/", "_", names(meta), fixed = TRUE)    # "fermented/non-fermented" -> a plain column name
  # The curated fermentation flag is cFMD's most useful binary target, but its
  # name carries a slash and its values are one-letter codes. Add a `fermented`
  # column with the classes spelled out, so the target, the class labels in
  # every plot and `dataset.positive_class` read "fermented" / "non_fermented".
  ferm_col <- grep("^fermented_non", names(meta), value = TRUE)[1]
  if (!is.na(ferm_col)) {
    meta$fermented <- c(F = "fermented", NF = "non_fermented")[as.character(meta[[ferm_col]])]
    meta$fermented[is.na(meta$fermented)] <- ""
  }
  # meta rows were aligned to the abundance columns above and filtered in step
  # with them, so the sample key is the column order.
  meta_out <- data.frame(sample = colnames(abundance),
                         dataset = meta$dataset_name, meta[, setdiff(names(meta), c("dataset_name")), drop = FALSE],
                         check.names = FALSE, stringsAsFactors = FALSE)

  # Each selection gets its own folder under the cache. With one shared file
  # name per release, every run would overwrite the previous run's input, and
  # two runs sharing a cache (e.g. a demo and a full run) could swap each
  # other's input between taxonomic levels. The key covers everything that
  # shapes the selection; selection.txt says what it was.
  selection <- list(datasets = if (is.null(datasets)) "all" else sort(datasets),
                    completeness_threshold = completeness_threshold,
                    min_samples_per_dataset = min_samples_per_dataset)
  subset_dir <- file.path(ref_dir, "subsets", substr(rlang::hash(selection), 1, 12))
  dir.create(subset_dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(c(sprintf("datasets: %s", paste(selection$datasets, collapse = ", ")),
               sprintf("completeness_threshold: %s", completeness_threshold),
               sprintf("min_samples_per_dataset: %s", min_samples_per_dataset),
               sprintf("written: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))),
             file.path(subset_dir, "selection.txt"))
  stem <- file.path(subset_dir, paste0("cfmd_", gsub("[^A-Za-z0-9._-]", "_", ref)))
  counts_path <- paste0(stem, "_counts.csv.gz"); taxa_path <- paste0(stem, "_taxa.csv.gz"); meta_path <- paste0(stem, "_meta.csv")
  data.table::fwrite(counts, counts_path, compress = "gzip")
  data.table::fwrite(taxa[, c("feature_id", "Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species", "taxonomy")], taxa_path, compress = "gzip")
  data.table::fwrite(meta_out, meta_path)
  message(sprintf("cFMD %s: %d samples x %d taxa from %d datasets written to %s", ref, ncol(abundance), nrow(abundance),
                  length(unique(meta_out$dataset)), subset_dir))
  list(counts_path = counts_path, taxa_path = taxa_path, meta_path = meta_path,
       n_samples = ncol(abundance), n_features = nrow(abundance),
       n_datasets = length(unique(meta_out$dataset)), datasets = sort(unique(meta_out$dataset)))
}
