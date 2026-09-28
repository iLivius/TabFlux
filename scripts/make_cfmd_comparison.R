#!/usr/bin/env Rscript

# Tables and figures for the learner comparison of the cFMD case study
# (docs/cfmd/comparison.md).
#
# What that page shows: the learners of ONE finished TabFlux run (TabPFN, random
# forest, XGBoost), scored on the same out-of-fold predictions under two decision
# rules. It asks how much of the difference between learners comes from the learner
# itself and how much from the rule that turns probabilities into a predicted category.
#
# The two decision rules, in plain words. For every sample a learner gives one
# probability per food category. The predicted category is then either:
#   - "largest":  the category with the largest probability, full stop;
#   - "default":  TabFlux's default (evaluation.prior_correction: true). Each
#                 probability is first divided by how common that category was in the
#                 training samples of that outer fold, then the largest is taken. A
#                 rare category needs a lower probability to win, so the rule stops the
#                 big categories (dairy here) from swallowing the small ones.
# The run saves the probabilities and the "default" prediction for every sample
# (metrics/oof_predictions.csv, column `response`). The "largest" prediction is not
# saved, so this script recomputes it from the same saved probabilities. Nothing is
# refitted: the models and their probabilities are identical under both rules; only
# the last step, picking the category, differs. Log-loss is computed from the
# probabilities alone, so it is the same under both rules.
# If the run was made with evaluation.prior_correction: false, `response` is already
# the largest probability and the two rules give identical numbers.
#
# Where each number comes from (all inside <run folder>/metrics/):
#   oof_predictions.csv          one row per sample x learner: learner key (`method`),
#                                dataset (`group`), true category (`truth`), the
#                                default-rule prediction (`response`) and one
#                                `prob.<category>` column per category.
#                                -> balanced accuracy, accuracy, recall (both rules)
#   lodo_metrics.csv             one row per outer fold x learner; `heldout_dataset`
#                                lists the datasets that fold held out, separated by
#                                ";", and `iteration` is the fold number.
#                                -> which fold each sample was tested in, and a check
#                                   that the default rule reproduces the run's scores
#   benchmark_metrics_spread.csv mean and SD over folds of each metric per learner,
#                                as the run reported them.
#                                -> log-loss (copied, not recomputed)
#
# Outputs, all in <out_dir>:
#   headline.csv   one row per learner x rule: balanced accuracy and accuracy (mean and
#                  SD over the outer folds), log-loss (mean and SD, from the run)
#   per_class.csv  one row per learner x rule x category: recall pooled over all
#                  out-of-fold predictions, with the category's sample count
#   per_fold.csv   one row per learner x rule x fold: test samples and balanced accuracy
#   cfmd_cmp_rule.png / _dark.png       balanced accuracy under the two rules
#   cfmd_cmp_per_class.png / _dark.png  recall per category under the two rules
#   cfmd_cmp_per_fold.png / _dark.png   balanced accuracy per fold, default rule
# The CSVs keep full precision; the docs page rounds when it quotes them. The PNGs are
# copied to docs/assets/ (light and dark versions, one per site theme).
#
# Usage, from the project root (the image ships this script in /work/scripts):
#   Rscript scripts/make_cfmd_comparison.R <run>_saved_learners <out_dir>
# e.g.
#   Rscript scripts/make_cfmd_comparison.R \
#     out/2026-09-23_TabFlux_category_target_category_tax_sgb_saved_learners out/comparison
# Packages: data.table and ggplot2 only, both in the TabFlux image.

suppressMessages({
  library(data.table)
  library(ggplot2)
})


# ---- 1. Command line: which run to read, where to write ---------------------------
# Argument 1 = the run's "<...>_saved_learners" folder (it holds metrics/).
# Argument 2 = the output folder; created when it does not exist.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) {
  stop("Usage: Rscript scripts/make_cfmd_comparison.R <run_saved_learners_folder> <out_dir>")
}
run_dir <- args[[1]]
out_dir <- args[[2]]

