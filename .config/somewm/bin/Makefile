# wlr-brightnessd - build and install
# Requires: wayland-protocols, pkg-config, wayland-scanner

PREFIX  ?= $(HOME)/bin
TARGET  := wlr-brightnessd
SRC     := wlr-brightnessd.c
PROTO   := wlr-gamma-control-unstable-v1.xml
GEN_C   := wlr-gamma-control-protocol.c
GEN_H   := wlr-gamma-control-client-protocol.h
CFLAGS  := -std=c11 -Wall -Wextra -O2
LDLIBS  := $(shell pkg-config --cflags --libs wayland-client) -lm

$(TARGET): $(SRC) $(GEN_C) $(GEN_H)
	cc $(CFLAGS) -o $@ $(SRC) $(GEN_C) $(LDLIBS)

$(GEN_H): $(PROTO)
	wayland-scanner client-header $< $@

$(GEN_C): $(PROTO)
	wayland-scanner private-code $< $@

install: $(TARGET)
	install -Dm755 $(TARGET) $(PREFIX)/$(TARGET)

clean:
	rm -f $(TARGET) $(GEN_C) $(GEN_H)

.PHONY: install clean
