# Tests for the per-class SHAP helpers in R/tabflux_figure_helpers.R — plain
# script, no framework. Run from the repository root:
#   Rscript tests/test_figure_helpers.R
# (save_report_figure() is tested in tests/test_summary_helpers.R.)
#
# Checks that shap_class_summary() ranks a taxon by mean |phi| even when its
# signed mean cancels to about zero, that the direction follows the sign of
# the Spearman correlation (and is "no variation" when the taxon's value never
# changes), that the two means equal hand computations, and that
# plot_shap_by_class() draws one panel per class with at most top_n bars, or
# one panel for the positive class of a binary target.
source(file.path("R", "tabflux_figure_helpers.R"))
ok <- function(label, cond) { stopifnot(cond); cat("PASS:", label, "\n") }

# ── Toy SHAP table: 20 samples x 3 classes (A, B, C) x 7 taxa ────────────────
# Same shape as the notebook's shap_export: one row per sample x taxon x class,
# with the SHAP value phi and the value the model saw (value_model).
#   strong   - abundant (value 1) in half the samples, absent (value 0) in the
#              other half. For class A it adds +0.30 to P(A) when abundant and
#              removes 0.30 when absent: the signed mean is 0, the mean |phi|
#              is the largest of the table, and more of it = higher P(A).
#   negative - a gradient of values; its phi for A falls as the value rises,
#              so more of it = lower P(A).
#   constant - the same value in every sample; its phi varies, but there is no
#              variation in the taxon to correlate with.
#   weak1..4 - small random effects, only there so that class A has more taxa
#              than the default top_n of 5.
n_samples <- 20
classes <- c("A", "B", "C")
taxa <- c("strong", "negative", "constant", "weak1", "weak2", "weak3", "weak4")
set.seed(42)

value_of <- list(
  strong   = rep(c(1, 0), length.out = n_samples),
  negative = seq(0, 1, length.out = n_samples),
  constant = rep(0.5, n_samples),
  weak1    = runif(n_samples),
  weak2    = runif(n_samples),
  weak3    = runif(n_samples),
  weak4    = runif(n_samples)
)

rows <- list()
for (taxon in taxa) {
  value <- value_of[[taxon]]
  for (cl in classes) {
    if (taxon == "strong" && cl == "A") {
      phi <- ifelse(value == 1, 0.30, -0.30)
    } else if (taxon == "negative" && cl == "A") {
      phi <- 0.10 - 0.20 * value          # falls as the value rises
    } else if (taxon == "constant") {
      phi <- rnorm(n_samples, 0, 0.02)
    } else {
      phi <- rnorm(n_samples, 0, 0.01)
    }
    rows[[length(rows) + 1]] <- data.frame(
      sample_id = seq_len(n_samples), feature = taxon, class = cl,
      phi = phi, value_model = value, stringsAsFactors = FALSE
    )
  }
}
shap_long <- do.call(rbind, rows)
shap_long <- shap_long[sample(nrow(shap_long)), ]   # row order must not matter

# ── shap_class_summary() ─────────────────────────────────────────────────────
summary_tab <- shap_class_summary(shap_long)
ok("one row per taxon x class, with the documented columns",
   nrow(summary_tab) == length(taxa) * length(classes) &&
     identical(names(summary_tab),
               c("feature", "class", "mean_phi", "mean_abs_phi", "direction_rho", "direction")))

row_of <- function(taxon, cl) summary_tab[summary_tab$feature == taxon & summary_tab$class == cl, ]
strong_A <- row_of("strong", "A")
ok("the cancelling taxon has a signed mean of about 0 ...", abs(strong_A$mean_phi) < 1e-12)
class_A <- summary_tab[summary_tab$class == "A", ]
ok("... but ranks first for class A by mean |phi|",
   class_A$feature[1] == "strong" && strong_A$mean_abs_phi == max(class_A$mean_abs_phi))
ok("more of the strong taxon = higher P(A)",
   strong_A$direction == "more of it: higher P(class)" && strong_A$direction_rho > 0.99)

negative_A <- row_of("negative", "A")
ok("a taxon whose phi falls with its value is labelled 'lower'",
   negative_A$direction == "more of it: lower P(class)" && negative_A$direction_rho < -0.99)

