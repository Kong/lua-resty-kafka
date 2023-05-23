OPENRESTY_PREFIX=/usr/local/openresty
SHELL := /bin/bash
PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

TOKENID := $(shell sed -n 1p dev/tokens/delegation-tokens.env)
TOKENHMAC := $(shell sed -n 2p dev/tokens/delegation-tokens.env)

.PHONY: all install


all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka
	$(INSTALL) lib/resty/kafka/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka

luarocks:
	luarocks make

setup-certs:
	cd dev/; bash kafka-generate-ssl-automatic.sh; cd -

devup: setup-certs
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml up -d
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test --replica-assignment 1
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test1 --replica-assignment 1
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic brokerdown --replica-assignment 2

test:
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T openresty luarocks make
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T -e TOKENID=$(TOKENID) -e TOKENHMAC=$(TOKENHMAC) openresty busted

devdown:
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml down --remove-orphans

devshell: delegation-token
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -e TOKENID=$(TOKENID) -e TOKENHMAC=$(TOKENHMAC) openresty /bin/bash

devlogs:
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml logs

delegation-token:
	docker-compose -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml run create-delegation-token