metrics_dir <- file.path(run_dir, "metrics")
oof_file <- file.path(metrics_dir, "oof_predictions.csv")
lodo_file <- file.path(metrics_dir, "lodo_metrics.csv")
spread_file <- file.path(metrics_dir, "benchmark_metrics_spread.csv")
for (needed_file in c(oof_file, lodo_file, spread_file)) {
  if (!file.exists(needed_file)) {
    stop("File not found: ", needed_file,
         "\nThe first argument must be a finished run's '<...>_saved_learners' folder.")
  }
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)


# ---- 2. Read the run's three tables -----------------------------------------------
# All three are written by analysis/tabflux.qmd at the end of a run (see "Where each
# number comes from" above). Read as plain tables; nothing is modified on disk.
oof <- fread(oof_file)
lodo <- fread(lodo_file)
spread <- fread(spread_file)


# ---- 3. Learners: names, display labels and fixed order ---------------------------
# oof_predictions.csv names a learner by its short key (tabpfn, ranger, xgboost);
# lodo_metrics.csv and benchmark_metrics_spread.csv use the run's label ("Random
# Forest"). lodo_metrics.csv holds both (`learner_id` and `method`), so it gives the
# key -> run label link used to look up log-loss.
# The docs write the labels in sentence case ("Random forest"); display_labels holds
# that spelling. A learner missing from it keeps the run's own label.
# learner_order fixes the order of rows in the tables and the colour of each learner
# in every figure: a learner keeps the same colour on every plot.
key_to_run_label <- unique(lodo[, .(learner_id, method)])
display_labels <- c(tabpfn = "TabPFN", ranger = "Random forest", xgboost = "XGBoost")

learner_keys_in_run <- unique(oof$method)
missing_keys <- setdiff(learner_keys_in_run, key_to_run_label$learner_id)
if (length(missing_keys) > 0) {
  stop("Learner(s) in oof_predictions.csv but not in lodo_metrics.csv: ",
       paste(missing_keys, collapse = ", "))
}
known_first <- intersect(names(display_labels), learner_keys_in_run)
learner_keys <- c(known_first, setdiff(learner_keys_in_run, known_first))

learner_label <- character(0)
for (learner_key in learner_keys) {
  if (learner_key %in% names(display_labels)) {
    learner_label[learner_key] <- display_labels[[learner_key]]
  } else {
    learner_label[learner_key] <- key_to_run_label$method[key_to_run_label$learner_id == learner_key][1]
  }
}
learner_order <- unname(learner_label[learner_keys])

# The figures use three validated colours (one per learner); more learners would need
# more colours than the palette has been checked for.
if (length(learner_keys) > 3) {
  stop("The figures have colours for at most 3 learners; the run has ",
       length(learner_keys), ".")
}


# ---- 4. Which outer fold tested each dataset --------------------------------------
# The folds are grouped: a whole dataset is held out together, so the fold of a sample
# is the fold of its dataset (`group` in oof_predictions.csv). lodo_metrics.csv lists,
# for every fold (`iteration`), the datasets it held out as "A;B;C". Every learner
# shares the same folds, so the rows of all learners give the same map; the check
# below makes sure no dataset is listed under two folds.
dataset_to_fold <- integer(0)
for (row_index in seq_len(nrow(lodo))) {
  fold_number <- as.integer(lodo$iteration[row_index])
  heldout_datasets <- strsplit(lodo$heldout_dataset[row_index], ";", fixed = TRUE)[[1]]
  for (dataset in heldout_datasets) {
    already_mapped <- dataset %in% names(dataset_to_fold)
    if (already_mapped && dataset_to_fold[[dataset]] != fold_number) {
      stop("Dataset ", dataset, " is listed under two folds in lodo_metrics.csv.")
    }
    dataset_to_fold[dataset] <- fold_number
  }
}

unmapped_datasets <- setdiff(unique(oof$group), names(dataset_to_fold))
if (length(unmapped_datasets) > 0) {
  stop("Dataset(s) in oof_predictions.csv with no fold in lodo_metrics.csv: ",
       paste(unmapped_datasets, collapse = ", "))
}
oof[, fold := unname(dataset_to_fold[group])]
fold_numbers <- sort(unique(oof$fold))

# Datasets per fold, only for the subtitle of the per-fold figure.
datasets_per_fold <- as.integer(table(dataset_to_fold))


