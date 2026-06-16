IMAGE         := registry.ops.scalecf.net/genesis-community/genesis
TAG           ?= $(shell genesis version | cut -f 2 -d ' ')
GENESIS_OWNER ?= genesis-community

rebuild:
	docker build -t $(IMAGE):dev --build-arg GENESIS_VERSION=$(TAG) --build-arg GENESIS_OWNER=$(GENESIS_OWNER) --no-cache .
	docker run $(IMAGE):dev genesis -v
build:
	docker build -t $(IMAGE):dev --build-arg GENESIS_VERSION=$(TAG) --build-arg GENESIS_OWNER=$(GENESIS_OWNER) .
	docker run $(IMAGE):dev genesis -v
prerelease: build
	docker tag $(IMAGE):dev $(IMAGE):$(TAG)
release: build
	docker tag $(IMAGE):dev $(IMAGE):latest
	docker tag $(IMAGE):dev $(IMAGE):$(TAG)
push: release
	docker push $(IMAGE):latest
	docker push $(IMAGE):$(TAG)
prepush: prerelease 
	docker push $(IMAGE):dev
	docker push $(IMAGE):$(TAG)
