.PHONY: setup run run-lan test ipad backup bundle

setup:
	./scripts/setup-computer.sh

run:
	./scripts/run-computer.sh

run-lan:
	./scripts/run-computer.sh --no-hotspot

test:
	./scripts/test-all.sh

ipad:
	./scripts/build-ipad.sh

backup:
	./scripts/backup-data.sh

bundle:
	./scripts/export-git-bundle.sh
