# Version control and transfer

## Initial repository state

This archive includes a real Git repository with:

- `main` — stable v0.5.1 baseline
- `develop` — integration branch
- annotated tag `v0.5.1`

## Create a hosted remote

Create an empty private repository on GitHub, GitLab, Codeberg or another Git host. Do not initialize it with a README. Then run:

```bash
git remote add origin <REMOTE-URL>
git push -u origin main
git push -u origin develop
git push origin --tags
```

On another computer:

```bash
git clone <REMOTE-URL> infinite-notes
cd infinite-notes
./scripts/setup-computer.sh
```

Notebook data is separate; use `scripts/backup-data.sh` and transfer the resulting archive privately.

## Prototype branches

Create a prototype from `develop`:

```bash
git switch develop
./scripts/new-prototype.sh new-renderer
```

This creates and switches to `prototype/new-renderer`.

Keep it:

```bash
git switch develop
git merge --no-ff prototype/new-renderer
```

Discard it:

```bash
git switch develop
git branch -D prototype/new-renderer
```

## Offline transfer with a Git bundle

Create a portable file containing every branch and tag:

```bash
./scripts/export-git-bundle.sh
```

Clone it elsewhere:

```bash
git clone transfer/infinite-notes-all.bundle infinite-notes
```

After cloning a bundle, add your normal hosted remote when available.

## Move notebook data

Create a private data archive:

```bash
./scripts/backup-data.sh
```

Restore it in another clone:

```bash
./scripts/restore-data.sh /path/to/infinite-notes-data-YYYYMMDD-HHMMSS.tar.gz
```

Data archives are ignored and must not be pushed to a public repository.

## Switch versions

List versions:

```bash
git tag --list --sort=-version:refname
```

Temporarily inspect an old release:

```bash
git switch --detach v0.5.1
```

Return to current work:

```bash
git switch main
```
