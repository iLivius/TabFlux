# Citation

If TabFlux is useful in your work, please cite the software.

> Antonielli, L., & Pucher, L. (2026). *TabFlux: machine-learning classification of microbial community profiles.*
> GitHub. <https://github.com/iLivius/TabFlux>

The repository carries a `CITATION.cff` file, so GitHub's "Cite this repository" button
produces a correct entry in APA or BibTeX. A Zenodo DOI is minted with the first public
release and is the preferred thing to cite. The concept DOI always resolves to the
newest release, and each tagged release gets its own version DOI, which is the one to
cite when the exact code matters.

## References

Cite the components a run relied on. The list follows the order of a run.

### Framework

- Lang M, Binder M, Richter J, Schratz P, Pfisterer F, Coors S, Au Q, Casalicchio G,
  Kotthoff L, Bischl B (2019). mlr3: A modern object-oriented machine learning framework
  in R. *Journal of Open Source Software* 4(44):1903.
  <https://doi.org/10.21105/joss.01903>
- Binder M, Pfisterer F, Lang M, Schneider L, Kotthoff L, Bischl B (2021). mlr3pipelines
  – flexible machine learning pipelines in R. *Journal of Machine Learning Research*
  22(184):1–7.
- Bischl B, Sonabend R, Kotthoff L, Lang M, eds. (2024). *Applied Machine Learning Using
  mlr3 in R.* CRC Press. <https://mlr3book.mlr-org.com>
- Allaire JJ, Teague C, Scheidegger C, Xie Y, Dervieux C, Woodhull G (2024). Quarto.
  <https://doi.org/10.5281/zenodo.5960048>
- Ushey K, Allaire JJ, Tang Y. reticulate: Interface to Python. R package.
  <https://rstudio.github.io/reticulate/>
- Bengtsson H (2021). A unifying framework for parallel and distributed processing in R
  using futures. *The R Journal* 13(2):208–227. <https://doi.org/10.32614/RJ-2021-048>

### Input formats

- Callahan BJ, McMurdie PJ, Rosen MJ, Han AW, Johnson AJA, Holmes SP (2016). DADA2:
  high-resolution sample inference from Illumina amplicon data. *Nature Methods*
  13:581–583. <https://doi.org/10.1038/nmeth.3869> — the three-file layout mirrors its
  output.
- Blanco-Míguez A, Beghini F, Cumbo F, et al. (2023). Extending and improving
  metagenomic taxonomic profiling with uncharacterized species using MetaPhlAn 4.
  *Nature Biotechnology* 41:1633–1644. <https://doi.org/10.1038/s41587-023-01688-w> —
  the profiles behind the SGB level.

### Depth normalisation

- Gloor GB, Macklaim JM, Pawlowsky-Glahn V, Egozcue JJ (2017). Microbiome datasets are
  compositional: and this is not optional. *Frontiers in Microbiology* 8:2224.
  <https://doi.org/10.3389/fmicb.2017.02224>
- Aitchison J (1986). *The Statistical Analysis of Compositional Data.* Chapman & Hall.
  — the centred log-ratio behind `tss_clr`.
- McMurdie PJ, Holmes S (2014). Waste not, want not: why rarefying microbiome data is
  inadmissible. *PLoS Computational Biology* 10(4):e1003531.
  <https://doi.org/10.1371/journal.pcbi.1003531>

### Feature selection and class balancing

- Guyon I, Weston J, Barnhill S, Vapnik V (2002). Gene selection for cancer
  classification using support vector machines. *Machine Learning* 46:389–422.
  <https://doi.org/10.1023/A:1012487302797> — recursive feature elimination.
- Breiman L, Friedman JH, Olshen RA, Stone CJ (1984). *Classification and Regression
  Trees.* Wadsworth. — the one-standard-error rule.
- Zawadzki Z, Kosinski M. FSelectorRcpp: Rcpp implementation of FSelector entropy-based
  feature selection algorithms. R package. — the information-gain filter.
- Chawla NV, Bowyer KW, Hall LO, Kegelmeyer WP (2002). SMOTE: synthetic minority
  over-sampling technique. *Journal of Artificial Intelligence Research* 16:321–357.
  <https://doi.org/10.1613/jair.953>
- Siriseriwan W. smotefamily: a collection of oversampling techniques for class
  imbalance problem based on SMOTE. R package.

### Learners

- Breiman L (2001). Random forests. *Machine Learning* 45:5–32.
  <https://doi.org/10.1023/A:1010933404324>
