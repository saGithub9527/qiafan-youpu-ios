#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/qf-meal-surfaces.XXXXXX")
trap 'rm -f "$work_dir/projection" "$work_dir/selection" "$work_dir/history" "$work_dir/main.swift" "$work_dir/privacy.swift" "$work_dir/privacy"; rmdir "$work_dir"' EXIT HUP INT TERM
xcrun swiftc Shared/QFMealSurfaceModel.swift scripts/checks/meal_surface_projection.swift -o "$work_dir/projection"
"$work_dir/projection"
# Top-level Swift entry points must have this filename when compiling multiple source files.
cp scripts/checks/meal_surface_selection.swift "$work_dir/main.swift"
xcrun swiftc Shared/QFMealSurfaceModel.swift "$work_dir/main.swift" -o "$work_dir/selection"
"$work_dir/selection"

xcrun swiftc Shared/QFMealSurfaceModel.swift scripts/checks/meal_surface_history.swift -o "$work_dir/history"
"$work_dir/history"

# Compile the private preview and the check in the same temporary source file; no visibility change.
cat QiafanYoupu/Core/Diagnostics/QFRequestLogStore.swift scripts/checks/meal_surface_privacy.swift > "$work_dir/privacy.swift"
xcrun swiftc -DDEBUG -parse-as-library "$work_dir/privacy.swift" -o "$work_dir/privacy"
"$work_dir/privacy"
