SHELL = /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Image URL to use all building/pushing image targets
TAG ?= $(shell git describe --tags --abbrev=0 --match 'v[0-9].*[0-9].*[0-9]' 2>/dev/null )
IMG ?= ghcr.io/banzaicloud/kafka-operator:$(TAG)

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,preserveUnknownFields=false"

RELEASE_TYPE ?= p
RELEASE_MSG ?= "operator release"

REL_TAG = $(shell ./scripts/increment_version.sh -${RELEASE_TYPE} ${TAG})

GOLANGCI_VERSION = 1.38.0
LICENSEI_VERSION = 0.2.0
GOPROXY=https://proxy.golang.org

CONTROLLER_GEN_VERSION = v0.5.0
CONTROLLER_GEN = $(PWD)/bin/controller-gen

KUSTOMIZE_BASE = config/overlays/specific-manager-version

HELM_CRD_PATH = charts/kafka-operator/templates/crds.yaml

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

export PATH := $(PWD)/bin:$(PATH)

all: test manager

.PHONY: check
check: test lint ## Run tests and linters

bin/golangci-lint: bin/golangci-lint-${GOLANGCI_VERSION}
	@ln -sf golangci-lint-${GOLANGCI_VERSION} bin/golangci-lint
bin/golangci-lint-${GOLANGCI_VERSION}:
	@mkdir -p bin
	curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | bash -s -- -b ./bin v${GOLANGCI_VERSION}
	@mv bin/golangci-lint $@

.PHONY: lint
lint: bin/golangci-lint ## Run linter
	@bin/golangci-lint run -v
	cd pkg/sdk && golangci-lint run -c ../../.golangci.yml
	cd properties && golangci-lint run -c ../.golangci.yml

bin/licensei: bin/licensei-${LICENSEI_VERSION}
	@ln -sf licensei-${LICENSEI_VERSION} bin/licensei
bin/licensei-${LICENSEI_VERSION}:
	@mkdir -p bin
	curl -sfL https://raw.githubusercontent.com/goph/licensei/master/install.sh | bash -s v${LICENSEI_VERSION}
	@mv bin/licensei $@

.PHONY: license-check
license-check: bin/licensei ## Run license check
	bin/licensei check
	./scripts/check-header.sh

.PHONY: license-cache
license-cache: bin/licensei ## Generate license cache
	bin/licensei cache

# Install kustomize
install-kustomize:
	@ if ! which bin/kustomize &>/dev/null; then\
		scripts/install_kustomize.sh;\
	fi

# Run tests
ENVTEST_ASSETS_DIR=$(shell pwd)/testbin
test: generate fmt vet
	cd pkg/sdk && go test ./...
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.8.3/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR);  go test ./... -coverprofile cover.out
	cd properties && go test -coverprofile cover.out -cover -failfast -v -covermode=count ./pkg/... ./internal/...

# Build manager binary
manager: generate fmt vet
	go build -o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet
	go run ./main.go

# Install CRDs into a cluster by manually creating or replacing the CRD depending on whether is currently existing
# Apply is not applicable as the last-applied-configuration annotation would exceed the size limit enforced by the api server
install: manifests
ifeq ($(shell kubectl get -f config/base/crds >/dev/null 2>&1; echo $$?), 1)
	kubectl create -f config/base/crds
else
	kubectl replace -f config/base/crds
endif

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: install-kustomize install
	# creates the kafka namespace
	bin/kustomize build config | kubectl apply -f -
	./scripts/image_patch.sh "${KUSTOMIZE_BASE}/manager_image_patch.yaml" ${IMG}
	bin/kustomize build $(KUSTOMIZE_BASE) | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: bin/controller-gen
	cd pkg/sdk && $(CONTROLLER_GEN) $(CRD_OPTIONS) webhook paths="./..." output:crd:artifacts:config=../../config/base/crds output:webhook:artifacts:config=../../config/base/webhook
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role paths="./controllers/..." output:rbac:artifacts:config=./config/base/rbac
	## Regenerate CRDs for the helm chart
	echo "{{- if .Values.crd.enabled }}" > $(HELM_CRD_PATH)
	cat config/base/crds/kafka.banzaicloud.io_kafkaclusters.yaml >> $(HELM_CRD_PATH)
	cat config/base/crds/kafka.banzaicloud.io_kafkatopics.yaml >> $(HELM_CRD_PATH)
	cat config/base/crds/kafka.banzaicloud.io_kafkausers.yaml >> $(HELM_CRD_PATH)
	echo "{{- end }}" >> $(HELM_CRD_PATH)

# Run go fmt against code
fmt:
	go fmt ./...
	cd pkg/sdk && go fmt ./...
	cd properties && go fmt ./...

# Run go vet against code
vet:
	go vet ./...
	cd pkg/sdk && go fmt ./...
	cd properties && go vet ./...

# Generate code
generate: bin/controller-gen
	cd pkg/sdk && $(CONTROLLER_GEN) object:headerFile=./../../hack/boilerplate.go.txt paths="./..."

# Build the docker image
docker-build:
	docker build . -t ${IMG}

# Push the docker image
docker-push:
	docker push ${IMG}

# find or download controller-gen
# download controller-gen if necessary
bin/controller-gen:
	@ if ! test -x bin/controller-gen; then \
		set -ex ;\
		CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
		cd $$CONTROLLER_GEN_TMP_DIR ;\
		go mod init tmp ;\
		GOBIN=$(PWD)/bin go get sigs.k8s.io/controller-tools/cmd/controller-gen@${CONTROLLER_GEN_VERSION} ;\
		rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	fi

check_release:
	@echo "A new tag (${REL_TAG}) will be pushed to Github, and a new Docker image will be released. Are you sure? [y/N] " && read ans && [ $${ans:-N} == y ]

release: check_release
	git tag -a ${REL_TAG} -m ${RELEASE_MSG}
	git push origin ${REL_TAG}
