# Licensing

**TabFlux** is released under the [Apache License 2.0](https://github.com/iLivius/TabFlux/blob/main/LICENSE);
the `NOTICE` file carries the copyright line.

**TabPFN weights** are not part of this code and carry their own licence. TabFlux uses
[TabPFN-3.5](https://priorlabs.ai/tabpfn-3-5), whose weights Prior Labs distribute under
the TabPFN-3.5 License v1.0: testing, evaluation and non-commercial research, including
internal benchmarking, are allowed; commercial, production, military, surveillance and
biometric uses are not, and a commercial arrangement with Prior Labs is a separate
matter. The non-commercial condition covers the model's outputs as well: predictions,
probabilities and explanations. The weights are downloaded on first use, after a one-time
licence acceptance on a Prior Labs account, made in the browser (a non-interactive run
confirms it with the account's API key in `TABPFN_TOKEN`); they are not inside the
container image. The `tabpfn` Python
package that loads them is itself Apache-2.0.

**Data.** No study data ship with this repository. The case study downloads a public
release of the [curated Food Metagenomic Data](https://github.com/SegataLab/cFMD) from
its own repository; see that repository for the terms attached to the data.

**Third-party software** invoked by the workflow (R packages, PyTorch, Quarto) is
distributed under its own licences, a mix of MIT, BSD, GPL and Apache; see each
package.