- Wright MN, Ziegler A (2017). ranger: a fast implementation of random forests for high
  dimensional data in C++ and R. *Journal of Statistical Software* 77(1):1–17.
  <https://doi.org/10.18637/jss.v077.i01>
- Hollmann N, Müller S, Purucker L, Krishnakumar A, Körfer M, Hoo SB, Schirrmeister RT,
  Hutter F (2025). Accurate predictions on small data with a tabular foundation model.
  *Nature* 637:319–326. <https://doi.org/10.1038/s41586-024-08328-6>
- Prior Labs (2026). TabPFN-3.5 model card and licence. <https://priorlabs.ai>
- Friedman J, Hastie T, Tibshirani R (2010). Regularization paths for generalized linear
  models via coordinate descent. *Journal of Statistical Software* 33(1):1–22.
  <https://doi.org/10.18637/jss.v033.i01> — `glmnet`, if picked.
- Chen T, Guestrin C (2016). XGBoost: a scalable tree boosting system. *KDD 2016*,
  785–794. <https://doi.org/10.1145/2939672.2939785> — `xgboost`, if picked.

### Tuning

- Li L, Jamieson K, DeSalvo G, Rostamizadeh A, Talwalkar A (2018). Hyperband: a novel
  bandit-based approach to hyperparameter optimization. *Journal of Machine Learning
  Research* 18(185):1–52.
- Jamieson K, Talwalkar A (2016). Non-stochastic best arm identification and
  hyperparameter optimization. *AISTATS 2016*, PMLR 51:240–248. — successive halving.

### Evaluation

- Varma S, Simon R (2006). Bias in error estimation when using cross-validation for
  model selection. *BMC Bioinformatics* 7:91. <https://doi.org/10.1186/1471-2105-7-91>
- Cawley GC, Talbot NLC (2010). On over-fitting in model selection and subsequent
  selection bias in performance evaluation. *Journal of Machine Learning Research*
  11:2079–2107.
- Bengio Y, Grandvalet Y (2004). No unbiased estimator of the variance of K-fold
  cross-validation. *Journal of Machine Learning Research* 5:1089–1105.
- Brodersen KH, Ong CS, Stephan KE, Buhmann JM (2010). The balanced accuracy and its
  posterior distribution. *ICPR 2010*, 3121–3124. <https://doi.org/10.1109/ICPR.2010.764>
- Platt J (1999). Probabilistic outputs for support vector machines and comparisons to
  regularized likelihood methods. In: *Advances in Large Margin Classifiers*, MIT Press,
  61–74. — the calibration step.
- Efron B, Tibshirani RJ (1993). *An Introduction to the Bootstrap.* Chapman & Hall. —
  the intervals on test sets.
- Pfisterer F, Wei S, Lang M. mlr3fairness: fairness auditing and debiasing for mlr3.
  R package. — the per-group fairness metrics.

### Explanation

- Štrumbelj E, Kononenko I (2014). Explaining prediction models and individual
  predictions with feature contributions. *Knowledge and Information Systems*
  41:647–665. <https://doi.org/10.1007/s10115-013-0679-x>
- Lundberg SM, Lee S-I (2017). A unified approach to interpreting model predictions.
  *NeurIPS 30.*
- Molnar C, Bischl B, Casalicchio G (2018). iml: an R package for interpretable machine
  learning. *Journal of Open Source Software* 3(26):786.
  <https://doi.org/10.21105/joss.00786>

### Case study data

- Carlino N, Blanco-Míguez A, Punčochář M, et al. (2024). Unexplored microbial diversity
  from 2,500 food metagenomes and links with the human microbiome. *Cell*
  187(20):5775–5795. <https://doi.org/10.1016/j.cell.2024.07.039> — the curated Food
  Metagenomic Data (cFMD).

## Acknowledgements

TabFlux grew out of the **MICROSUPPRESS** project (*The role of wheat microbiomes in
stress suppressiveness*) at the AIT Austrian Institute of Technology, funded by the
Austrian Science Fund (FWF), project
[P 36288](https://www.fwf.ac.at/en/research-radar/10.55776/P36288).

Much of the road from a single notebook to v1.6.0 — the nested evaluation, the
container, the cFMD module and this documentation — was travelled with
[Claude Code](https://claude.com/claude-code). Anthropic provided six months of Claude
Max through their Open Source programme. Every line was reviewed by the authors.
