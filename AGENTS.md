# Instructions for coding agents in a hep-forge feedstock

This repo is a **hep-forge** feedstock: a conda recipe published to the
[hep-forge](https://anaconda.org/hep-forge) channel. It follows hep-forge
rules, **not** conda-forge's. The full rules are in the meta-repo
[hep-forge/.github](https://github.com/hep-forge/.github), in
[AGENTS.md](https://github.com/hep-forge/.github/blob/main/AGENTS.md). Read
that file before changing anything outside `recipe/`.

This file is rendered from `scripts/templates/AGENTS.md` in hep-forge/.github.
Don't edit it here.

## What you may edit

- `recipe/**`: `meta.yaml`, `build.sh`, `conda_build_config.yaml`, patches, test scripts.
- Your own extra docs or workflows (for example `BUILDING.md`, a PR smoke-test
  workflow). Those must never upload to anaconda.org.

## What is rendered (overwritten every day, so don't edit it here)

| File | Source in hep-forge/.github |
|---|---|
| `.github/workflows/autoupload.yml` | `scripts/templates/autoupload.yml` |
| `.github/workflows/hep-bot-comment.yml` | `scripts/templates/hep-bot-comment.yml` |
| `README.md` | `scripts/generate_readme.py` (reads `recipe/meta.yaml`) |
| `AGENTS.md` | `scripts/templates/AGENTS.md` |

To re-apply the render now, comment `@hep-bot rerender` on an issue here or in
hep-forge/.github. Do **not** run `conda smithy rerender` to fix CI. It writes
conda-forge CI files that hep-forge doesn't use.

## Rules that are easy to get wrong

- **Only a tag builds and publishes**: a numeric release tag (`[0-9]*`), or `head`.
  Merging a PR or pushing to `main` publishes nothing. Tag `main` only after the
  recipe has been merged. A release tag is the version (`X-y` publishes as `X.y`),
  and it must be a key in the `versions` dict at the top of `meta.yaml`.
- `head` is the tag for upstream main/master. The recipe must resolve the version
  `head` to the upstream branch (for a git source,
  `git_rev: {{ versions.get(version, "HEAD") }}`). hep-bot rebuilds it when upstream
  moves. Don't add `head` to the `versions` dict with a fixed commit.
- Branches are anaconda labels (`main` -> `main`, `legacy` -> `legacy`). A second
  version line goes on its own branch, with tags created on that branch.
- Keep the version header (`versions` dict, `COMMIT_VERSION`, `ANACONDA_PACKAGE`,
  `ANACONDA_VERSION`). CI injects those variables.
- CI runs a plain `conda build recipe` with channels `hep-forge`, `conda-forge`,
  `defaults` and strict priority. No conda-forge global pinning is applied, so pin
  compilers and the glibc floor in `recipe/conda_build_config.yaml`
  (`c_stdlib_version: 2.17`).
- conda-build filters the environment, so CI variables don't reach `build.sh`.
  Export what the build needs (for example `CMAKE_POLICY_VERSION_MINIMUM=3.5`) in
  `build.sh`.
- conda's `CMAKE_ARGS` sets `CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY`, which hides
  headers in the source tree. Add explicit include directories.
- Platforms: linux-64 and linux-aarch64 are published. A macos-arm64 leg is
  compiled but never published. If the package can't build on macOS, add
  `skip: true  # [not linux]` under `build:` rather than asking for repo variables.
- Shared libraries need `run_exports: [{{ pin_subpackage(name, max_pin="x.x") }}]`.
  Tests must exercise the installed package, not just `echo`.
- The repo's `.gitignore` starts with `*`, so new files outside `recipe/` need
  `git add -f`. Otherwise they are silently left out of the commit.
- The channel keeps only the newest 2 versions per label. Older versions that
  must stay go in `extra.lts`.
- A GitHub release only hosts a file the recipe downloads (e.g. a tarball mirror). Its
  title is the tag, with no notes: `gh release create <tag> <file> --title <tag> --notes ""`.
- Rebuilding an existing tag: `@hep-bot rerun <tag>` rebuilds the recipe *as of
  that tag*. To ship a recipe fix under the same version, move the tag with
  `make retag <name>` in hep-forge/.github, or bump `build.number` and retag.
