#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library.

No XcodeGen/Ruby dependency. Stable IDs and sorted inputs make regeneration
deterministic. SwiftPM and Xcode compile the exact same source/test files;
SWIFT_PACKAGE selects only the module import spelling.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent


def uid(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def generate():
    sources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'PathDeck').rglob('*.swift'))
    tests = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'PathDeckTests').rglob('*.swift'))
    resources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'PathDeck/Resources').glob('*.icns'))
    objects = []

    def obj(key, body):
        objects.append(f'\t\t{uid(key)} = {{ {body} }};')

    def refs(keys):
        identifiers = ', '.join(uid(key) for key in keys)
        return '(' + identifiers + (',)' if identifiers else ')')

    for path in sources + tests:
        obj('ref:' + path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;')
        obj('build:' + path, f'isa = PBXBuildFile; fileRef = {uid("ref:" + path)};')

    for path in resources:
        obj('ref:' + path, f'isa = PBXFileReference; lastKnownFileType = image.icns; path = {quote(path)}; sourceTree = SOURCE_ROOT;')
        obj('build:' + path, f'isa = PBXBuildFile; fileRef = {uid("ref:" + path)};')

    metadata = ['SPEC.md', 'README.md', 'Package.swift', 'PathDeck/Resources/Info.plist', 'assets/branding/PathDeck-master.png']
    for path in metadata:
        filetype = 'text.plist.xml' if path.endswith('.plist') else 'image.png' if path.endswith('.png') else 'text'
        obj('ref:' + path, f'isa = PBXFileReference; lastKnownFileType = {filetype}; path = {quote(path)}; sourceTree = SOURCE_ROOT;')

    for name, filetype in [('PathDeck.app', 'wrapper.application'), ('PathDeckTests.xctest', 'wrapper.cfbundle')]:
        obj('product:' + name, f'isa = PBXFileReference; explicitFileType = {filetype}; includeInIndex = 0; path = {quote(name)}; sourceTree = BUILT_PRODUCTS_DIR;')

    obj('sourcesGroup', f'isa = PBXGroup; name = Sources; children = {refs("ref:" + p for p in sources)}; sourceTree = "<group>";')
    obj('testsGroup', f'isa = PBXGroup; name = Tests; children = {refs("ref:" + p for p in tests)}; sourceTree = "<group>";')
    obj('metadataGroup', f'isa = PBXGroup; name = Project; children = {refs("ref:" + p for p in metadata)}; sourceTree = "<group>";')
    obj('resourcesGroup', f'isa = PBXGroup; name = Resources; children = {refs("ref:" + p for p in resources)}; sourceTree = "<group>";')
    obj('productsGroup', f'isa = PBXGroup; name = Products; children = {refs(["product:PathDeck.app", "product:PathDeckTests.xctest"])}; sourceTree = "<group>";')
    obj('mainGroup', f'isa = PBXGroup; children = {refs(["sourcesGroup", "testsGroup", "resourcesGroup", "metadataGroup", "productsGroup"])}; sourceTree = "<group>";')

    for target, files in [('app', sources), ('tests', tests)]:
        obj(target + ':sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs("build:" + p for p in files)}; runOnlyForDeploymentPostprocessing = 0;')
        for phase, kind in [('frameworks', 'PBXFrameworksBuildPhase'), ('resources', 'PBXResourcesBuildPhase')]:
            phase_files = refs("build:" + p for p in resources) if target == 'app' and phase == 'resources' and resources else '()'
            obj(target + ':' + phase, f'isa = {kind}; buildActionMask = 2147483647; files = {phase_files}; runOnlyForDeploymentPostprocessing = 0;')

    common = {
        'CLANG_ENABLE_MODULES': 'YES', 'MACOSX_DEPLOYMENT_TARGET': '14.0',
        'SDKROOT': 'macosx', 'SWIFT_VERSION': '6.0', 'SWIFT_STRICT_CONCURRENCY': 'complete',
        'CODE_SIGN_IDENTITY': '-', 'CODE_SIGN_STYLE': 'Manual',
    }
    app_settings = {
        'PRODUCT_NAME': 'PathDeck', 'PRODUCT_BUNDLE_IDENTIFIER': 'local.pathdeck.app',
        'INFOPLIST_FILE': 'PathDeck/Resources/Info.plist',
        'GENERATE_INFOPLIST_FILE': 'NO', 'ENABLE_APP_SANDBOX': 'NO',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks',
    }
    test_settings = {
        'PRODUCT_NAME': 'PathDeckTests', 'PRODUCT_BUNDLE_IDENTIFIER': 'local.pathdeck.tests',
        'GENERATE_INFOPLIST_FILE': 'YES',
        'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/PathDeck.app/Contents/MacOS/PathDeck',
        'BUNDLE_LOADER': '$(TEST_HOST)',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks',
    }
    for owner, settings in [('project', common), ('app', app_settings), ('tests', test_settings)]:
        for config in ['Debug', 'Release']:
            values = dict(settings)
            if owner == 'project':
                values.update({
                    'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
                    'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO',
                    'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym',
                })
                if config == 'Debug':
                    values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
            body = ' '.join(f'{key} = {quote(value)};' for key, value in sorted(values.items()))
            obj(owner + ':' + config, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};')
        obj(owner + ':configs', f'isa = XCConfigurationList; buildConfigurations = {refs([owner + ":Debug", owner + ":Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

    obj('testProxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("app")}; remoteInfo = PathDeck;')
    obj('testDependency', f'isa = PBXTargetDependency; target = {uid("app")}; targetProxy = {uid("testProxy")};')
    for target, name, producttype, product in [
        ('app', 'PathDeck', 'com.apple.product-type.application', 'PathDeck.app'),
        ('tests', 'PathDeckTests', 'com.apple.product-type.bundle.unit-test', 'PathDeckTests.xctest'),
    ]:
        dependencies = refs(['testDependency']) if target == 'tests' else '()'
        obj(target, f'isa = PBXNativeTarget; buildConfigurationList = {uid(target + ":configs")}; buildPhases = {refs(target + ":" + p for p in ["sources", "frameworks", "resources"])}; buildRules = (); dependencies = {dependencies}; name = {name}; productName = {name}; productReference = {uid("product:" + product)}; productType = {quote(producttype)};')
    attrs = f'LastUpgradeCheck = 1600; TargetAttributes = {{ {uid("app")} = {{ CreatedOnToolsVersion = 16.0; }}; {uid("tests")} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {uid("app")}; }}; }};'
    obj('project', f'isa = PBXProject; attributes = {{ {attrs} }}; buildConfigurationList = {uid("project:configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN, en, Base,); mainGroup = {uid("mainGroup")}; productRefGroup = {uid("productsGroup")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["app", "tests"])};')
    pbx = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {uid("project")};\n}}\n'

    app_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("app")}" BuildableName="PathDeck.app" BlueprintName="PathDeck" ReferencedContainer="container:PathDeck.xcodeproj"/>'
    tests_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("tests")}" BuildableName="PathDeckTests.xctest" BlueprintName="PathDeckTests" ReferencedContainer="container:PathDeck.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{tests_ref}</BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{tests_ref}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return {
        'PathDeck.xcodeproj/project.pbxproj': pbx,
        'PathDeck.xcodeproj/xcshareddata/xcschemes/PathDeck.xcscheme': scheme,
        'PathDeck.xcodeproj/project.xcworkspace/contents.xcworkspacedata': '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"/></Workspace>\n',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if the committed project differs')
    args = parser.parse_args()
    mismatches = []
    for relative, content in generate().items():
        path = ROOT / relative
        if args.check:
            if not path.exists() or path.read_text() != content:
                mismatches.append(relative)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            print('Generated:', relative)
    if mismatches:
        print('Regenerate Xcode project; mismatched files:', *mismatches, sep='\n', file=sys.stderr)
        return 1
    if args.check:
        print('Xcode project matches current source files and generator.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
