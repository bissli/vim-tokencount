.PHONY: build install clean

build:
	./install.sh

install: build

clean:
	cargo clean
