# Run it chunk by chunk

`analysis/tabflux.qmd` runs one code cell (chunk) at a time, with every object left in
the R session to inspect, as in RStudio. Two routes:

| route | R and packages | editor |
|---|---|---|
| [in the container](#vs-code-in-the-container) (recommended) | the image's: R 4.5, date-pinned packages, Quarto, TabPFN, CUDA; the software of a container run | VS Code with the repository's dev container |
| [on the workstation](#rstudio-rstudio-server-positron) | your own R with TabFlux's packages, and the TabPFN conda environment | RStudio, RStudio Server, Positron or VS Code |

## Rules for any editor

1. **Source mode.** The notebook opens as plain text (`editor: source` in its header),
   where each chunk has its run controls. A visual editor has none, and Quarto's visual
   editor rewrites the notebook's commented header when it saves.
2. **Choose the configuration first.** In the R console, before the first chunk:

    ```r
    Sys.setenv(TABFLUX_CONFIG = "config_cfmd_demo.yaml")
    ```

    A relative path is taken from the repository root. Without the variable the notebook
    reads `config.yaml`, the template for your own data.

3. **One taxonomic level.** `dataset.tax_level` must name a single level. With several,
   the notebook stops ("Multiple taxonomic levels detected") and points to the wrapper,
   which runs one level after the other.
4. **A fresh R session.** The first chunks connect R to TabPFN's Python environment, which
   works only before anything in the session has started Python. After a restart, set
   `TABFLUX_CONFIG` again.
5. **In order, from the top.** Every chunk uses objects the chunks above created.
6. **Check the input.** After Set Parameters the console reports what was read; for the
   demo: `Input source: cFMD v1.3.2, 1020 samples x 4494 taxa from 18 datasets`.
7. **Results** go to the same run folder a rendered run writes, in `output.dir`. There is
   no HTML report: the [wrapper](#render-the-report) makes one. Tuned models and per-fold
   results are saved there, and running a chunk again reuses them; to start over, delete
   the run folder or change `dataset.version`.
8. **Preview, Render and Knit are not chunk runs.** They render the whole notebook in a
   separate R process, which reads `config.yaml`, not the `TABFLUX_CONFIG` set in the
   console.

## VS Code, in the container

The repository ships a development container (`.devcontainer/`). VS Code reopens the
repository inside the TabFlux image: the editor window runs on your computer; R, its
packages, Quarto, TabPFN and the GPU run in the container.

### What you need

| where | what |
|---|---|
| your computer | VS Code with the **Dev Containers** extension (`ms-vscode-remote.remote-containers`), installed in your local VS Code; **Remote - SSH** as well when the repository is on another machine |
| the machine that holds the repository | Docker, a checkout of the repository and, for the GPU, the NVIDIA driver and NVIDIA Container Toolkit |
| once | the TabFlux image. VS Code pulls `ghcr.io/ilivius/tabflux:1.6.0`; to use an image built from the checkout instead, build it under that name first: `docker build -t ghcr.io/ilivius/tabflux:1.6.0 .` |
| once, for TabPFN-3.5 | the weights in `~/.cache/tabpfn` on the Docker machine, or the means to download them ([TabPFN-3.5 weights](#tabpfn-35-weights)) |

### Open the repository in the container

1. Repository on another machine: F1 → **Remote-SSH: Connect to Host…**, then
   **File → Open Folder** on the repository folder itself.
2. F1 → **Dev Containers: Reopen in Container**. This turns the current window into the
   container window. To keep working on the host at the same time, open a second window
   first (**File → New Window**) and do steps 1–2 there.
3. The first time takes one to two minutes: VS Code adds a small layer to the TabFlux
   image and installs the Quarto and R extensions inside the container. Later openings
   take seconds. The status bar then reads **Dev Container: TabFlux**.
4. Check it in a terminal (**Terminal → New Terminal**; the prompt is in `/work`):

    ```bash
    R --version | head -1    # R 4.5.3
    nvidia-smi -L            # the GPU, when the host has one
    ```

| in the container | on the Docker machine |
|---|---|
| `/work` | the repository checkout; edits apply at once |
| `/work/out` | `out/` in the checkout (git-ignored): run folders, the cFMD download |
| `/home/tabflux/.cache/tabpfn` | `~/.cache/tabpfn`: TabPFN weights and the Prior Labs key |

The container runs as your own user: what it writes into the checkout belongs to you.

### Find your way through the notebook

- **Outline**: at the bottom of the Explorer side bar. It lists the notebook's sections,
  each with its code cell; a click jumps there. In its `…` menu, **Follow Cursor**
  highlights the cell you are in.
- **Outline on the right**, as in RStudio: open the right-hand side bar (**View →
  Appearance → Secondary Side Bar**, Ctrl+Alt+B) and drag the **OUTLINE** title into it.
- Above every ```` ```{r …} ```` line: **Run Cell | Run Next Cell | Run Above**.

### Run the cFMD demo

1. Open `analysis/tabflux.qmd`.
2. F1 → **R: Create R Terminal**. It opens an **R Interactive** terminal in `/work`;
   the cells run there.
3. In that terminal: `Sys.setenv(TABFLUX_CONFIG = "config_cfmd_demo.yaml")`.
4. Put the cursor in the header at the top of the notebook and press **Ctrl+Alt+N**
   (Run Next Cell) once per cell. It moves the cursor into the next cell, scrolls it into
   view and runs it, so the notebook is walked through without scrolling.

| key (macOS: Cmd for Ctrl) | action |
|---|---|
| Ctrl+Alt+N | run the next cell and move into it |
| Ctrl+Shift+Enter | run the cell the cursor is in |
| Shift+Enter | run the cell the cursor is in, then move to the next one |
| Ctrl+PageDown / Ctrl+PageUp | move to the next / previous cell without running it |
| Ctrl+Shift+Alt+P | run every cell above the cursor, to catch up after a restart |
| Ctrl+Enter | run the selected line(s) |

The terminal shows each line of code twice, now and then with stray characters: VS
Code types the cell into the terminal while R is still busy with earlier lines. The code
runs as written.

Almost all the time goes into three cells (the demo on one RTX 4090 workstation;
33 min in all):

| cells | what they do | time |
|---|---|---|
| the twelve before Train models | read the configuration and the cFMD data (downloaded the first time, seconds), build and normalise the table, select taxa | under a minute |
| Train models | tune and fit the final TabPFN and random-forest models | about 3 min |
| Benchmark | the three outer folds: selection, tuning and scoring in each | about 9 min |
| Prediction to External Test Set | save the metrics; the demo has no test sets | seconds |
| Feature Importance | SHAP for the best model, 100 samples | about 21 min |

Plots open as images in a VS Code tab; `View(x)` shows a data frame in a table viewer.
Results go to `out/<date>_TabFlux_demo_target_category_tax_sgb_saved_learners/`.

**Restart R**: close the R Interactive terminal (bin icon), open a new one with **R:
Create R Terminal**, set `TABFLUX_CONFIG` again, put the cursor in the cell to reach and
press Ctrl+Shift+Alt+P.

**The full cFMD run**: the same steps with `config_cfmd_category.yaml`: 3,680 samples,
five folds, three learners, about 1 h 40 min, of which about 50 min is SHAP.

### Render the report

In a container terminal (**Terminal → New Terminal**, not the R terminal):

```bash
Rscript scripts/run_multi_tax_levels.R config_cfmd_demo.yaml
```

It writes the run folder and the report `tabflux_demo_sgb.html` into `out/`.

### Your own data

Put the three files in `input/` and edit `config.yaml` as described in
[your own data](your-data.md), with one taxonomic level for a chunk-by-chunk run.
`TABFLUX_CONFIG` is not needed for `config.yaml`. Run folders go to the repository root
(git-ignored), or to `out/` with `output.dir: "/work/out"`.

### TabPFN-3.5 weights

TabPFN downloads the weights the first time, after a one-time licence acceptance on a
Prior Labs account, and only then: with the weights in `~/.cache/tabpfn`, nothing else is
needed. For the first download:

1. Log in at <https://ux.priorlabs.ai>, accept the licence on the Licenses tab and copy
   the API key from the account page.
2. On the Docker machine, store the key where the package looks for it; the container
   reads it through the mounted cache:

    ```bash
    mkdir -p ~/.cache/tabpfn
    printf '%s' 'YOUR_API_KEY' > ~/.cache/tabpfn/auth_token
    chmod 600 ~/.cache/tabpfn/auth_token
    ```

The same `.devcontainer/` works with Positron's dev container support, which is
experimental (setting `dev.containers.enable`).

## RStudio, RStudio Server, Positron

Without the container, the notebook runs on the R the editor starts, with the packages
installed in it. Numbers can differ slightly from a container run, whose package
versions are pinned ([installation](installation.md#conda)).

### What you need

- **An R with TabFlux's packages**, run by the editor:
    - the conda route of [installation](installation.md#conda) installs them into the
      `tabflux-r` environment. Start RStudio from a shell where that environment is
      active; in Positron, select its R as the interpreter; in VS Code, set the R
      extension's R path to it;
    - RStudio Server runs one R for all its users, chosen by the administrator (usually
      the system R, not a conda environment). That R needs the packages listed in
      `conda/install_r_packages.R`.
- **The TabPFN environment** from the conda route (`tabflux-tabpfn35-gpu`).
- **A configuration with workstation paths.** The cFMD configurations write to
  container paths (`/work/out`). Copy one into `input/` (git-ignored) and change three
  entries:

    ```bash
    cp config_cfmd_demo.yaml input/demo_workstation.yaml
    ```

    | entry | value |
    |---|---|
    | `output.dir` | `"out"`: run folders in `out/` of the repository |
    | `input.cfmd.cache_dir` | `"out/cfmd_cache"` |
    | `runtime.tabpfn.env_name` | the TabPFN environment's full path, e.g. `"/home/me/miniforge3/envs/tabflux-tabpfn35-gpu"` (`conda env list` shows it). A bare name needs the notebook to find conda by itself (on the PATH or in a standard install location), which an RStudio Server session may not; the full path always works |

### Run it

1. RStudio: **Session → Restart R**. Positron: restart the R session. VS Code: a new R
   terminal.
2. In the console: `Sys.setenv(TABFLUX_CONFIG = "input/demo_workstation.yaml")`.
3. Open `analysis/tabflux.qmd` and run the chunks from the top. In RStudio: Ctrl+Alt+N
   runs the next chunk, Ctrl+Shift+Enter the current one, Ctrl+Alt+P every chunk above;
   Ctrl+Shift+O shows the outline. Chunk output goes to the console (the header sets
   `chunk_output_type: console`).

The notebook finds the repository from the open file in RStudio, and from the R
session's working directory elsewhere: in Positron and VS Code, open the repository
folder itself. If it still stops with "Could not resolve the project root", set
`Sys.setenv(TABFLUX_WORKDIR = "/path/to/TabFlux")` before the first chunk.

## When something goes wrong

| symptom | cause and fix |
|---|---|
| the notebook opens in the visual editor (a toolbar with Normal, Format, Insert) and no cell has **Run Cell** | the header lost its `editor: source` line, and the visual editor may have rewritten the file; restore it (`git checkout -- analysis/tabflux.qmd`), close the tab and open the file again. Ctrl+Shift+F4 switches an open file to source mode |
| "Multiple taxonomic levels detected in 'dataset.tax_level'" | `TABFLUX_CONFIG` was not set, so `config.yaml` was read, or the configuration lists several levels; set it and run from the first chunk in a fresh session |
| Preview or Render stops in the `settings` chunk | they render with `config.yaml`; run chunks instead, or [render with the wrapper](#render-the-report) |
| "Cannot write to the output folder", or "Download failed … the cache folder is not writable" | `out/` belongs to root: Docker created it for an earlier `docker run -v "$PWD/out:/work/out"`, or a run without `--user` wrote it. Give it back to your user, on the Docker machine: `docker run --rm --user 0 -v "$PWD/out:/o" ghcr.io/ilivius/tabflux:1.6.0 chown -R "$(id -u):$(id -g)" /o` |
| **Reopen in Container** fails to pull `ghcr.io/ilivius/tabflux:1.6.0` | the image is not on the registry, or not public; build it locally under that name ([what you need](#what-you-need)) |
| TabPFN stops with a licence message | no weights in the cache and no key; see [TabPFN-3.5 weights](#tabpfn-35-weights) |
| "TabPFN Python not found at '…'" (workstation) | the notebook could not find the TabPFN environment from its name; give its full path in `runtime.tabpfn.env_name` |
| plots do not appear (VS Code) | R was started by typing `R` in a plain terminal; use **R: Create R Terminal** |
| no autocompletion, no hover help (VS Code, container) | the image has no `languageserver` package; the dev container turns the R extension's language server off |
| a change to `.devcontainer/` or to a host variable has no effect | F1 → **Dev Containers: Rebuild Container** |
