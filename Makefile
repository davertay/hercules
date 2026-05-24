.PHONY: help build test test-lib

help:
	@echo "make build - build the entire project"
	@echo "make test - run all tests"
	@echo "make test-lib - test the lib package"

build:
	xcodebuild build \
		-project Hercules.xcodeproj \
		-scheme Hercules \
		-destination 'platform=macOS,arch=arm64' \
		-skipMacroValidation \
		CODE_SIGNING_ALLOWED=NO

test:
	xcodebuild test \
		-project Hercules.xcodeproj \
		-scheme Hercules \
		-destination 'platform=macOS,arch=arm64' \
		-skipMacroValidation \
		CODE_SIGNING_ALLOWED=NO

test-lib:
	cd lib && swift test

