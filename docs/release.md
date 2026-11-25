# Make a new release

A release has two parts:

1. **peridiod.** You push a tag. The `Build and Push Release` workflow then makes the GitHub release, the Docker images, and the deb and rpm packages.
2. **meta-peridio.** Yocto users build peridiod from the recipe in [meta-peridio](https://github.com/peridio/meta-peridio). The recipe points to one peridiod commit. Until you update the recipe, Yocto users keep the previous version.

The examples use `3.5.0`. Use your version.

## 1. Before you start

1. Make sure that `main` passes CI. `mix hex.audit` fails when a new advisory is published for a dependency, even if no code changed. Fix advisories in a separate PR before the release PR.
2. Make sure that each PR merged since the last tag has an entry under `## Unreleased` in `CHANGELOG.md`. Compare with `git log <last tag>..main`.
3. Choose the version. Use a minor version (`3.5.0`) if the release has new features, and a patch version (`3.4.2`) if it has only fixes.

## 2. Release PR

1. Set `VERSION` to `3.5.0`.
2. In `CHANGELOG.md`, change `## Unreleased` to `## 3.5.0`. The heading must be the same as the tag. CI uses the text in this section as the release notes and the package notes.
3. If a change has an effect on devices after an update (for example a new default or a stricter check), add it to an `Upgrade notes` list at the top of the section.
4. Open a PR into `main`. Merge it after review and after CI passes.

## 3. Tag

```bash
git checkout main && git pull
cat VERSION          # must be 3.5.0
git tag 3.5.0
git push origin 3.5.0
```

1. Do not use a `v` prefix.
2. The tag must be the same as `VERSION`. `mix release` makes `peridiod-<VERSION>.tar.gz`, and the deb and rpm jobs look for `peridiod-<tag>.tar.gz`. If they are different, these jobs fail.
3. Tag the merge commit of the release PR on `main`.

## 4. CI

The tag starts `.github/workflows/build_push_release.yml`:

1. `create_release`: makes the GitHub release from the `## 3.5.0` section of `CHANGELOG.md`.
2. `create_container_images` and `create_container_manifest`: push `peridio/peridiod:3.5.0`, `3.5.0-arm64` and `3.5.0-amd64`, and move `latest` to `3.5.0`.
3. `create_debs`: jammy and noble, arm64 and amd64.
4. `create_rpms`: rhel9, arm64 and amd64.

When the workflow is done, the release has 4 deb files and 2 rpm files. Check with `gh release view 3.5.0`.

If a job fails, re-run that job. `create_release` skips a release that exists, and the uploads replace files that are already there. Do not delete or move a tag after its packages are published.

## 5. meta-peridio

Update the recipe on each branch: `kirkstone`, `scarthgap` and `main`. The recipe files are the same on all three branches.

```bash
git checkout kirkstone && git pull
git checkout -b peridiod-3.5.0-kirkstone
git mv recipes-peridio/peridiod/peridiod_3.4.1.bb recipes-peridio/peridiod/peridiod_3.5.0.bb
```

Edit `recipes-peridio/peridiod/peridiod_3.5.0.bb`:

```
require peridiod.inc

PV = "3.5.0"

SRCREV = "<full 40-character SHA of the 3.5.0 tag>"
SRCBRANCH = "main"
```

Get the SHA with `git rev-parse 3.5.0^{commit}` in peridiod. Commit with the message `peridiod: v3.5.0 release`, and open a PR into the branch. Do the same for `scarthgap` and `main`.
