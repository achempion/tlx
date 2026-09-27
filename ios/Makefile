Core.xcframework: core/go.mod core/go.sum core/core.go Makefile
	cd core && gomobile bind -target ios,iossimulator,maccatalyst -iosversion 17.0 -o ../Core.xcframework .

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

mac-export: tlx.xcodeproj
	xcodebuild -project tlx.xcodeproj -scheme tlx -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath build/mac/tlx.xcarchive -derivedDataPath build/mac/DerivedData -allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath build/mac/tlx.xcarchive -exportOptionsPlist MacExportOptions.plist -exportPath build/mac/export -allowProvisioningUpdates
	test -f build/mac/export/tlx.app/Contents/embedded.provisionprofile
	codesign --verify --deep --strict build/mac/export/tlx.app

.PHONY: core project icon release mac-export
