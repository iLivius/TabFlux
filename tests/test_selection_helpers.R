# Tests for R/tabflux_selection_helpers.R — plain script, no framework.
# Run from the repository root inside the tabflux-r environment:
#   Rscript tests/test_selection_helpers.R
# What is checked:
#   1. Feature selection returns the SAME features whatever random-number
#      generator is active when it is called. A parallel back end switches R
#      to L'Ecuyer-CMRG, and with the same seed the two generator kinds can
#      select different numbers of features, because the CV splits inside the
#      elimination differ. select_features() pins the generator kind; this
#      test checks that it does.
#   2. The inner resampling is capped by the number of groups, so a grouped
#      task with fewer groups than folds does not produce empty folds.
#   3. With the class-prior correction on, selection still runs and keeps an
#      informative feature.
suppressMessages({
  library(mlr3); library(mlr3learners); library(mlr3pipelines); library(mlr3extralearners)
  library(mlr3fselect); library(mlr3filters); library(paradox); library(data.table); library(future)
})
lgr::get_logger("mlr3")$set_threshold("off"); lgr::get_logger("bbotk")$set_threshold("off")
source(file.path("R", "tabflux_selection_helpers.R"))
ok <- function(label, cond) { stopifnot(cond); cat("PASS:", label, "\n") }

# Toy grouped task: 3 studies, a handful of informative features among noise.
set.seed(7)
n <- 90
dt <- data.table(lodo = factor(rep(paste0("ds", 1:3), each = n / 3)))
for (j in 1:12) set(dt, j = paste0("noise", j), value = rnorm(n))
signal <- rnorm(n)
dt[, target := factor(ifelse(signal + rnorm(n, sd = 0.4) > 0, "a", "b"))]
dt[, good1 := signal + rnorm(n, sd = 0.3)][, good2 := signal + rnorm(n, sd = 0.5)]
task <- as_task_classif(dt, target = "target", id = "toy")
task$set_col_roles("lodo", "group")
task$col_roles$feature <- setdiff(task$col_roles$feature, "lodo")

select_under <- function(kind) {
  suppressWarnings(RNGkind(kind))
  suppressMessages(select_features(task_train = task$clone(deep = TRUE), seed = 42,
                                   num_threads = 2, out_dir = tempfile())$selected_feats)
}
mt <- select_under("Mersenne-Twister")
le <- select_under("L'Ecuyer-CMRG")
suppressWarnings(RNGkind("Mersenne-Twister"))
ok("selection ignores the ambient RNG kind", identical(sort(mt), sort(le)))
ok("selection is repeatable", identical(sort(mt), sort(select_under("Mersenne-Twister"))))
ok("an informative feature survived (good1 or good2)", any(c("good1", "good2") %in% mt))

# 3 groups must not yield 5 folds: the run would die with an empty fold later.
# select_features() says so in a message; collect the messages and look for it.
fs_messages <- character(0)
withCallingHandlers(
  invisible(capture.output(
    select_features(task_train = task$clone(deep = TRUE), seed = 1, num_threads = 1, out_dir = tempfile())
  )),
  message = function(m) {
    fs_messages <<- c(fs_messages, conditionMessage(m))
    invokeRestart("muffleMessage")
  }
)
ok("inner folds capped by the number of groups (3 folds for 3 studies)",
   any(grepl("reduced to 3 folds (number of groups)", fs_messages, fixed = TRUE)))


# ── feature selection with the class-prior correction ────────────────────────
# With evaluation.prior_correction on, subsets are ranked by the corrected
# balanced accuracy; the call must run and return a subset that keeps at
# least one of the informative features.
source(file.path("R", "tabflux_training_helpers.R"))   # MeasureClassifBaccPrior
set.seed(5)
dsel <- data.frame(target = factor(c(rep("a", 70), rep("b", 20), rep("c", 10))))
# f1-f3 carry the class (shifted by 1, 2 or 3), f4-f30 are noise. `if`, not
# ifelse(): ifelse() on a single TRUE returns only the FIRST class value, which
# would shift the whole column by one constant and carry no signal at all.
for (j in 1:30) dsel[[paste0("f", j)]] <- rnorm(100) + if (j <= 3) as.integer(dsel$target) else 0
tsel <- mlr3::as_task_classif(dsel, target = "target")
fs_c <- select_features(task_train = tsel$clone(deep = TRUE), seed = 1, num_threads = 1,
                        out_dir = file.path(tempdir(), "fs_prior"), prior_correction = TRUE)
stopifnot(length(fs_c$selected_feats) >= 1, all(fs_c$selected_feats %in% tsel$feature_names))
cat("PASS: feature selection runs with the corrected measure and returns a subset\n")
stopifnot(any(c("f1", "f2", "f3") %in% fs_c$selected_feats))
cat("PASS: that subset holds at least one of the three informative features\n")

cat("\nAll selection-helper tests passed.\n")
