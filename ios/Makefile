Core.xcframework: core/go.mod core/go.sum core/core.go Makefile
	cd core && gomobile bind -target ios,iossimulator,maccatalyst -iosversion 17.0 -o ../Core.xcframework .

export TLX_BUNDLE_ID TLX_TEAM_ID

project:
	@test -n "$$TLX_BUNDLE_ID" || { echo "Set TLX_BUNDLE_ID to your app's bundle identifier" >&2; exit 1; }
	@test -n "$$TLX_TEAM_ID" || { echo "Set TLX_TEAM_ID to your Apple Developer team ID" >&2; exit 1; }
	xcodegen generate

Assets.xcassets/AppIcon.appiconset/icon.png: icon.py
	python3 icon.py

core: Core.xcframework

icon: Assets.xcassets/AppIcon.appiconset/icon.png

release: project
	xcodebuild -project tlx.xcodeproj -scheme tlx -destination generic/platform=iOS -archivePath build/tlx.xcarchive -allowProvisioningUpdates archive
	PATH=/usr/bin:$$PATH xcodebuild -exportArchive -archivePath build/tlx.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build -allowProvisioningUpdates

mac-export: project
	xcodebuild -project tlx.xcodeproj -scheme tlx -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath build/mac/tlx.xcarchive -derivedDataPath build/mac/DerivedData -allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath build/mac/tlx.xcarchive -exportOptionsPlist MacExportOptions.plist -exportPath build/mac/export -allowProvisioningUpdates
	test -f build/mac/export/tlx.app/Contents/embedded.provisionprofile
	codesign --verify --deep --strict build/mac/export/tlx.app

.PHONY: core project icon release mac-export
