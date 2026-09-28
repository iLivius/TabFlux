# Report figures: saving them at presentation quality, and the per-class
# SHAP figure.
#
# Part 1 - saving. The figures inside the HTML report are sized for the
# report: fine to read on screen, too small and too coarse to drop into a
# slide or a manuscript. save_report_figure() writes the same plot again,
# larger and at print resolution, into a figures/ folder next to the run's
# metrics/, in two formats:
#
#   PNG  raster, 300 dpi - for slides, posters and anything that wants pixels;
#   SVG  vector          - for a manuscript figure, because it can be scaled or
#                          edited (fonts, colours, panel order) in Inkscape or
#                          Illustrator without going blurry.
#
# Part 2 - which taxa drive each class. shap_class_summary() condenses the
# per-sample SHAP values of the final model into one row per taxon x class, and
# plot_shap_by_class() draws the strongest taxa of each class from that table.
# See the comment above shap_class_summary() for why the figure shows mean |phi|
# and a correlation-based direction instead of the signed mean.
#
# Sourced by analysis/tabflux.qmd; tested by tests/test_figure_helpers.R and
# tests/test_summary_helpers.R. The saving helpers fail softly: a run
# without ggplot2 or svglite loses the exported copies, never the analysis.


# Create (once) the figures/ folder of a run and return its path.
# Input:  save_dir - the run folder (the same one metrics/ lives in).
# Output: the path, invisibly. Safe to call repeatedly.
tabflux_figure_dir <- function(save_dir) {
  path <- file.path(save_dir, "figures")
  if (!dir.exists(path)) dir.create(path, recursive = TRUE, showWarnings = FALSE)
  invisible(path)
}


# Write one ggplot as PNG + SVG at presentation size.
#
# Input:  plot     - a ggplot object (anything ggplot2::ggsave accepts);
#         name     - file stem, no extension. Keep it descriptive and stable:
#                    these names are what a user cites in a slide deck, and the
#                    documentation links to them by name;
#         save_dir - the run folder; the files land in its figures/ subfolder;
#         width, height - inches. The defaults suit a 16:9 slide;
#         dpi      - raster resolution for the PNG. 300 is print quality.
# Output: character vector of the files written (invisibly). Failures are
#         reported as a message and never stop the run: an exported copy is a
#         convenience, and losing it must not cost a four-hour analysis.
save_report_figure <- function(plot, name, save_dir, width = 10, height = 6.5, dpi = 300) {
  if (is.null(plot) || !requireNamespace("ggplot2", quietly = TRUE)) return(invisible(character(0)))
  dir_path <- tabflux_figure_dir(save_dir)
  stem <- file.path(dir_path, gsub("[^A-Za-z0-9._-]+", "_", name))
  written <- character(0)

  ok <- try(suppressMessages(suppressWarnings(
    ggplot2::ggsave(paste0(stem, ".png"), plot, width = width, height = height, dpi = dpi, bg = "white")
  )), silent = TRUE)
  if (!inherits(ok, "try-error")) written <- c(written, paste0(stem, ".png"))

  # SVG needs the svglite device; without it, the PNG alone is still written.
  if (requireNamespace("svglite", quietly = TRUE)) {
    ok <- try(suppressMessages(suppressWarnings(
      ggplot2::ggsave(paste0(stem, ".svg"), plot, width = width, height = height, device = svglite::svglite, bg = "white")
    )), silent = TRUE)
    if (!inherits(ok, "try-error")) written <- c(written, paste0(stem, ".svg"))
  }

  if (!length(written)) message("Could not export the figure '", name, "'; the report copy is unaffected.")
  invisible(written)
}


# Print a plot into the report AND export it, in one call.
# Saves writing `print(p)` and `save_report_figure(p, ...)` side by side at every
# figure, which is how one of the two ends up forgotten.
# Input/Output: as save_report_figure(); the plot is printed as a side effect.
show_and_save_figure <- function(plot, name, save_dir, width = 10, height = 6.5, dpi = 300) {
  print(plot)
  save_report_figure(plot, name, save_dir, width = width, height = height, dpi = dpi)
}


# ── Per-class SHAP figure ─────────────────────────────────────────────────────
#
# What a SHAP value is here: phi = how far one taxon's value in one sample
# moved the model's predicted probability of one class away from the model's
# average prediction (positive = towards that class, negative = away from it).
# The notebook computes one phi per sample x taxon x class for the final model.
#
# Why the figure does not plot the signed mean of phi. SHAP values are measured
# against the average prediction, so over the explained samples a taxon's
# pushes up (in samples where it is abundant) and down (in samples where it is
# rare or absent) largely cancel. The signed mean then sits near zero even for
# a taxon the model leans on heavily, and hides it. On the cFMD category run,
# S. thermophilus on dairy has a signed mean of -0.001 but a mean |phi| of
# 0.114, the strongest taxon of the run.
#
# So each taxon x class is described by two separate numbers:
#   strength  = mean |phi|: how far the taxon moves P(class), up or down;
#   direction = the sign of the Spearman correlation between the taxon's value
#               and its phi. Spearman = a correlation computed on ranks, so it
#               only asks "does more of the taxon go with a higher phi?", not
#               whether the relation is a straight line. Positive: samples
#               with more of the taxon get a higher P(class); negative: a lower
#               P(class).

