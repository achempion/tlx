Core.xcframework: core/go.mod core/go.sum core/core.go
	cd core && gomobile bind -target ios,iossimulator -o ../Core.xcframework .

tlx.xcodeproj: project.yml $(shell find Sources -name '*.swift')
	xcodegen generate

Assets.xcassets/AppIcon.appiconset/icon.png: icon.py
	python3 icon.py

core: Core.xcframework

project: tlx.xcodeproj

icon: Assets.xcassets/AppIcon.appiconset/icon.png

.PHONY: core project icon
