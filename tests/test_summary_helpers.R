# Tests for R/tabflux_summary_helpers.R and for the multi-level wrapper that
# uses them (scripts/run_multi_tax_levels.R) — plain script, no framework.
# Run from the repository root:  Rscript tests/test_summary_helpers.R
# Checks that the wide site-by-rank table has the expected shape, that the
# mean row is the plain average over sites, that a site missing at one rank
# gives NA rather than a shifted value, that the figure's subtitle follows the
# nested flag, and that the wrapper creates a missing output.dir.
source(file.path("R", "tabflux_summary_helpers.R"))
ok <- function(label, cond) { stopifnot(cond); cat("PASS:", label, "\n") }

# Toy long table: 2 ranks x 2 methods x 3 sites, as read_level_metrics() gives it.
long <- expand.grid(tax_level = c("genus", "family"), method = c("TabPFN", "Random Forest"),
                    heldout_dataset = c("siteA", "siteB", "siteC"), stringsAsFactors = FALSE)
long$n_test <- c(siteA = 10L, siteB = 20L, siteC = 30L)[long$heldout_dataset]
set.seed(1)
long$`balanced accuracy` <- round(runif(nrow(long), 0.4, 1), 4)
long$auc <- round(runif(nrow(long), 0.4, 1), 4)
long <- long[sample(nrow(long)), ]              # row order must not matter
long <- long[!(long$tax_level == "family" & long$heldout_dataset == "siteC" & long$method == "TabPFN"), ]  # one hole

wide <- pivot_lodo_metrics_wide(long, level_order = c("family", "genus"))
ok("one block per method x metric, sites + mean row each",
   nrow(wide) == 2 * 2 * (3 + 1))
ok("rank columns follow level_order, after the four id columns",
   identical(names(wide), c("method", "metric", "heldout_dataset", "n_test", "family", "genus")))
tab_row <- wide[wide$method == "TabPFN" & wide$metric == "auc" & wide$heldout_dataset == "siteB", ]
ok("a cell holds the right site x rank x method value",
   tab_row$genus == long$auc[long$method == "TabPFN" & long$tax_level == "genus" & long$heldout_dataset == "siteB"])
mean_row <- wide[wide$method == "TabPFN" & wide$metric == "auc" & wide$heldout_dataset == "mean", ]
ok("mean row = average over sites", isTRUE(all.equal(
  mean_row$genus, round(mean(long$auc[long$method == "TabPFN" & long$tax_level == "genus"]), 4))))
ok("a site missing at one rank gives NA, and the mean skips it",
   is.na(wide$family[wide$method == "TabPFN" & wide$metric == "auc" & wide$heldout_dataset == "siteC"]) &&
     !is.na(mean_row$family))
ok("n_test carried per site", all(wide$n_test[wide$heldout_dataset == "siteC"] == 30L))
ok("a metric absent from the table is skipped",
   nrow(pivot_lodo_metrics_wide(long, c("family", "genus"), metrics = c("auc", "pr auc"))) == 2 * (3 + 1))

if (requireNamespace("ggplot2", quietly = TRUE)) {
  p_nested <- plot_lodo_metrics_by_level(long, c("family", "genus"), nested = TRUE)
  p_plain <- plot_lodo_metrics_by_level(long, c("family", "genus"), nested = FALSE)
  ok("figure is a ggplot with the nested subtitle", inherits(p_nested, "ggplot") && grepl("Nested", p_nested$labels$subtitle))
  ok("non-nested subtitle says so", grepl("Internal estimates", p_plain$labels$subtitle))
}
# ── shorten_heldout_label(): grouped CV produces unusable axis labels ────────
# Under LODO a fold holds one group and its name is fine. Under grouped CV the
# label is every group in the fold joined by ";" - on the cFMD category run, 12
# dataset names and 197 characters, which pushes the whole plot off the canvas.
long_lab <- paste(sprintf("Dataset_%02d_2020", 1:12), collapse = ";")
out <- shorten_heldout_label(c("siteA", long_lab), iteration = c(1, 2))
stopifnot(out[1] == "siteA", out[2] == "fold 2 (12 groups)")
cat("PASS: short labels pass through, concatenated ones become 'fold i (k groups)'\n")
stopifnot(identical(shorten_heldout_label(c("A", "B"), 1:2), c("A", "B")))
cat("PASS: a pure LODO table is left untouched\n")
stopifnot(shorten_heldout_label(strrep("x", 60), 3) == "fold 3 (1 groups)")
cat("PASS: one very long group name is shortened too\n")

# ── lodo_chance_level(): 0.5 is only right for a binary target ───────────────
stopifnot(lodo_chance_level(data.frame(class_counts = c("a=10; b=5", "a=8; b=7"))) == 0.5)
cat("PASS: two classes give chance 0.5\n")
seven <- paste(sprintf("c%d=%d", 1:7, 10:16), collapse = "; ")
stopifnot(abs(lodo_chance_level(data.frame(class_counts = rep(seven, 3))) - 1/7) < 1e-9)
cat("PASS: seven classes give chance 1/7, not 0.5\n")
# A fold whose test part missed a class still lists it with a zero count, so the
# class set stays complete across folds.
mixed <- data.frame(class_counts = c("a=10; b=0; c=3", "a=2; b=6; c=0"))
stopifnot(abs(lodo_chance_level(mixed) - 1/3) < 1e-9)
cat("PASS: classes absent from a fold still count towards the chance level\n")
stopifnot(lodo_chance_level(data.frame(x = 1)) == 0.5)
cat("PASS: a table without class_counts falls back to 0.5\n")

