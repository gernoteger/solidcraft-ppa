SERIES ?= resolute
TAG ?=
KEY ?=

.PHONY: vendor source clean

vendor:
	scripts/fetch-upstream.sh $(TAG)

source:
	@test -f vendor/metadata.env || { echo "run 'make vendor' first" >&2; exit 1; }
	@set -a; . ./vendor/metadata.env; set +a; \
		scripts/build-source.sh "$(SERIES)" "$$UPSTREAM_DATE" "$(KEY)"

clean:
	rm -rf debian/files debian/.debhelper debian/solidcraft \
		debian/debhelper-build-stamp debian/*.substvars \
		../solidcraft_*.orig.tar.gz ../solidcraft_*.debian.tar.* \
		../solidcraft_*.dsc ../solidcraft_*.changes ../solidcraft_*.buildinfo \
		../solidcraft_*_source.changes