# ---- 5. The two predictions for every sample --------------------------------------
# Categories = the `prob.<category>` columns, in the order the run wrote them.
# pred_default = the saved `response` (the run's own decision, default rule).
# pred_largest = the category with the largest saved probability. which.max() returns
# the FIRST category when two probabilities tie exactly, the same tie-break the run
# uses for its own decision (ties_method "first" in apply_prior_correction()).
prob_columns <- grep("^prob\\.", names(oof), value = TRUE)
categories <- sub("^prob\\.", "", prob_columns)
prob_matrix <- as.matrix(oof[, ..prob_columns])
index_of_largest <- apply(prob_matrix, 1, which.max)

oof[, pred_default := as.character(response)]
oof[, pred_largest := categories[index_of_largest]]
oof[, truth := as.character(truth)]

rules <- c("largest", "default")
prediction_column <- c(largest = "pred_largest", default = "pred_default")


# ---- 6. Scores ---------------------------------------------------------------------
# Recall of one category = share of its samples that were predicted as that category.
# Balanced accuracy = the mean recall over the categories present in `truth`. A
# category with no sample in a fold has no recall there and is left out of that
# fold's mean, as mlr3 does when it scores the run.
# Accuracy = share of all samples predicted correctly; dominated by dairy here.
recall_of <- function(truth, predicted, category) {
  is_this_category <- truth == category
  mean(predicted[is_this_category] == category)
}

balanced_accuracy <- function(truth, predicted) {
  categories_present <- unique(truth)
  recalls <- numeric(length(categories_present))
  for (i in seq_along(categories_present)) {
    recalls[i] <- recall_of(truth, predicted, categories_present[i])
  }
  mean(recalls)
}


# ---- 7. Tables: one pass per learner and rule -------------------------------------
# For each learner and each rule:
#   per fold      balanced accuracy and accuracy on that fold's test samples
#   headline      mean and SD (n - 1 denominator) of those fold values, plus the run's
#                 log-loss (mean and SD over folds, benchmark_metrics_spread.csv)
#   per category  recall pooled over ALL out-of-fold predictions of that learner,
#                 i.e. every sample counted once, whatever fold tested it
# Rows are collected in lists and stacked at the end.
headline_rows <- list()
per_class_rows <- list()
per_fold_rows <- list()

for (learner_key in learner_keys) {
  label <- learner_label[[learner_key]]
  learner_rows <- oof[method == learner_key]

  run_label <- key_to_run_label$method[key_to_run_label$learner_id == learner_key][1]
  logloss_row <- spread[method == run_label & metric == "logloss"]
  if (nrow(logloss_row) != 1) {
    stop("No single log-loss row for '", run_label, "' in benchmark_metrics_spread.csv.")
  }

  for (rule in rules) {
    predicted_all <- learner_rows[[prediction_column[[rule]]]]

    fold_bacc <- numeric(length(fold_numbers))
    fold_acc <- numeric(length(fold_numbers))
    for (i in seq_along(fold_numbers)) {
      in_fold <- learner_rows$fold == fold_numbers[i]
      truth_fold <- learner_rows$truth[in_fold]
      predicted_fold <- predicted_all[in_fold]

      fold_bacc[i] <- balanced_accuracy(truth_fold, predicted_fold)
      fold_acc[i] <- mean(predicted_fold == truth_fold)

      per_fold_rows[[length(per_fold_rows) + 1]] <- data.table(
        learner = label, rule = rule, fold = fold_numbers[i],
        n_test = sum(in_fold), bacc = fold_bacc[i]
      )
    }

    for (category in categories) {
      n_category <- sum(learner_rows$truth == category)
      per_class_rows[[length(per_class_rows) + 1]] <- data.table(
        learner = label, rule = rule, cls = category, n = n_category,
        recall = recall_of(learner_rows$truth, predicted_all, category)
      )
    }

    headline_rows[[length(headline_rows) + 1]] <- data.table(
      learner = label, rule = rule,
      bacc_mean = mean(fold_bacc), bacc_sd = sd(fold_bacc),
      acc_mean = mean(fold_acc), acc_sd = sd(fold_acc),
      logloss_mean = logloss_row$mean, logloss_sd = logloss_row$sd
    )
  }
}