# ── save_report_figure(): the presentation-quality copies ───────────────────
source(file.path("R", "tabflux_figure_helpers.R"))
fig_dir <- file.path(tempdir(), "figtest"); dir.create(fig_dir, showWarnings = FALSE)
pl <- ggplot2::ggplot(data.frame(x = 1:3, y = 1:3), ggplot2::aes(x, y)) + ggplot2::geom_point()
out <- save_report_figure(pl, "my figure/name", fig_dir)
stopifnot(length(out) >= 1, all(file.exists(out)))
cat("PASS: save_report_figure writes its files\n")
stopifnot(dir.exists(file.path(fig_dir, "figures")))
cat("PASS: they land in a figures/ subfolder of the run\n")
stopifnot(all(grepl("my_figure_name", basename(out))))
cat("PASS: an unsafe file name is made safe\n")
if (requireNamespace("svglite", quietly = TRUE)) {
  stopifnot(any(grepl("\\.png$", out)), any(grepl("\\.svg$", out)))
  cat("PASS: both a raster and a vector copy are written\n")
}
stopifnot(identical(save_report_figure(NULL, "nothing", fig_dir), character(0)))
cat("PASS: a missing plot is a no-op, not an error\n")

# ── the multi-level wrapper creates output.dir when it does not exist ───────
# scripts/run_multi_tax_levels.R resolves output.dir the way the notebook does
# (a relative path is taken from the project root) and creates the folder when
# it is missing, instead of stopping. No full render is needed to check this:
# the wrapper creates the output folder, and the combined-results folder
# inside it, before its first child render. So the test builds a throw-away
# project (config.yaml, the two R/ helpers the wrapper sources, an empty
# input/, and a notebook with broken front matter that Quarto rejects in about
# a second), runs the wrapper on it, and checks the folders although the
# render itself fails. Needs the Quarto CLI and the yaml package, both in the
# container; skipped without them.
wrapper_script <- file.path("scripts", "run_multi_tax_levels.R")
if (nzchar(Sys.which("quarto")) && file.exists(wrapper_script) &&
    requireNamespace("yaml", quietly = TRUE)) {

  # Build the throw-away project with the given output.dir value, run the
  # wrapper from its root, and return the root plus the wrapper's exit status
  # and console output.
  run_wrapper_with_output_dir <- function(output_dir_value) {
    root <- tempfile("wrapper_root_")
    for (d in c("R", "input", "analysis", "scripts")) {
      dir.create(file.path(root, d), recursive = TRUE)
    }
    file.copy(file.path("R", c("tabflux_config_helpers.R", "tabflux_summary_helpers.R")),
              file.path(root, "R"))
    file.copy(wrapper_script, file.path(root, "scripts"))
    writeLines(c("---", "title: [unclosed", "---"), file.path(root, "analysis", "broken.qmd"))
    # ranger only, so the wrapper skips its TabPFN environment lookup.
    yaml::write_yaml(
      list(methods = list(pick = list("ranger")),
           dataset = list(id = "wraptest", version = "v1", tax_level = ""),
           output = list(dir = output_dir_value, run_date = "2026-01-01")),
      file.path(root, "config.yaml")
    )
    old_wd <- setwd(root)
    on.exit(setwd(old_wd))
    console <- suppressWarnings(system2(
      file.path(R.home("bin"), "Rscript"),
      c(file.path("scripts", "run_multi_tax_levels.R"), "config.yaml", file.path("analysis", "broken.qmd")),
      stdout = TRUE, stderr = TRUE
    ))
    list(root = root, status = attr(console, "status"), console = console)
  }

  combined_name <- "2026-01-01_wraptest_v1_multi_tax_results"

  # Relative output.dir, two levels that do not exist yet.
  rel <- run_wrapper_with_output_dir("results/new")
  rel_dir <- file.path(rel$root, "results", "new")
  if (!dir.exists(rel_dir)) cat(rel$console, sep = "\n")
  ok("wrapper creates a missing relative output.dir under the project root", dir.exists(rel_dir))
  ok("the combined-results folder is created inside it",
     dir.exists(file.path(rel_dir, combined_name)))
  ok("the broken notebook then stops the run (the test render really failed)",
     !is.null(rel$status) && rel$status != 0 && any(grepl("Child render failed", rel$console)))

  # Absolute output.dir, outside the project.
  abs_dir <- file.path(tempfile("abs_out_"), "deeper")
  abs_run <- run_wrapper_with_output_dir(abs_dir)
  if (!dir.exists(abs_dir)) cat(abs_run$console, sep = "\n")
  ok("wrapper creates a missing absolute output.dir",
     dir.exists(abs_dir) && dir.exists(file.path(abs_dir, combined_name)))
} else {
  cat("SKIP: wrapper output.dir test (needs the Quarto CLI, scripts/ and yaml)\n")
}

cat("\nAll summary-helper tests passed.\n")
