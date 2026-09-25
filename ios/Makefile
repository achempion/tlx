Core.xcframework: core/go.mod core/go.sum core/core.go
	cd core && gomobile bind -target ios,iossimulator -o ../Core.xcframework .

tlx.xcodeproj: project.yml $(wildcard Sources/*.swift)
	xcodegen generate

core: Core.xcframework

project: tlx.xcodeproj

.PHONY: core project