headline <- rbindlist(headline_rows)
per_class <- rbindlist(per_class_rows)
per_fold <- rbindlist(per_fold_rows)


# ---- 8. Check: the default rule reproduces the run's own fold scores --------------
# lodo_metrics.csv holds the balanced accuracy the run itself computed per fold and
# learner (rounded to 4 decimals). The default-rule values above are recomputed from
# the saved predictions and must agree; a mismatch means `response` is not the
# decision the run was scored on, and the "default" columns would be mislabelled.
for (learner_key in learner_keys) {
  run_label <- key_to_run_label$method[key_to_run_label$learner_id == learner_key][1]
  for (fold_number in fold_numbers) {
    run_value <- lodo[method == run_label & iteration == fold_number][["balanced accuracy"]]
    our_value <- per_fold[learner == learner_label[[learner_key]] & rule == "default" &
                            fold == fold_number, bacc]
    if (length(run_value) == 1 && abs(run_value - our_value) > 1e-4) {
      warning(sprintf("%s, fold %d: default-rule balanced accuracy %.4f, run reports %.4f.",
                      learner_label[[learner_key]], fold_number, our_value, run_value))
    }
  }
}


# ---- 9. Write the tables -----------------------------------------------------------
# fwrite keeps 15 significant digits: no rounding here, the docs round when quoting.
fwrite(headline, file.path(out_dir, "headline.csv"))
fwrite(per_class, file.path(out_dir, "per_class.csv"))
fwrite(per_fold, file.path(out_dir, "per_fold.csv"))


# ---- 10. Figure style: one light and one dark theme -------------------------------
# The docs site has a light and a dark theme and shows the matching PNG. Both themes
# use the same three hues in the same order (blue, orange, green = learner 1, 2, 3),
# each tuned for its background and checked for colour-blind separation.
# surface = background, ink = titles, ink2 = axis text and labels, grid = grid lines.
themes <- list(
  light = list(surface = "#fcfcfb", ink = "#0b0b0b", ink2 = "#52514e", grid = "#e6e5e1",
               cols = c("#2a78d6", "#eb6834", "#1baf7a")),
  dark  = list(surface = "#1a1a19", ink = "#ffffff", ink2 = "#c3c2b7", grid = "#383835",
               cols = c("#3987e5", "#d95926", "#199e70"))
)

# Shared ggplot theme for the three figures, given one entry of `themes`.
base_theme <- function(t) {
  theme_minimal(base_size = 12) +
    theme(plot.background = element_rect(fill = t$surface, colour = NA),
          panel.background = element_rect(fill = t$surface, colour = NA),
          panel.grid.major = element_line(colour = t$grid, linewidth = 0.35),
          panel.grid.minor = element_blank(),
          text = element_text(colour = t$ink),
          axis.text = element_text(colour = t$ink2, size = 11),
          plot.title = element_text(face = "bold", size = 13),
          plot.subtitle = element_text(colour = t$ink2, size = 10.5),
          strip.text = element_text(colour = t$ink, face = "bold", hjust = 0, size = 11),
          legend.position = "top", legend.justification = "left",
          legend.text = element_text(colour = t$ink2, size = 11),
          legend.title = element_blank(),
          plot.margin = margin(10, 14, 8, 8))
}

# Learner -> colour for one theme, in learner_order (same learner, same colour).
learner_colours <- function(t) {
  setNames(t$cols[seq_along(learner_order)], learner_order)
}

# Build a figure twice (light, dark) and save both PNGs.
# make = a function that takes one theme and returns the ggplot.
# Output: <out_dir>/<name>.png and <out_dir>/<name>_dark.png, 200 dpi.
save_both <- function(make, name, width, height) {
  for (mode in names(themes)) {
    plot_object <- make(themes[[mode]])
    suffix <- if (mode == "dark") "_dark" else ""
    ggsave(file.path(out_dir, paste0(name, suffix, ".png")), plot_object,
           width = width, height = height, dpi = 200, bg = themes[[mode]]$surface)
  }
}

