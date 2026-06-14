IMAGE ?= quay.io/$(USER)/workload-inspector
TAG   ?= latest
FULL  := $(IMAGE):$(TAG)
NS    ?= workload-inspector

.PHONY: build push deploy-all deploy-standard deploy-kata deploy-kata-remote deploy-kata-cc clean

build:
	podman build -t $(FULL) -f Containerfile .

push: build
	podman push $(FULL)

deploy-all: deploy-standard deploy-kata deploy-kata-remote deploy-kata-cc

deploy-standard:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-standard.yaml | oc apply -f -
	oc apply -f k8s/service.yaml -f k8s/route.yaml

deploy-kata:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-kata.yaml | oc apply -f -
	oc apply -f k8s/service.yaml -f k8s/route.yaml

deploy-kata-remote:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-kata-remote.yaml | oc apply -f -
	oc apply -f k8s/service.yaml -f k8s/route.yaml

deploy-kata-cc:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-kata-cc.yaml | oc apply -f -
	oc apply -f k8s/service.yaml -f k8s/route.yaml

clean:
	oc delete namespace $(NS) --ignore-not-found
