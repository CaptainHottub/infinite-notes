# Contributing and local development

## Branches

- Keep `main` releasable.
- Merge tested work into `develop` first.
- Use `prototype/<topic>` for experiments.
- Use `feature/<topic>` or `fix/<topic>` for focused changes.

Use lowercase names with hyphens, for example:

```bash
git switch develop
./scripts/new-prototype.sh alternate-spline
```

## Before committing

```bash
./scripts/test-all.sh
git status --short
```

Do not commit files from `computer/data/`, `.inotes` archives, PDFs containing personal notes, signing credentials, `.build`, `.swiftpm`, `xtool`, or Python virtual environments.

## Commit style

Prefer small commits with imperative subjects:

```text
Fix page rotation transform
Add pressure ribbon diagnostics
Refactor selection hit testing
```

## Releasing

Update `VERSION` and `CHANGELOG.md`, run all validation, merge to `main`, then:

```bash
git tag -a vX.Y.Z -m "Infinite Notes X.Y.Z"
git push origin main develop --tags
```
