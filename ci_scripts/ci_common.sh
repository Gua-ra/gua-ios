#!/bin/sh

setup_xcode_cloud_environment () {
    # Return on failures
    # Fail when expanding unset variables
    # Trace each command before executing it
    set -eEu

    # Move to the project root
    cd ..

    # Prevent installing dependencies in system directories
    echo 'export GEM_HOME=$HOME/.gem' >>~/.zshrc
    echo 'export PATH=$GEM_HOME/bin:$PATH' >>~/.zshrc
    echo 'export PATH="/usr/local/opt/ruby/bin:$PATH"' >> ~/.zshrc
    echo 'export PATH="/Users/local/Library/Python/3.9/bin:$PATH"' >> ~/.zshrc

    export GEM_HOME=$HOME/.gem
    export PATH=$GEM_HOME/bin:$PATH
    export PATH="/usr/local/opt/ruby/bin:$PATH"
    export PATH="/Users/local/Library/Python/3.9/bin:$PATH"

    # Things don't work well on the default ruby version
    brew install ruby

    gem install bundler

    bundle config path vendor/bundle
    bundle install --jobs 4 --retry 3
}

install_xcode_cloud_brew_dependencies () {
    brew update && brew install xcodegen pkl
}

setup_github_actions_environment() {
    xcode_select_for_github_actions
    
    unset HOMEBREW_NO_INSTALL_FROM_API
    export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
    
    brew update && brew install xcodegen swiftlint git-lfs pkl a7ex/homebrew-formulae/xcresultparser

    bundle config path vendor/bundle
    bundle install --jobs 4 --retry 3
}

setup_github_actions_translations_environment() {
    xcode_select_for_github_actions
    
    unset HOMEBREW_NO_INSTALL_FROM_API
    export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1

    brew update && brew install swiftgen mint localazy/tools/localazy

    mint install Asana/locheck
}

xcode_select_for_github_actions() {
    # While fastlane has its own way of selecting Xcode, that only works inside of fastlane.
    # We need to select it globally for other processes like xcresultparser and our custom tools to use the same Xcode version.
    # The project needs the iOS 26 SDK: prefer the pinned release, otherwise the newest Xcode 26 on the image.
    local xcode_app
    xcode_app="$(ls -d /Applications/Xcode_26.5.0.app 2>/dev/null || true)"
    if [ -z "$xcode_app" ]; then
        xcode_app="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n1 || true)"
    fi
    if [ -z "$xcode_app" ]; then
        echo "::error::No Xcode 26.x on this runner. Available: $(ls -d /Applications/Xcode_*.app 2>/dev/null | tr '\n' ' ')" >&2
        return 1
    fi
    sudo xcode-select -s "$xcode_app"
    xcodebuild -version
}

install_ios18_simulator_runtime() {
    # macos-26 images ship only iOS 26 simulator runtimes; the snapshot-based test targets are pinned to iOS 18.6.
    if ! xcrun simctl list runtimes | grep -q "iOS 18.6"; then
        xcodebuild -downloadPlatform iOS -buildVersion 18.6
    fi
    if ! xcrun simctl list runtimes | grep -q "iOS 18.6"; then
        echo "::error::The iOS 18.6 simulator runtime is not available." >&2
        xcrun simctl list runtimes >&2
        return 1
    fi
}

# Usage: ensure_ios18_simulator "<device name>" <device type identifier>
ensure_ios18_simulator() {
    local runtime_id
    runtime_id="$(xcrun simctl list -j runtimes | jq -r '.runtimes[] | select(.identifier | startswith("com.apple.CoreSimulator.SimRuntime.iOS-18-6")) | .identifier' | head -n 1)"
    if ! xcrun simctl list -j devices | jq -e --arg rt "$runtime_id" --arg name "$1" '.devices[$rt] // [] | map(select(.name == $name)) | length > 0' > /dev/null; then
        xcrun simctl create "$1" "$2" "$runtime_id"
    fi
}

generate_what_to_test_notes() {
    if [[ -d "$CI_APP_STORE_SIGNED_APP_PATH" ]]; then
        TESTFLIGHT_DIR_PATH=TestFlight
        TESTFLIGHT_NOTES_FILE_NAME=WhatToTest.en-US.txt
        
        LATEST_TAG=""
        if [ "$CI_WORKFLOW" = "Release" ]; then
            # Use -v to invert grep, searching for non-nightlies
            LATEST_TAG=$(git tag --sort=-creatordate | grep -v 'nightly' | head -n1)
        elif [ "$CI_WORKFLOW" = "Nightly" ]; then
            LATEST_TAG=$(git tag --sort=-creatordate | grep 'nightly' | head -n1)
        fi

        if [[ -z "$LATEST_TAG" ]]; then
            echo "generate_what_to_test_notes: Failed fetching previous tag"
            return 0 # Continue even though this failed
        fi

        echo "generate_what_to_test_notes: latest tag is $LATEST_TAG"

        mkdir $TESTFLIGHT_DIR_PATH

        NOTES="$(git log --pretty='- %an: %s' "$LATEST_TAG"..HEAD)"

        echo "generate_what_to_test_notes: Generated notes:\n"$NOTES""

        echo "$NOTES" > $TESTFLIGHT_DIR_PATH/$TESTFLIGHT_NOTES_FILE_NAME
    fi
}

fetch_unshallow_repository() {
    # Xcode Cloud shallow clones the repo. We need to deepen it to fetch tags, commit history and be able to rebase main on develop at the end of releases.
    git fetch --unshallow --quiet
}
