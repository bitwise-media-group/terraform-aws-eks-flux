# Development

The repo uses the shared [toolchain], mounted as the `.mise/` submodule. It pins every tool (terraform, tflint,
terraform-docs, prettier, markdownlint, uv, …) and provides the terraform archetype's tasks. The `Makefile` is a thin
forwarder: `make <task>` is the same as `mise run <task>`.

Once per clone:

```sh
git submodule update --init
mise trust --all
```

## Tasks

| Task         | What it does                                                                                                                |
| ------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `make fmt`   | `terraform fmt -recursive` and the prose formatter                                                                          |
| `make lint`  | License headers, validate + tflint (root and `examples/*`), terraform-docs `--output-check`, prose, shell and workflow lint |
| `make test`  | `terraform test` for every configuration with a test suite (the root and each `modules/*/tests`)                            |
| `make docs`  | Regenerate the terraform-docs block in every README                                                                         |
| `make build` | Build this documentation site into `site/`                                                                                  |
| `make serve` | Serve the documentation site locally, with live reload                                                                      |
| `make pr`    | The full local gate: `fmt`, `lint`, `docs`, `test`, `build`                                                                 |
| `make help`  | List every task                                                                                                             |

Everything in `make lint` and `make test` runs against mocked providers, so you need no credentials to develop here. The
tests are plan-time `terraform test` suites under `tests/` and `modules/*/tests/`.

Applying a cluster for real also needs the **AWS CLI**. See [Caveats](caveats.md#the-helm-provider-needs-the-aws-cli).

## The documentation site

This site is built with [Zensical] from `docs/`, configured in `zensical.toml`, with the BitWise Media Group theme in
`docs/stylesheets/extra.css` and `overrides/`. uv provisions Zensical from `pyproject.toml` and `uv.lock`.

```sh
make serve   # http://localhost:8003, rebuilds on save
make build   # renders site/, the same build CI runs
```

CI runs `make build` on every pull request, so a broken page or a missing embedded file fails the check. When a release
is cut, the release workflow builds the site from the tag and publishes it to GitHub Pages.

### Generated content, and why it can't drift

Two kinds of content are embedded from the source tree when the site builds, rather than copied into `docs/`:

- **Module reference tables.** terraform-docs writes each module's requirements, providers, resources, inputs and
  outputs between the `BEGIN_TF_DOCS` / `END_TF_DOCS` markers in its `README.md`. A `tf-docs` snippet section wraps that
  block, and each module page embeds it with `--8<-- "modules/<name>/README.md:tf-docs"`.
- **Example code.** The [Examples](../getting-started/examples.md) page embeds each `examples/*/main.tf` whole.

The chain that keeps them correct:

1. `make docs` regenerates the README blocks from the `.tf` sources.
2. `make lint` runs `terraform-docs --output-check`, so a pull request with a stale README fails CI.
3. The site embeds those README blocks, and `check_paths` fails the build if a file or section is missing.

Don't edit the generated block in a README by hand. Change the variable or output `description` in the `.tf` file and
run `make docs`. Keep the `<!-- --8<-- [start:tf-docs] -->` / `[end:tf-docs]` comment lines either side of the
terraform-docs markers.

### Adding a module

1. Create `modules/<name>/` with the canonical layout and a `README.md`.
2. Run `make docs`. terraform-docs adds the generated block, because `.terraform-docs.yml` recurses into `modules/`.
3. Wrap the block in `tf-docs` snippet markers, as the existing module READMEs do.
4. Add `docs/modules/<name>.md`, ending with `--8<-- "modules/<name>/README.md:tf-docs"`, and add it to `nav` in
   `zensical.toml`.

[toolchain]: https://oss.bitwisemedia.uk/toolchain/
[Zensical]: https://zensical.org/
