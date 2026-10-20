#!/usr/bin/env python3
"""Regenerate the dependency-free iPad Xcode project using deterministic identifiers."""
from hashlib import sha256
from pathlib import Path
import argparse
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "CompositorPad.xcodeproj"
objects = {}


def identifier(label):
    return sha256(label.encode()).hexdigest()[:24].upper()


def add(label, isa, **values):
    key = identifier(label)
    objects[key] = dict(isa=isa, **values)
    return key


def encode(value, depth=0):
    if isinstance(value, dict):
        inner = "\n".join("\t" * (depth + 1) + f"{json.dumps(str(k))} = {encode(v, depth + 1)};" for k, v in value.items())
        return "{\n" + inner + "\n" + "\t" * depth + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(item, depth + 1) for item in value) + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def source_files(directory, label):
    references, builds = [], []
    for path in sorted((ROOT / directory).glob("**/*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        reference = add("file:" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="<group>")
        references.append(reference)
        builds.append(add("build:" + label + ":" + relative, "PBXBuildFile", fileRef=reference))
    return references, builds


app_files, app_builds = source_files("Sources", "app")
unit_files, unit_builds = source_files("iOSTests/Unit", "unit")
ui_files, ui_builds = source_files("iOSTests/UI", "ui")
plist = add("info", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Resources/Info.plist", sourceTree="<group>")
app_product = add("product:app", "PBXFileReference", explicitFileType="wrapper.application", path="CompositorPad.app", sourceTree="BUILT_PRODUCTS_DIR")
unit_product = add("product:unit", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="CompositorPadTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
ui_product = add("product:ui", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="CompositorPadUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
sources_group = add("group:sources", "PBXGroup", children=app_files, name="Sources", sourceTree="<group>")
tests_group = add("group:tests", "PBXGroup", children=unit_files + ui_files, name="iOSTests", sourceTree="<group>")
products_group = add("group:products", "PBXGroup", children=[app_product, unit_product, ui_product], name="Products", sourceTree="<group>")
root_group = add("group:root", "PBXGroup", children=[sources_group, tests_group, plist, products_group], sourceTree="<group>")


def configurations(label, settings):
    configs = []
    for name in ["Debug", "Release"]:
        values = dict(settings)
        if label == "project":
            values.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if name == "Debug" else "-O",
                          DEBUG_INFORMATION_FORMAT="dwarf" if name == "Debug" else "dwarf-with-dsym",
                          ENABLE_TESTABILITY="YES" if name == "Debug" else "NO",
                          SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG" if name == "Debug" else "")
        configs.append(add(f"config:{label}:{name}", "XCBuildConfiguration", buildSettings=values, name=name))
    return add("configs:" + label, "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


common = dict(SWIFT_VERSION="5.0", IPHONEOS_DEPLOYMENT_TARGET="17.0", SDKROOT="iphoneos",
              TARGETED_DEVICE_FAMILY="2", SUPPORTED_PLATFORMS="iphoneos iphonesimulator",
              SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO",
              CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", CODE_SIGN_STYLE="Automatic",
              CODE_SIGNING_ALLOWED="YES",
              CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="0.1.0")
common["CODE_SIGN_IDENTITY[sdk=iphonesimulator*]"] = "-"
project_configs = configurations("project", common)
project_id, app_id = identifier("project"), identifier("target:app")


def target(label, name, builds, product, bundle_id, kind, extra):
    source_phase = add("phase:" + label + ":sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
    frameworks_phase = add("phase:" + label + ":frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    resources_phase = add("phase:" + label + ":resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    dependencies = []
    if label != "app":
        proxy = add("proxy:" + label, "PBXContainerItemProxy", containerPortal=project_id, proxyType=1, remoteGlobalIDString=app_id, remoteInfo="CompositorPad")
        dependencies.append(add("dependency:" + label, "PBXTargetDependency", target=app_id, targetProxy=proxy))
    configs = configurations(label, dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER=bundle_id,
        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"], **extra))
    return add("target:" + label, "PBXNativeTarget", buildConfigurationList=configs,
        buildPhases=[source_phase, frameworks_phase, resources_phase], buildRules=[], dependencies=dependencies,
        name=name, productName=name, productReference=product, productType=kind)


app = target("app", "CompositorPad", app_builds, app_product, "com.compositor.ipad.dev", "com.apple.product-type.application",
             dict(INFOPLIST_FILE="Resources/Info.plist", GENERATE_INFOPLIST_FILE="NO"))
unit = target("unit", "CompositorPadTests", unit_builds, unit_product, "com.compositor.ipad.dev.tests", "com.apple.product-type.bundle.unit-test",
              dict(GENERATE_INFOPLIST_FILE="YES", TEST_HOST="$(BUILT_PRODUCTS_DIR)/CompositorPad.app/CompositorPad", BUNDLE_LOADER="$(TEST_HOST)"))
ui = target("ui", "CompositorPadUITests", ui_builds, ui_product, "com.compositor.ipad.dev.uitests", "com.apple.product-type.bundle.ui-testing",
            dict(GENERATE_INFOPLIST_FILE="YES", TEST_TARGET_NAME="CompositorPad"))
add("project", "PBXProject", attributes=dict(BuildIndependentTargetsInParallel="YES", LastUpgradeCheck="2600",
    TargetAttributes={app: dict(CreatedOnToolsVersion="26.0"), unit: dict(CreatedOnToolsVersion="26.0", TestTargetID=app), ui: dict(CreatedOnToolsVersion="26.0", TestTargetID=app)}),
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0,
    knownRegions=["en", "Base", "zh-Hans"], mainGroup=root_group, productRefGroup=products_group,
    projectDirPath="", projectRoot="", targets=[app, unit, ui])
PROJECT.mkdir(parents=True, exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project_id)) + "\n")


def reference(target_id, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:CompositorPad.xcodeproj"/>'


app_ref = reference(app, "CompositorPad", "CompositorPad.app")
unit_ref = reference(unit, "CompositorPadTests", "CompositorPadTests.xctest")
ui_ref = reference(ui, "CompositorPadUITests", "CompositorPadUITests.xctest")
schemes = PROJECT / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "CompositorPad.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
  <Testables><TestableReference skipped="NO" parallelizable="NO">{unit_ref}</TestableReference><TestableReference skipped="NO" parallelizable="NO">{ui_ref}</TestableReference></Testables>
 </TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated CompositorPad.xcodeproj: {len(app_files)} app files, {len(unit_files)} unit test files, {len(ui_files)} UI test files")

# Xcode may compile an installed Simulator SDK while its scheme destination resolver
# refuses an older installed runtime. Its documented test-without-building interface
# can still execute the built tests on that runtime. Keep these paths relative to the
# supplied build products folder and Xcode's own platform directory.
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--test-products", type=Path, help="Also write a test-without-building xctestrun into this build products folder")
arguments = parser.parse_args()
if arguments.test_products:
    base = "__TESTROOT__/Debug-iphonesimulator/"
    app_path = base + "CompositorPad.app"
    environment = {
        "DYLD_LIBRARY_PATH": "__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib",
        "DYLD_FRAMEWORK_PATH": "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks:__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/PrivateFrameworks",
    }
    unit = dict(BlueprintName="CompositorPadTests", ProductModuleName="CompositorPadTests",
        TestBundlePath="__TESTHOST__/PlugIns/CompositorPadTests.xctest", TestHostPath=app_path,
        TestHostBundleIdentifier="com.compositor.ipad.dev", IsAppHostedTestBundle=True, IsUITestBundle=False,
        ParallelizationEnabled=False, TestingEnvironmentVariables=dict(environment,
            DYLD_INSERT_LIBRARIES="__TESTHOST__/Frameworks/libXCTestBundleInject.dylib",
            XCInjectBundleInto="__TESTHOST__/CompositorPad"))
    ui = dict(BlueprintName="CompositorPadUITests", ProductModuleName="CompositorPadUITests",
        TestBundlePath="__TESTHOST__/PlugIns/CompositorPadUITests.xctest", TestHostPath=base + "CompositorPadUITests-Runner.app",
        TestHostBundleIdentifier="com.compositor.ipad.dev.uitests.xctrunner", UITargetAppPath=app_path,
        UITargetAppBundleIdentifier="com.compositor.ipad.dev", IsUITestBundle=True, ParallelizationEnabled=False,
        DependentProductPaths=[app_path], TestingEnvironmentVariables=environment)
    run = {"TestConfigurations": [dict(Name="Debug", IsEnabled=True, TestTargets=[unit, ui])],
           "__xctestrun_metadata__": {"FormatVersion": 2}}
    arguments.test_products.mkdir(parents=True, exist_ok=True)
    destination = arguments.test_products / "CompositorPad.xctestrun"
    destination.write_bytes(plistlib.dumps(run))
    print(f"Wrote {destination}")
