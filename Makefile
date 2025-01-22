OPENRESTY_PREFIX=/usr/local/openresty
SHELL := /bin/bash
PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

TOKENID := $(shell awk '{print $$1}' dev/tokens/delegation-tokens.env)
TOKENHMAC := $(shell awk '{print $$2}' dev/tokens/delegation-tokens.env)

.PHONY: all install

# Check if docker-compose is installed, fall back to `docker compose` if not
COMPOSE_BIN := $(shell command -v docker-compose 2> /dev/null)
ifeq ($(COMPOSE_BIN),)
	COMPOSE_BIN := docker compose
endif


all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka/auth
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka/protocol
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka/consumer
	$(INSTALL) lib/resty/kafka/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka
	$(INSTALL) lib/resty/kafka/protocol/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka/protocol
	$(INSTALL) lib/resty/kafka/auth/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka/auth
	$(INSTALL) lib/resty/kafka/consumer/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/kafka/consumer

luarocks:
	luarocks make

setup-certs:
	cd dev/; bash kafka-generate-ssl-automatic.sh; cd -

devup: setup-certs
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml up -d
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test0 --partitions 20
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test1 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test2 --partitions 20
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test3 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test4 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test5 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test6 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test7 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test8 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test9 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic test10 --partitions 10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --create --topic brokerdown

debug:
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --list
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test0
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test1
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test2
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test3
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test4
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test5
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test6
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test7
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test8
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test9
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-topics --bootstrap-server broker:9092 --describe --topic test10
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T broker kafka-consumer-groups --bootstrap-server broker:9092 --group testing-consume --describe


test:
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T openresty luarocks make
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -T                                           \
								 -e TOKENID=$(TOKENID) -e TOKENHMAC=$(TOKENHMAC) -e CONFLUENT_BOOTSTRAP_SERVER=$(CONFLUENT_BOOTSTRAP_SERVER) \
								 -e CONFLUENT_BOOTSTRAP_PORT=$(CONFLUENT_BOOTSTRAP_PORT) -e CONFLUENT_API_KEY=$(CONFLUENT_API_KEY)           \
								 -e CONFLUENT_API_SECRET=$(CONFLUENT_API_SECRET) -e CONFLUENT_TOPIC=$(CONFLUENT_TOPIC) openresty busted

devdown:
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml down --remove-orphans

devshell:
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml exec -e TOKENID=$(TOKENID) -e TOKENHMAC=$(TOKENHMAC) openresty /bin/bash

devlogs:
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml logs

delegation-token:
	$(COMPOSE_BIN) -f dev/docker-compose.yaml -f dev/docker-compose.dev.yaml run create-delegation-token


lint:
	luacheck --no-default-config --config .luacheckrc kong spec
