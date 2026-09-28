# Summary helpers for the multi-level wrapper (scripts/run_multi_tax_levels.R).
#
# The wrapper renders the notebook once per taxonomic rank and stacks each
# rank's per-group LODO scores (metrics/lodo_metrics.csv) into one long table:
# one row per rank x method x held-out group. Good to store, hard to read, so:
#   pivot_lodo_metrics_wide()    - one block per method x metric, groups down
#                                  the rows, ranks across the columns: which
#                                  rank transfers best, and to which groups.
#   plot_lodo_metrics_by_level() - the per-group bar figure, one panel per rank.
# Both take that stacked table straight from the wrapper's
# read_level_metrics("lodo_metrics.csv"). The wrapper is the only caller in the
# pipeline; tests/test_summary_helpers.R also pins the output columns and the
# figure subtitles. The column names are set in the notebook's Benchmark chunk;
# if they change, these two functions are what breaks.

# Chance level for balanced accuracy, from the classes actually in the task.
#
# Balanced accuracy averages the per-class recalls, so a model guessing at
# random scores 1 / number_of_classes: 0.5 for two classes, 0.143 for seven.
# A reference line at 0.5 on a seven-class target would mark folds as "below
# chance" while they score three times chance.
#
# Input:  lodo_metrics_all - the stacked long table. Its `class_counts` column
#                            is written per fold by the Benchmark chunk and
#                            reads "dairy=842; fish=0; meat=102"; the class
#                            NAMES are what matters here, not the counts, since
#                            a fold whose test part misses a class is still
#                            scored against the full set of them.
# Output: one number. Falls back to 0.5 when the table has no class_counts
#         column.
lodo_chance_level <- function(lodo_metrics_all) {
  counts <- lodo_metrics_all$class_counts
  if (is.null(counts) || !length(stats::na.omit(counts))) return(0.5)
  entries <- unlist(strsplit(as.character(stats::na.omit(counts)), ";", fixed = TRUE))
  classes <- unique(trimws(sub("=.*$", "", entries)))
  classes <- classes[nzchar(classes)]
  if (length(classes) < 2L) return(0.5)
  1 / length(classes)
}


# Short, readable name for the group a fold held out.
#
# Why this exists: `heldout_dataset` holds the groups that were in a fold's test
# part, joined by ";". Under leave-one-dataset-out that is one name and reads
# fine. Under grouped cross-validation a fold holds a slice of the groups, so
# the label becomes every one of them concatenated - on the cFMD category run,
# up to twelve dataset names and 197 characters. As an axis label that is
# unusable: ggplot sizes the panel around the text and pushes the bars, the
# title and the axis labels off the canvas entirely.
#
# Input:  labels    - the heldout_dataset column;
#         iteration - the fold number that produced each label, used for the
#                     short form;
#         max_chars - labels longer than this are replaced.
# Output: character vector, same length: the original name where it is short
#         enough, otherwise "fold <i> (<k> groups)". The full membership stays
#         in the CSV, which is where you look it up.
shorten_heldout_label <- function(labels, iteration = NULL, max_chars = 40L) {
  labels <- as.character(labels)
  n_groups <- lengths(strsplit(labels, ";", fixed = TRUE))
  too_long <- !is.na(labels) & (nchar(labels) > max_chars | n_groups > 1L)
  if (!any(too_long)) return(labels)
  fold_no <- if (is.null(iteration)) seq_along(labels) else as.integer(iteration)
  labels[too_long] <- sprintf("fold %s (%d groups)", fold_no[too_long], n_groups[too_long])
  labels
}