# The three direction labels and their bar colours, kept in one place so the
# summary table and the figure always use the same wording. Blue and red stay
# distinguishable for the common forms of colour blindness; grey marks taxa
# whose direction cannot be measured.
shap_direction_colours <- c(
  "more of it: higher P(class)" = "#1f78b4",
  "more of it: lower P(class)"  = "#e31a1c",
  "no variation"                = "grey60"
)


# Spearman correlation between a taxon's value and its phi, for one taxon x
# class. Used only by shap_class_summary() below.
# Input:  value - the taxon's value the model saw, one per explained sample;
#         phi   - the matching SHAP values.
# Output: one number between -1 and 1, or NA when fewer than two samples have
#         both numbers, or when either of them is the same in every sample (a
#         taxon absent from all explained samples, or a phi that never moves):
#         a correlation is undefined then, and there is no direction to report.
shap_direction_rho <- function(value, phi) {
  both_known <- is.finite(value) & is.finite(phi)
  value <- value[both_known]
  phi <- phi[both_known]
  if (length(value) < 2) return(NA_real_)
  if (stats::var(value) == 0 || stats::var(phi) == 0) return(NA_real_)
  stats::cor(value, phi, method = "spearman")
}


# Condense per-sample SHAP values into one row per taxon x class.
#
# Input:  shap_long - one row per sample x taxon x class, with the columns
#           feature      taxon (model feature) name;
#           class        target class the phi refers to;
#           phi          SHAP value (change in predicted probability);
#           value_model  the taxon's value the model saw in that sample, after
#                        the run's normalisation (e.g. CLR).
#         The notebook builds this table as shap_export, the same table it
#         writes to metrics/shap_values.csv, so a finished run can also be
#         re-summarised from that file.
# What it does: groups the rows by taxon and class and computes, per group,
#         the signed mean, the mean absolute value and the Spearman direction
#         (see the section comment above), then turns the direction into one of
#         the three labels of shap_direction_colours.
# Output: data frame, one row per taxon x class, sorted by class and then by
#         strength (strongest taxon first), with the columns
#           feature, class,
#           mean_phi       signed mean (kept for reference; cancels, see above),
#           mean_abs_phi   strength,
#           direction_rho  Spearman correlation, NA when there is no variation,
#           direction      text label.
#         The notebook writes it to metrics/shap_class_contributions.csv and
#         passes it to plot_shap_by_class().
shap_class_summary <- function(shap_long) {
  needed_cols <- c("feature", "class", "phi", "value_model")
  missing_cols <- setdiff(needed_cols, names(shap_long))
  if (length(missing_cols) > 0) {
    stop("shap_class_summary(): the SHAP table has no column ",
         paste(missing_cols, collapse = ", "),
         ". It needs one row per sample x taxon x class with the columns ",
         "feature, class, phi and value_model.")
  }

  # One group per taxon x class; each group holds one row per explained sample.
  by_taxon_class <- dplyr::group_by(shap_long, feature, class)
  class_summary <- dplyr::summarise(
    by_taxon_class,
    mean_phi      = mean(phi),
    mean_abs_phi  = mean(abs(phi)),
    direction_rho = shap_direction_rho(value_model, phi),
    .groups = "drop"
  )
  class_summary <- as.data.frame(class_summary)

  # Correlation -> label. Everything starts as "no variation" (rho is NA);
  # a known rho then decides between the two directions. A rho of exactly 0
  # (rare) is filed under "higher", so every known rho gets a direction.
  labels <- names(shap_direction_colours)
  rho <- class_summary$direction_rho
  direction <- rep(labels[3], nrow(class_summary))
  direction[!is.na(rho) & rho >= 0] <- labels[1]
  direction[!is.na(rho) & rho < 0] <- labels[2]
  class_summary$direction <- direction

  # Strongest taxa of each class first, so the CSV reads top-down per class.
  class_summary <- class_summary[order(class_summary$class, -class_summary$mean_abs_phi), ]
  rownames(class_summary) <- NULL
  class_summary
}


