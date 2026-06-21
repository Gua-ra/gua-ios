#!/bin/bash

# This script is invoked by xcodegen for running post commands

# Move file header template in project shared data folder
mkdir -p ../../Gua.xcodeproj/xcshareddata/
cp IDETemplateMacros.plist ../../Gua.xcodeproj/xcshareddata/