# Axis limits on round steps that enclose the data plus half a step on each side, so
# no point sits on the edge of the panel (e.g. lowest fold 0.406, step 0.1 -> 0.3).
# round() removes floating-point dust so the last break is not dropped.
round_limits <- function(values, step) {
  lower <- round(floor((min(values) - step / 2) / step) * step, 6)
  upper <- round(ceiling((max(values) + step / 2) / step) * step, 6)
  c(lower, upper)
}

# "11 or 12" / "12" / "10 to 13": how many datasets a fold holds out.
describe_count_range <- function(counts) {
  smallest <- min(counts)
  largest <- max(counts)
  if (smallest == largest) return(as.character(smallest))
  if (largest - smallest == 1) return(sprintf("%d or %d", smallest, largest))
  sprintf("%d to %d", smallest, largest)
}


# ---- 11. Figure 1: balanced accuracy under each rule ------------------------------
# One row per learner: an open circle at the largest-probability score, a filled one
# at the default-rule score, joined by a line. The length of the line is what the
# rule alone changes; the horizontal gap between rows is what the learner changes.
# Input: headline (mean balanced accuracy over folds). Consumer: comparison page,
# section "The decision rule".
rule_labels <- c(largest = "Largest probability",
                 default = "Largest probability / training frequency (default)")

rule_plot_data <- copy(headline)
rule_plot_data[, learner := factor(learner, levels = rev(learner_order))]
rule_plot_data[, rule := factor(rule, levels = c("largest", "default"))]
rule_segments <- dcast(rule_plot_data, learner ~ rule, value.var = "bacc_mean")
rule_x_limits <- round_limits(rule_plot_data$bacc_mean, 0.02)
rule_x_breaks <- round(seq(rule_x_limits[1], rule_x_limits[2], by = 0.02), 6)
rule_x_title <- sprintf("Balanced accuracy, mean of %d grouped folds", length(fold_numbers))

fig_rule <- function(t) {
  cols <- learner_colours(t)
  ggplot() +
    geom_segment(data = rule_segments,
                 aes(y = learner, yend = learner, x = largest, xend = default, colour = learner),
                 linewidth = 1, lineend = "round", show.legend = FALSE) +
    # open (largest) and filled (default) markers; the legend explains the shapes
    geom_point(data = rule_plot_data,
               aes(y = learner, x = bacc_mean, colour = learner, shape = rule),
               size = 3.8, stroke = 1.2, fill = t$surface) +
    # redraw the default-rule marker with a thin background-coloured ring, so it
    # stays readable where it touches the line
    geom_point(data = rule_plot_data[rule == "default"],
               aes(y = learner, x = bacc_mean, fill = learner),
               shape = 21, size = 3.8, stroke = 0.9, colour = t$surface, show.legend = FALSE) +
    geom_text(data = rule_plot_data,
              aes(y = learner, x = bacc_mean, label = sprintf("%.3f", bacc_mean)),
              colour = t$ink2, size = 3.6, vjust = -1.3) +
    scale_colour_manual(values = cols, guide = "none") +
    scale_fill_manual(values = cols, guide = "none") +
    scale_shape_manual(values = c(largest = 21, default = 16), labels = rule_labels) +
    guides(shape = guide_legend(nrow = 2, override.aes = list(colour = t$ink2))) +
    scale_x_continuous(limits = rule_x_limits, breaks = rule_x_breaks) +
    labs(x = rule_x_title, y = NULL,
         title = "Balanced accuracy under two decision rules",
         subtitle = "Same saved probabilities per learner; only the rule that picks the category differs.") +
    base_theme(t) +
    theme(panel.grid.major.y = element_blank())
}
save_both(fig_rule, "cfmd_cmp_rule", 7.4, 3.6)


# ---- 12. Figure 2: recall per category, both rules --------------------------------
# One panel per rule; one row per category, largest first, labelled with its sample
# count; one dot per learner. Shows which categories the default rule rescues (small
# ones) and what it costs (dairy). Input: per_class. Consumer: comparison page,
# section "Per category".
category_sizes <- unique(per_class[, .(cls, n)])
category_sizes <- category_sizes[order(-n)]
category_label <- function(category, n) {
  sprintf("%s (%s)", category, prettyNum(n, big.mark = ","))
}