# Draw the strongest taxa of each class as horizontal bars.
#
# Input:  summary        - the output of shap_class_summary();
#         method_label   - model name for the title, e.g. "TabPFN";
#         top_n          - taxa shown per class. NULL picks the default: 5 per
#                          class when there are more than two classes, 10 for a
#                          binary target (only one panel is drawn then);
#         positive_class - binary targets only: the class whose panel is drawn.
#                          With two classes the phi of one class is the mirror
#                          image of the other's, so one panel says it all; the
#                          configured positive class keeps the figure pointing
#                          the same way as the metrics. NULL, "" or a name that
#                          is not a class fall back to the alphabetically first
#                          class.
# What it does: keeps each class's top_n taxa by mean |phi|, draws one panel
#         per class (two panels per row), bar length = mean |phi|, bar colour =
#         direction. Bars are sorted within each panel, strongest on top. The
#         same taxon can appear in several panels, so each bar gets a label
#         unique to its panel (taxon + "___" + class) for sorting, and the axis
#         shows only the taxon name, looked up from that label.
#         The x axis is shared by all panels, so bar lengths compare across
#         classes as well as within one.
# Output: a ggplot object, or NULL (with a message) when the table is empty.
#         The notebook prints and saves it as "importance_by_class" with
#         show_and_save_figure().
plot_shap_by_class <- function(summary, method_label, top_n = NULL, positive_class = NULL) {
  if (is.null(summary) || nrow(summary) == 0) {
    message("plot_shap_by_class(): no SHAP values to draw.")
    return(NULL)
  }

  # Which classes get a panel, and how many taxa each shows.
  classes <- sort(unique(as.character(summary$class)))
  is_binary <- length(classes) == 2L
  if (is_binary) {
    # isTRUE() is FALSE for NULL, NA and "", so all three fall back to classes[1].
    if (isTRUE(positive_class %in% classes)) {
      panel_classes <- positive_class
    } else {
      panel_classes <- classes[1]
    }
    if (is.null(top_n)) top_n <- 10L
  } else {
    panel_classes <- classes
    if (is.null(top_n)) top_n <- 5L
  }

  # Keep the top_n strongest taxa of each drawn class (ties broken by row
  # order, so a panel never shows more than top_n bars).
  top_rows <- dplyr::filter(summary, class %in% panel_classes)
  top_rows <- dplyr::group_by(top_rows, class)
  top_rows <- dplyr::slice_max(top_rows, mean_abs_phi, n = top_n, with_ties = FALSE)
  top_rows <- as.data.frame(dplyr::ungroup(top_rows))

  # Sort bars within each panel. A discrete y axis draws its first level at
  # the bottom, so ordering by increasing strength puts the strongest on top.
  # Each panel only draws its own labels (scales = "free_y" below), so one
  # overall order, sorted inside each class, sorts every panel.
  top_rows <- top_rows[order(top_rows$class, top_rows$mean_abs_phi), ]
  top_rows$bar_id <- paste(top_rows$feature, top_rows$class, sep = "___")
  top_rows$bar_id <- factor(top_rows$bar_id, levels = top_rows$bar_id)
  top_rows$class <- factor(top_rows$class, levels = panel_classes)

  # bar_id -> taxon name, for the axis labels. A lookup rather than cutting
  # the text at "___", so a taxon or class name that itself contains "___"
  # is still labelled correctly.
  taxon_of_bar <- stats::setNames(as.character(top_rows$feature), as.character(top_rows$bar_id))
  axis_label <- function(bar_ids) unname(taxon_of_bar[bar_ids])

  plot_title <- paste0("Most influential taxa per class, ", method_label, " model")
  plot_subtitle <- paste0(
    "Bar length: mean |SHAP value|, how far the taxon moves P(class) on average, up or down.\n",
    "Colour: sign of the Spearman correlation between the taxon's value and its SHAP value; ",
    "grey = no variation."
  )

  ggplot2::ggplot(top_rows, ggplot2::aes(x = mean_abs_phi, y = bar_id, fill = direction)) +
    ggplot2::geom_col(width = 0.7) +
    ggplot2::facet_wrap(~ class, ncol = 2, scales = "free_y") +
    # Bars start at the axis line (no gap at 0); a little room on the right.
    ggplot2::scale_x_continuous(expand = ggplot2::expansion(mult = c(0, 0.05))) +
    ggplot2::scale_y_discrete(labels = axis_label) +
    ggplot2::scale_fill_manual(name = NULL, values = shap_direction_colours,
                               breaks = names(shap_direction_colours)) +
    ggplot2::labs(
      title    = plot_title,
      subtitle = plot_subtitle,
      x        = "Mean |SHAP value| (change in predicted probability of the class)",
      y        = NULL
    ) +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      plot.title          = ggplot2::element_text(size = 14, face = "bold"),
      plot.title.position = "plot",   # title and subtitle start at the left edge
      strip.text          = ggplot2::element_text(size = 12, face = "bold", hjust = 0),
      panel.grid.major.y  = ggplot2::element_blank(),
      panel.spacing.x     = ggplot2::unit(1.5, "lines"),
      legend.position     = "bottom",
      # extra right margin so the last tick label of the right column is not cut
      plot.margin         = ggplot2::margin(10, 20, 10, 10)
    )
}
