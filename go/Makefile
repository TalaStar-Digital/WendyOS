.PHONY: build build-cli build-agent test vet proto clean

# Build both CLI and agent
build: build-cli build-agent

# Build the wendy CLI
build-cli:
	go build -o bin/wendy ./cmd/wendy

# Build the wendy-agent
build-agent:
	go build -o bin/wendy-agent ./cmd/wendy-agent

# Build for Linux arm64 (Jetson)
build-agent-linux:
	GOOS=linux GOARCH=arm64 go build -o bin/wendy-agent-linux-arm64 ./cmd/wendy-agent

# Run all tests
test:
	go test ./... -v -count=1 -timeout 120s

# Run tests with race detector
test-race:
	go test ./... -v -count=1 -race -timeout 120s

# Run go vet
vet:
	go vet ./...

# Generate protobuf code
proto:
	bash scripts/generate-proto.sh

# Clean build artifacts
clean:
	rm -rf bin/

# Install both binaries
install:
	go install ./cmd/wendy
	go install ./cmd/wendy-agent

# Format code
fmt:
	gofmt -w -s .

# Lint (requires golangci-lint)
lint:
	golangci-lint run ./...
