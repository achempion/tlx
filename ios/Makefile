# The Go core is bound with gomobile into an xcframework the app links.

Core.xcframework: core/go.mod core/go.sum core/core.go
	cd core && gomobile bind -target ios,iossimulator -o ../Core.xcframework .

core: Core.xcframework

.PHONY: core
