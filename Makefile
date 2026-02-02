# StreamVault Makefile

FORGE := ~/.foundry/bin/forge

.PHONY: build test test-v test-gas fmt fmt-check snapshot clean install check

# Build contracts
build:
	$(FORGE) build

# Run all tests
test:
	$(FORGE) test

# Run tests with verbose output
test-v:
	$(FORGE) test -vv

# Run tests with gas reporting
test-gas:
	$(FORGE) test --gas-report

# Format Solidity files
fmt:
	$(FORGE) fmt

# Check formatting without modifying files
fmt-check:
	$(FORGE) fmt --check

# Generate gas snapshots
snapshot:
	$(FORGE) snapshot

# Install dependencies
install:
	$(FORGE) install

# Remove build artifacts
clean:
	$(FORGE) clean

# Run all checks (format check + build + tests)
check: fmt-check build test