# Wide group-by-rank table of the per-group LODO scores.
# Input:  lodo_metrics_all - the stacked long table (columns tax_level, method,
#                            heldout_dataset, n_test, one column per metric,
#                            e.g. "balanced accuracy", "auc");
#         level_order      - ranks in the order they should appear as columns
#                            (phylum ... species, as in the config);
#         metrics          - which metric columns to spread; ones missing from
#                            the table are skipped (multi-class runs have no AUC).
# Output: one data frame of stacked blocks, one per method x metric: a row per
#         held-out group with its score at each rank, then a "mean" row (plain
#         average over groups, the number the benchmark table reports). NA where
#         a group was not scored at that rank. n_test comes from the first rank
#         that scored the group; a rank that dropped zero-read samples after
#         aggregation may have scored a few fewer.
# Written to <run>_multi_tax_results/lodo_metrics_all_tax_levels_wide.csv.
pivot_lodo_metrics_wide <- function(lodo_metrics_all, level_order,
                                    metrics = c("balanced accuracy", "auc")) {
  metrics <- intersect(metrics, names(lodo_metrics_all))
  if (!length(metrics)) stop("None of the requested metrics is a column of the LODO table.")
  level_order <- intersect(level_order, unique(lodo_metrics_all$tax_level))

  blocks <- list()
  for (method_i in unique(lodo_metrics_all$method)) {
    rows_method <- lodo_metrics_all[lodo_metrics_all$method == method_i, , drop = FALSE]
    # Long concatenated labels (grouped CV) become "fold i (k groups)"; the
    # full membership is in the long CSV next to this file.
    rows_method$heldout_dataset <- shorten_heldout_label(
      rows_method$heldout_dataset, rows_method$iteration
    )
    groups <- sort(unique(rows_method$heldout_dataset))

    for (metric_i in metrics) {
      # Skeleton: one row per group; the rank columns are filled in below.
      wide <- data.frame(
        method = method_i,
        metric = metric_i,
        heldout_dataset = groups,
        n_test = rows_method$n_test[match(groups, rows_method$heldout_dataset)],
        stringsAsFactors = FALSE, check.names = FALSE
      )
      for (level_i in level_order) {
        rows_level <- rows_method[rows_method$tax_level == level_i, , drop = FALSE]
        wide[[level_i]] <- rows_level[[metric_i]][match(groups, rows_level$heldout_dataset)]
      }

      # Mean over groups, one per rank: the number the benchmark table shows.
      mean_row <- wide[1, , drop = FALSE]
      mean_row$heldout_dataset <- "mean"
      mean_row$n_test <- NA
      for (level_i in level_order) {
        mean_row[[level_i]] <- round(mean(wide[[level_i]], na.rm = TRUE), 4)
      }
      blocks[[length(blocks) + 1]] <- rbind(wide, mean_row)
    }
  }
  wide_all <- do.call(rbind, blocks)
  rownames(wide_all) <- NULL
  wide_all
}

# Per-group figure across ranks: balanced accuracy of every method at every
# held-out group, one panel per rank, with a dotted line at chance
# (lodo_chance_level(), 1 / number of classes).
# Input:  lodo_metrics_all and level_order as above;
#         outer  - the run's evaluation.outer. Decides whether the figure may
#                  call itself LODO: only that strategy holds out one group per
#                  fold, and the shipped cFMD category run uses grouped cv;
#         nested - the run's evaluation.nested flag. Only sets the subtitle,
#                  which says whether the bars are honest nested estimates
#                  (selection and tuning repeated inside every fold) or the
#                  non-nested, mildly optimistic ones, where selection and
#                  tuning saw every group.
# Output: a ggplot object; the caller saves it (ggsave) or prints it.
# Bars near the dotted chance line at a group mean the method does not
# transfer to that group, whatever its mean says.
plot_lodo_metrics_by_level <- function(lodo_metrics_all, level_order, nested, outer = "lodo") {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("Package 'ggplot2' is required to draw the LODO figure.")
  }
  # Keep the ranks in rank order (as listed in the config), not alphabetical,
  # so the panels read phylum -> species.
  lodo_metrics_all$heldout_dataset <- shorten_heldout_label(
    lodo_metrics_all$heldout_dataset, lodo_metrics_all$iteration
  )
  lodo_metrics_all$tax_level <- factor(lodo_metrics_all$tax_level, levels = level_order)

  # Chance for balanced accuracy is 1 / number of classes, not 0.5 unless the
  # target happens to be binary.
  chance <- lodo_chance_level(lodo_metrics_all)
  subtitle <- paste(
    sprintf("Dotted line = chance (%.2f).", chance),
    if (isTRUE(nested)) "Nested: feature selection and tuning repeated inside every fold."
    else "Internal estimates: feature selection and tuning used all groups."
  )

  ggplot2::ggplot(
    lodo_metrics_all,
    ggplot2::aes(x = heldout_dataset, y = `balanced accuracy`, fill = method)
  ) +
    ggplot2::geom_col(position = ggplot2::position_dodge(width = 0.8), width = 0.7) +
    ggplot2::geom_hline(yintercept = chance, linetype = "dotted", colour = "grey40") +
    ggplot2::facet_wrap(~tax_level, ncol = 2) +
    ggplot2::scale_y_continuous(limits = c(0, 1)) +
    ggplot2::labs(
      # Only leave-one-dataset-out holds out ONE group per fold; grouped
      # cross-validation holds out several, so the title must not claim LODO.
      title = if (identical(outer, "lodo"))
        "LODO: balanced accuracy per held-out dataset, by taxonomic level"
      else "Balanced accuracy per outer fold, by taxonomic level",
      subtitle = subtitle,
      x = if (identical(outer, "lodo")) "Held-out dataset" else "Held-out groups (per fold)",
      y = "Balanced accuracy", fill = "Method"
    ) +
    ggplot2::theme_bw(base_size = 12) +
    ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 45, hjust = 1),
                   plot.title = ggplot2::element_text(face = "bold"))
}
