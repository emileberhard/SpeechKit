default:
    @just --list

build:
    swift build --jobs 4

test:
    swift test --jobs 4

build-ios:
    xcodebuild -quiet -scheme DictationLibrary -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .local/DerivedData CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
