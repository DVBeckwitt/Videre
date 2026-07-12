export PATH := $(shell pwd)/submodules/flutter/bin:$(PATH)

build-runner:
	dart run build_runner build --delete-conflicting-outputs

build-runner-watch:
	dart run build_runner watch --delete-conflicting-outputs

splashscreen:
	dart run flutter_native_splash:create --path flutter_native_splash.yaml
