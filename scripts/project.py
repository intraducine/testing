#!/usr/bin/env python3
"""Generate only the simulator app, unchanged widget, and native UI-test targets."""
# SPDX-License-Identifier: AGPL-3.0-only
import hashlib
import json
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET

REFERENCE = 'f9187c8eeeda4f2b986744f4a003ec6d5643708d'
SOURCES = {
    'iridium/apps/ios/SteamActivityShared/SteamDownloadActivityAttributes.swift': '498c518bbbfcbbafc77b4e8ea811ebd27bc39be7a84f38744d5d1f096dd5285d',
    'iridium/apps/ios/SteamDownloadWidget/SteamDownloadPresentation.swift': '8d658fbe1e9e89f2028094071b3aca12f716bdd3b6694c52bcc1ae85e99558cc',
    'iridium/apps/ios/SteamDownloadWidget/SteamDownloadWidget.swift': '74de10e92f1a416dd4af28eb32e9b9d1ea1f1a157a82336d2bd181f0f172021c',
    'iridium/apps/ios/Iridium/SteamDownloadActivity.swift': '2eeb77bf38c571dcf320664a6eb6271b8a38d31c15235f23c64aee4d4d509068',
}
BUNDLE = 'org.iridium.synthetic.activity-demo'


def verify_sources(upstream):
    for name, expected in SOURCES.items():
        if hashlib.sha256((upstream / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f'Pinned production source mismatch: {name}')


def openstep(value):
    if isinstance(value, dict):
        return '{\n' + ''.join(f'{json.dumps(k)} = {openstep(v)};\n' for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '(' + ','.join(openstep(item) for item in value) + ')'
    return json.dumps(str(value))


def generate(root, upstream, destination):
    verify_sources(upstream)
    destination.mkdir(parents=True, exist_ok=False)
    project = destination / 'ActivityDemo.xcodeproj'
    project.mkdir()
    objects = {}

    def add(label, **fields):
        identifier = hashlib.sha256(label.encode()).hexdigest()[:24].upper()
        if identifier in objects:
            raise ValueError('Duplicate project object')
        objects[identifier] = fields
        return identifier

    products = {}
    targets = {}
    for name, extension, product_type in [('ActivityDemo', 'app', 'application'),
                                          ('SteamDownloadWidget', 'appex', 'app-extension'),
                                          ('ActivityCaptureTests', 'xctest', 'bundle.ui-testing')]:
        products[name] = add('product/' + name, isa='PBXFileReference', explicitFileType={
            'app': 'wrapper.application', 'appex': 'wrapper.app-extension', 'xctest': 'wrapper.cfbundle'}[extension],
            path=f'{name}.{extension}', sourceTree='BUILT_PRODUCTS_DIR')
        targets[name] = hashlib.sha256(('target/' + name).encode()).hexdigest()[:24].upper()
    files = {}
    sources = [root / 'demo/FixtureDemo.swift', root / 'demo/CaptureTests.swift', *(upstream / name for name in SOURCES)]
    for path in sources:
        files[path.name] = add('file/' + path.name, isa='PBXFileReference', lastKnownFileType='sourcecode.swift',
                              path=str(path), sourceTree='<absolute>')
    product_group = add('group/products', isa='PBXGroup', children=list(products.values()), name='Products', sourceTree='<group>')
    main_group = add('group/main', isa='PBXGroup', children=[*files.values(), product_group], sourceTree='<group>')

    def configs(label, settings):
        identifiers = [add(f'config/{label}/{name}', isa='XCBuildConfiguration', name=name, buildSettings=settings)
                       for name in ['Debug', 'Release']]
        return add('configs/' + label, isa='XCConfigurationList', buildConfigurations=identifiers,
                   defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')

    project_config = configs('project', {'SDKROOT': 'iphonesimulator', 'SUPPORTED_PLATFORMS': 'iphonesimulator',
        'IPHONEOS_DEPLOYMENT_TARGET': '18.0', 'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES',
        'CODE_SIGN_IDENTITY': '-', 'CODE_SIGN_STYLE': 'Automatic', 'DEVELOPMENT_TEAM': '',
        'PROVISIONING_PROFILE_SPECIFIER': '', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES'})
    shared = [Path(name).name for name in list(SOURCES)[:3]]
    for name, extension, product_type in [('ActivityDemo', 'app', 'application'),
                                          ('SteamDownloadWidget', 'appex', 'app-extension'),
                                          ('ActivityCaptureTests', 'xctest', 'bundle.ui-testing')]:
        source_names = {'ActivityDemo': ['FixtureDemo.swift', *shared, 'SteamDownloadActivity.swift'],
                        'SteamDownloadWidget': shared, 'ActivityCaptureTests': ['CaptureTests.swift']}[name]
        build_files = [add(f'build/{name}/{file}', isa='PBXBuildFile', fileRef=files[file]) for file in source_names]
        phases = [add('sources/' + name, isa='PBXSourcesBuildPhase', buildActionMask='2147483647',
                      files=build_files, runOnlyForDeploymentPostprocessing='0'),
                  add('frameworks/' + name, isa='PBXFrameworksBuildPhase', buildActionMask='2147483647',
                      files=[], runOnlyForDeploymentPostprocessing='0')]
        deps = []
        child = 'SteamDownloadWidget' if name == 'ActivityDemo' else 'ActivityDemo' if name == 'ActivityCaptureTests' else None
        if child:
            proxy = add('proxy/' + name, isa='PBXContainerItemProxy', containerPortal=hashlib.sha256(b'project').hexdigest()[:24].upper(),
                        proxyType='1', remoteGlobalIDString=targets[child], remoteInfo=child)
            deps.append(add('dependency/' + name, isa='PBXTargetDependency', target=targets[child], targetProxy=proxy))
        if name == 'ActivityDemo':
            embed = add('embed/widget', isa='PBXBuildFile', fileRef=products['SteamDownloadWidget'],
                        settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']})
            phases.append(add('embed/extensions', isa='PBXCopyFilesBuildPhase', buildActionMask='2147483647',
                              dstPath='', dstSubfolderSpec='13', files=[embed], name='Embed App Extensions',
                              runOnlyForDeploymentPostprocessing='0'))
        identifier = BUNDLE if name == 'ActivityDemo' else BUNDLE + '.' + name
        info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': name, 'CFBundleName': name,
                'CFBundlePackageType': 'APPL' if extension == 'app' else 'XPC!' if extension == 'appex' else 'BNDL',
                'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'MinimumOSVersion': '18.0'}
        if name == 'ActivityDemo':
            info.update(NSSupportsLiveActivities=True, LSRequiresIPhoneOS=True, UIDeviceFamily=[1],
                        UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False},
                        UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'])
        if name == 'SteamDownloadWidget':
            info['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
        plist_path = destination / (name + '-Info.plist')
        plist_path.write_bytes(plistlib.dumps(info))
        settings = {'PRODUCT_BUNDLE_IDENTIFIER': identifier, 'PRODUCT_NAME': name, 'INFOPLIST_FILE': str(plist_path),
                    'TARGETED_DEVICE_FAMILY': '1', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'}
        if name == 'ActivityDemo':
            settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) IRIDIUM_APP IRIDIUM_ACTIVITY_RENDERING'
        if name == 'SteamDownloadWidget':
            settings.update(APPLICATION_EXTENSION_API_ONLY='YES', SKIP_INSTALL='YES')
        if name == 'ActivityCaptureTests':
            settings['TEST_TARGET_NAME'] = 'ActivityDemo'
        add('target/' + name, isa='PBXNativeTarget', buildConfigurationList=configs(name, settings), buildPhases=phases,
            buildRules=[], dependencies=deps, name=name, productName=name, productReference=products[name],
            productType='com.apple.product-type.' + product_type)
    project_id = add('project', isa='PBXProject', buildConfigurationList=project_config,
        compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en', 'Base'],
        mainGroup=main_group, productRefGroup=product_group, projectDirPath='', projectRoot='',
        targets=list(targets.values()), attributes={'LastUpgradeCheck': '1600',
            'TargetAttributes': {targets['ActivityCaptureTests']: {'TestTargetID': targets['ActivityDemo']}}})
    (project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + openstep({
        'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project_id}) + '\n')
    scheme = ET.Element('Scheme', LastUpgradeVersion='1600', version='1.3')
    build = ET.SubElement(ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES'), 'BuildActionEntries')
    def reference(parent, name):
        return ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=targets[name],
                             BuildableName=name + ('.xctest' if name == 'ActivityCaptureTests' else '.app'),
                             BlueprintName=name, ReferencedContainer='container:ActivityDemo.xcodeproj')
    for name in ['ActivityDemo', 'ActivityCaptureTests']:
        reference(ET.SubElement(build, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES' if name == 'ActivityDemo' else 'NO',
                                buildForProfiling='NO', buildForArchiving='NO', buildForAnalyzing='YES'), name)
    test = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                         selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
    reference(ET.SubElement(ET.SubElement(test, 'Testables'), 'TestableReference', skipped='NO'), 'ActivityCaptureTests')
    launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                           selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO',
                           ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', allowLocationSimulation='NO')
    reference(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'), 'ActivityDemo')
    folder = project / 'xcshareddata/xcschemes'; folder.mkdir(parents=True)
    ET.ElementTree(scheme).write(folder / 'ActivityDemo.xcscheme', encoding='utf-8', xml_declaration=True)
    return project
