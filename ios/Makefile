Core.xcframework: core/go.mod core/go.sum core/core.go
	cd core && gomobile bind -target ios,iossimulator -o ../Core.xcframework .

tlx.xcodeproj: project.yml $(shell find Sources -name '*.swift')
	xcodegen generate

Assets.xcassets/AppIcon.appiconset/icon.png: icon.py
	python3 icon.py

core: Core.xcframework

project: tlx.xcodeproj

icon: Assets.xcassets/AppIcon.appiconset/icon.png

release: tlx.xcodeproj
	xcodebuild -project tlx.xcodeproj -scheme tlx -destination generic/platform=iOS -archivePath build/tlx.xcarchive -allowProvisioningUpdates archive
	PATH=/usr/bin:$$PATH xcodebuild -exportArchive -archivePath build/tlx.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build -allowProvisioningUpdates

.PHONY: core project icon release
