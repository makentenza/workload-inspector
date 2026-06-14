IMAGE ?= quay.io/$(USER)/workload-inspector
TAG   ?= latest
FULL  := $(IMAGE):$(TAG)
NS    ?= workload-inspector

.PHONY: build push deploy-all deploy-dashboard deploy-standard deploy-kata deploy-kata-remote deploy-kata-cc clean

build:
	podman build -t $(FULL) -f Containerfile .

push: build
	podman push $(FULL)

# Deploy everything: the aggregator dashboard (Service + Route owner) plus all
# four probe variants. Probe pods are discovered by the dashboard in-cluster;
# they are not exposed through the Route themselves.
deploy-all: deploy-dashboard deploy-standard deploy-kata deploy-kata-remote deploy-kata-cc

# Aggregator dashboard: RBAC (SA/Role/RoleBinding), the dashboard Deployment,
# and the Service + Route that front it.
deploy-dashboard:
	oc apply -f k8s/namespace.yaml
	oc apply -f k8s/rbac.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-dashboard.yaml | oc apply -f -
	oc apply -f k8s/service.yaml -f k8s/route.yaml

deploy-standard:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-standard.yaml | oc apply -f -

deploy-kata:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-kata.yaml | oc apply -f -

deploy-kata-remote:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-kata-remote.yaml | oc apply -f -

deploy-kata-cc:
	oc apply -f k8s/namespace.yaml
	sed 's|IMAGE_PLACEHOLDER|$(FULL)|g' k8s/deployment-kata-cc.yaml | oc apply -f -

clean:
	oc delete namespace $(NS) --ignore-not-found