constant_rows <- summary_tab[summary_tab$feature == "constant", ]
ok("a taxon with a constant value gets NA rho and 'no variation'",
   all(is.na(constant_rows$direction_rho)) && all(constant_rows$direction == "no variation"))

# Hand computations for two cells, straight from the long table.
for (cell in list(c("negative", "A"), c("weak2", "C"))) {
  phi_cell <- shap_long$phi[shap_long$feature == cell[1] & shap_long$class == cell[2]]
  got <- row_of(cell[1], cell[2])
  ok(paste0("mean_phi and mean_abs_phi of ", cell[1], " x ", cell[2], " match the hand computation"),
     isTRUE(all.equal(got$mean_phi, mean(phi_cell))) &&
       isTRUE(all.equal(got$mean_abs_phi, mean(abs(phi_cell)))))
}

ok("rows are sorted by class, strongest taxon first",
   all(sapply(split(summary_tab$mean_abs_phi, summary_tab$class),
              function(x) !is.unsorted(rev(x)))))

missing_col <- try(shap_class_summary(shap_long[, c("feature", "class", "phi")]), silent = TRUE)
ok("a table without value_model stops with a clear message",
   inherits(missing_col, "try-error") && grepl("value_model", missing_col))

# ── plot_shap_by_class(): multi-class ────────────────────────────────────────
multi_plot <- plot_shap_by_class(summary_tab, method_label = "Random Forest")
multi_built <- ggplot2::ggplot_build(multi_plot)
bars <- multi_built$data[[1]]
ok("multi-class: one panel per class", nrow(multi_built$layout$layout) == length(classes))
ok("multi-class: at most 5 bars per panel by default (class A has 7 taxa)",
   all(table(bars$PANEL) <= 5) && max(table(bars$PANEL)) == 5)
ok("the title names the method",
   grepl("Random Forest", multi_plot$labels$title))

# In panel A the strong taxon's bar is on top (largest y position).
panel_of_A <- multi_built$layout$layout$PANEL[multi_built$layout$layout$class == "A"]
bars_A <- bars[bars$PANEL == panel_of_A, ]
top_bar_A <- bars_A[which.max(bars_A$y), ]
ok("panel A: the strong taxon's bar is on top and is the longest",
   isTRUE(all.equal(top_bar_A$xmax, strong_A$mean_abs_phi)) && top_bar_A$xmax == max(bars_A$xmax))

# The axis shows taxon names only, without the "___class" suffix.
y_labels <- multi_built$layout$panel_params[[as.integer(panel_of_A)]]$y$get_labels()
ok("axis labels are plain taxon names", "strong" %in% y_labels && !any(grepl("___", y_labels)))

few_plot <- ggplot2::ggplot_build(plot_shap_by_class(summary_tab, "RF", top_n = 2))
ok("an explicit top_n is respected", all(table(few_plot$data[[1]]$PANEL) == 2))

# ── plot_shap_by_class(): binary ─────────────────────────────────────────────
# Two classes, 12 taxa: one panel for the positive class, default top_n = 10.
binary_long <- shap_long[shap_long$class %in% c("A", "B"), ]
extra <- lapply(1:5, function(k) {
  data.frame(sample_id = seq_len(n_samples), feature = paste0("extra", k),
             class = rep(c("A", "B"), each = n_samples),
             phi = rnorm(2 * n_samples, 0, 0.01),
             value_model = rep(runif(n_samples), 2), stringsAsFactors = FALSE)
})
binary_long <- rbind(binary_long, do.call(rbind, extra))
binary_summary <- shap_class_summary(binary_long)

binary_built <- ggplot2::ggplot_build(plot_shap_by_class(binary_summary, "TabPFN", positive_class = "B"))
ok("binary: one panel, for the positive class",
   nrow(binary_built$layout$layout) == 1 && as.character(binary_built$layout$layout$class) == "B")
ok("binary: 10 bars by default", nrow(binary_built$data[[1]]) == 10)

fallback_built <- ggplot2::ggplot_build(plot_shap_by_class(binary_summary, "TabPFN", positive_class = ""))
ok("binary without a usable positive class: the alphabetically first class",
   as.character(fallback_built$layout$layout$class) == "A")

ok("an empty table gives NULL, not an error",
   is.null(suppressMessages(plot_shap_by_class(binary_summary[0, ], "TabPFN"))))

cat("\nAll figure-helper tests passed.\n")