class_plot_data <- copy(per_class)
class_plot_data[, cls_lab := factor(category_label(cls, n),
                                    levels = rev(category_label(category_sizes$cls, category_sizes$n)))]
class_plot_data[, learner := factor(learner, levels = learner_order)]
class_plot_data[, rule := factor(c(largest = "Largest probability", default = "Default rule")[rule],
                                 levels = c("Largest probability", "Default rule"))]

fig_class <- function(t) {
  ggplot(class_plot_data, aes(x = recall, y = cls_lab, fill = learner)) +
    # dots of the three learners side by side within a category row (dodge)
    geom_point(shape = 21, size = 3.4, stroke = 0.7, colour = t$surface,
               position = position_dodge(width = 0.6)) +
    facet_wrap(~ rule, nrow = 1) +
    scale_fill_manual(values = learner_colours(t)) +
    scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.25),
                       labels = c("0", "0.25", "0.50", "0.75", "1")) +
    labs(x = "Recall, pooled out-of-fold predictions", y = NULL,
         title = "Recall per food category",
         subtitle = "Categories ordered by sample count.") +
    base_theme(t) +
    theme(panel.grid.major.y = element_line(colour = t$grid, linewidth = 0.35),
          panel.spacing = unit(1.4, "lines"))
}
save_both(fig_class, "cfmd_cmp_per_class", 8.8, 4.6)


# ---- 13. Figure 3: balanced accuracy per fold, default rule -----------------------
# One line per learner across the outer folds, each fold labelled with its test
# sample count. Shows that the held-out datasets move the score more than the learner
# does. Input: per_fold (default rule only). Consumer: comparison page, "Per fold".
fold_plot_data <- per_fold[rule == "default"]
fold_plot_data[, learner := factor(learner, levels = learner_order)]
fold_sizes <- unique(fold_plot_data[, .(fold, n_test)])
fold_sizes <- fold_sizes[order(fold)]
fold_label <- function(fold, n) {
  sprintf("Fold %d\n%s samples", fold, prettyNum(n, big.mark = ","))
}
fold_plot_data[, fold_lab := factor(fold_label(fold, n_test),
                                    levels = fold_label(fold_sizes$fold, fold_sizes$n_test))]
fold_y_limits <- round_limits(fold_plot_data$bacc, 0.1)
fold_y_breaks <- round(seq(fold_y_limits[1], fold_y_limits[2], by = 0.1), 6)
fold_subtitle <- sprintf("Default rule. Each fold holds out %s whole datasets.",
                         describe_count_range(datasets_per_fold))

fig_fold <- function(t) {
  cols <- learner_colours(t)
  ggplot(fold_plot_data, aes(x = fold_lab, y = bacc, group = learner, colour = learner)) +
    geom_line(linewidth = 0.9, lineend = "round", linejoin = "round") +
    geom_point(aes(fill = learner), shape = 21, size = 3.2, stroke = 0.8, colour = t$surface) +
    scale_colour_manual(values = cols) +
    scale_fill_manual(values = cols) +
    scale_y_continuous(limits = fold_y_limits, breaks = fold_y_breaks) +
    labs(x = NULL, y = "Balanced accuracy",
         title = "Balanced accuracy per outer fold",
         subtitle = fold_subtitle) +
    base_theme(t) +
    theme(panel.grid.major.x = element_blank())
}
save_both(fig_fold, "cfmd_cmp_per_fold", 7.6, 4.2)


# ---- 14. Report what was written --------------------------------------------------
written_files <- c("headline.csv", "per_class.csv", "per_fold.csv",
                   "cfmd_cmp_rule.png", "cfmd_cmp_rule_dark.png",
                   "cfmd_cmp_per_class.png", "cfmd_cmp_per_class_dark.png",
                   "cfmd_cmp_per_fold.png", "cfmd_cmp_per_fold_dark.png")
cat("Learner comparison written to ", normalizePath(out_dir), ":\n", sep = "")
cat(paste0("  ", written_files, collapse = "\n"), "\n")
