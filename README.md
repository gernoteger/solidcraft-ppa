# solidcraft-ppa

Self-maintaining Launchpad PPA for [SolidCraft](https://solidcraft.io/).

A scheduled GitHub Actions workflow watches the upstream
[`tangency-labs/solidcraft`](https://github.com/tangency-labs/solidcraft)
releases, downloads the prebuilt Linux `.deb` files, verifies their SHA-256
sums, wraps them in a signed Debian source package and uploads that to
`ppa:gernoteger/solidcraft` for every configured Ubuntu series.

Launchpad does not accept binary uploads and its builders have no network
access. Upstream publishes neither a `debian/` directory nor a vendored Cargo
tree, so this PPA repackages the official release binaries instead of compiling
them. The binaries are byte-identical to the upstream release.

## Install

```sh
sudo add-apt-repository ppa:gernoteger/solidcraft
sudo apt update
sudo apt install solidcraft
```

## One-time setup

1. **Create the PPA** at
   <https://launchpad.net/~gernoteger/+activate-ppa> (name: `solidcraft`), then
   enable **amd64** and **arm64** under *Change details*.
   `LP_OWNER`/`LP_ARCHIVE` in the workflow are your **Launchpad** username and
   PPA name; the Launchpad username can differ from your GitHub handle, so
   adjust them (and the links above) if necessary.

2. **Create a dedicated signing key** with a certify-only primary key and a
   signing subkey. CI then only needs the subkey, and the primary key can stay
   offline:

   ```sh
   # Certify-only primary key
   gpg --quick-generate-key "Gernot Eger <gernot.eger@gmail.com>" rsa4096 cert 5y
   gpg --list-secret-keys --keyid-format long
   FPR=<primary fingerprint from the sec line>

   # Signing subkey (GnuPG 2.2+)
   gpg --quick-add-key "$FPR" rsa4096 sign 3y

   # Note the ssb fingerprint; that is GPG_KEY_ID
   gpg --list-secret-keys --keyid-format long --with-subkey-fingerprint "$FPR"

   # Public key for Launchpad (includes the subkey)
   gpg --armor --export "$FPR" > solidcraft-ppa.asc

   # Secret subkeys for CI (primary secret is exported as a stub only)
   gpg --armor --export-secret-subkeys "$FPR" > solidcraft-ppa-secret.asc
   ```

   If you already have a key, run only the `--quick-add-key` step with its
   primary fingerprint, then repeat the two exports (and re-upload the public
   key if it was already registered). With `gpg --edit-key "$FPR"` you can use
   `addkey` → *RSA (sign only)* → `4096` → `3y` → `save` instead.

   Register `solidcraft-ppa.asc` at
   <https://launchpad.net/people/+me/+editpgpkeys> and confirm the email
   Launchpad sends you. The subkey uses the primary key's passphrase; if it has
   one, also set `GPG_PASSPHRASE` below. If you want the subkey to be
   passphrase-less, change it with `gpg --edit-key "$FPR"` → `key 1` → `passwd`.

3. **Add repository secrets** (*Settings → Secrets and variables → Actions*):

   | Secret | Value |
   | --- | --- |
   | `GPG_PRIVATE_KEY` | contents of `solidcraft-ppa-secret.asc` |
   | `GPG_KEY_ID` | fingerprint of the signing **subkey** (`ssb` line) |
   | `GPG_PASSPHRASE` | optional, only for a protected subkey |

4. **Push this repository to GitHub** and run the workflow once by hand:
   *Actions → PPA → Run workflow*. Builds for uploaded sources appear at
   <https://launchpad.net/~gernoteger/+archive/ubuntu/solidcraft/+packages>.

## How it works

`prepare` resolves the latest upstream release, downloads
`solidcraft-linux-x86_64.deb`, `solidcraft-linux-aarch64.deb` and
`SHA256SUMS.txt`, verifies them and asks the Launchpad API which series are
missing the new version. `upload` then runs once per series and:

- rewrites `debian/changelog` for that series with a deterministic date,
- creates `solidcraft_<upstream>.orig.tar.gz` from the working tree (everything
  but `debian/`; the vendored `.debs` are in the orig tarball),
- builds and GPG-signs the source package,
- `dput`s it to Launchpad.

The version is the upstream Debian version with `ppa1` appended to the
revision: upstream `0.17.0-1` becomes `0.17.0-1ppa1`, which upgrades over the
release `.deb`. A version that is already published is never uploaded again,
because Launchpad rejects duplicate versions even after a failed build.

The default series are `noble` and `resolute`. Edit `DEFAULT_SERIES` in
`.github/workflows/ppa.yml` (or pass the `series` input) to change them.
`jammy` also satisfies the binary's `libc6 (>= 2.35)` floor if you want it.

## Manual runs and local testing

```sh
# Fetch and verify the latest upstream debs into vendor/
scripts/fetch-upstream.sh            # or: scripts/fetch-upstream.sh v0.17.0

# Which series still need this version?
scripts/missing-series.sh 0.17.0-1ppa1

# Build a source package locally (unsigned)
scripts/build-source.sh resolute

# Or build the binary package to inspect it (needs the vendored debs)
dpkg-buildpackage -b -us -uc
```

`make vendor`, `make source SERIES=noble` and `make clean` wrap the common
commands. `vendor/metadata.env` is written by the fetch script and is ignored by
git.

## Things to keep an eye on

- Each upload carries both debs (~130 MB) into every series, so PPA space adds
  up quickly. Delete superseded source versions and old binaries in the
  Launchpad UI from time to time.
- Upstream asset names must stay `solidcraft-linux-{x86_64,aarch64}.deb` and
  `SHA256SUMS.txt`; update `scripts/fetch-upstream.sh` if they change.
- If a Launchpad build fails, use *Rebuild this package* on the package page.
  The workflow intentionally will not upload an already published version
  again, because Launchpad rejects duplicate versions.
- If the signing key expires or is replaced, update the Launchpad key and the
  `GPG_KEY_ID` secret.
- SolidCraft is Apache-2.0/MIT; see `debian/copyright`. This is an unofficial
  repackaging by the PPA maintainer.
