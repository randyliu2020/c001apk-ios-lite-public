"""Build only our source, and exercise it in a synthetic UIKit app on a simulator.

The official Coolapk IPA is never uploaded to this build or executed here.
These checks are not a real-device Coolapk test.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'build'
OUT.mkdir(exist_ok=True)


def run(*args, timeout=180):
    print('Running: ' + ' '.join(str(x) for x in args), flush=True)
    result = subprocess.run([str(x) for x in args], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    print(result.stdout, flush=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited {result.returncode}')
    return result.stdout.strip()


device_sdk = run('xcrun', '--sdk', 'iphoneos', '--show-sdk-path')
sim_sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
clang = run('xcrun', '--find', 'clang')
common = ['-fobjc-arc', '-fblocks', '-O2', '-Wall', '-Wextra', '-Werror',
          '-framework', 'Foundation', '-framework', 'UIKit']
binary = OUT / 'CoolapkDisplay.dylib'
run(clang, '-target', 'arm64-apple-ios17.0', '-isysroot', device_sdk,
    *common, '-dynamiclib', '-Wl,-install_name,@rpath/CoolapkDisplay.dylib',
    '-Wl,-dead_strip', 'CoolapkDisplay.m', '-o', binary)
run('codesign', '--force', '--sign', '-', binary)
run('codesign', '--verify', '--strict', binary)
(OUT / 'device-mach-o.txt').write_text(run('xcrun', 'otool', '-l', binary))
(OUT / 'device-dependencies.txt').write_text(run('xcrun', 'otool', '-L', binary))
(OUT / 'device-symbols.txt').write_text(run('xcrun', 'nm', '-u', binary))

app = OUT / 'DisplayTests.app'
app.mkdir(exist_ok=True)
bundle_id = 'org.randy.coolapk.displaytests'
architecture = run('uname', '-m')
assert architecture in ('arm64', 'x86_64')
run(clang, '-target', f'{architecture}-apple-ios17.0-simulator',
    '-isysroot', sim_sdk, *common, '-framework', 'CoreGraphics', '-DCD_TESTING=1',
    'CoolapkDisplay.m', 'DisplayTests.m', '-o', app / 'DisplayTests')
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'DisplayTests',
    'CFBundleName': 'DisplayTests', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'MinimumOSVersion': '17.0', 'LSRequiresIPhoneOS': True,
    'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    'UIApplicationSceneManifest': {
        'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {
            'UIWindowSceneSessionRoleApplication': [{
                'UISceneClassName': 'UIWindowScene',
                'UISceneConfigurationName': 'Default Configuration',
                'UISceneDelegateClassName': 'DisplayTestSceneDelegate',
            }]
        },
    },
}))
run('codesign', '--force', '--sign', '-', app)
devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))
choices = [(runtime, item) for runtime, items in devices['devices'].items()
           if '.iOS-' in runtime for item in items if item.get('isAvailable')
           and item['name'].startswith('iPhone')]
assert choices, 'No available iPhone simulator'
runtime, device = sorted(choices, key=lambda item: (item[0], 'Pro Max' in item[1]['name']), reverse=True)[0]
udid = device['udid']
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', udid)
run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=240)
run('xcrun', 'simctl', 'install', udid, app)
run('xcrun', 'simctl', 'launch', '--terminate-running-process', udid, bundle_id)
container = Path(run('xcrun', 'simctl', 'get_app_container', udid, bundle_id, 'data'))
receipt = container / 'Documents' / 'display-test-results.json'
deadline = time.monotonic() + 90
while not receipt.exists() and time.monotonic() < deadline:
    time.sleep(0.5)
assert receipt.exists(), 'UIKit test app did not produce a result (possible startup crash)'
result = json.loads(receipt.read_text())
(OUT / 'display-test-results.json').write_text(json.dumps(result, indent=2))
assert result['failed'] == 0 and result['passed'] >= 42, result
manifest = {
    'source_commit': os.environ.get('GITHUB_SHA'),
    'workflow_run': os.environ.get('GITHUB_RUN_ID'),
    'dylib_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'dylib_bytes': binary.stat().st_size,
    'source_sha256': hashlib.sha256((ROOT / 'CoolapkDisplay.m').read_bytes()).hexdigest(),
    'simulator_runtime': runtime, 'simulator_device': device['name'],
    'tests': result,
    'limitation': 'Synthetic UIKit tests only; not Coolapk, real-device performance, or account validation.',
}
(OUT / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
