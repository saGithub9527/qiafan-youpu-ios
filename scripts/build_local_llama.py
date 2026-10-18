#!/usr/bin/env python3
"""Build the pinned upstream iPhone X+ CPU runtime; no model weights are bundled."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'Packages/QFLocalLLM'
COMMIT = 'd81235049384534c167caea52b85a694f6103d14'
SOURCE_SHA256 = '6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14'
# A11 (iPhone X) and A12 support FP16 arithmetic, but not ARM dot-product.
# Do not target the host Mac's instruction set or require newer iPhones.
ARM_ARCH = 'armv8.2-a+fp16'


def fetch(url, path):
    subprocess.run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error',
                    '--connect-timeout', '15', '--max-time', '600', '--output', str(path), url],
                   check=True, timeout=605)


def main():
    PACKAGE.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='qf-local-llama-') as temporary:
        work = Path(temporary).resolve()
        owner = PACKAGE / 'build-owner.json'
        owner.write_text(json.dumps({'pid': os.getpid(), 'directory': str(work), 'released': False}))
        try:
            # A task-local CMake avoids changing the user's global development tools.
            with urllib.request.urlopen('https://pypi.org/pypi/cmake/3.31.6/json', timeout=30) as response:
                metadata = json.load(response)
            wheel = next(item for item in metadata['urls'] if 'macosx' in item['filename'] and 'universal2' in item['filename'])
            archive = work / wheel['filename']; fetch(wheel['url'], archive)
            assert hashlib.sha256(archive.read_bytes()).hexdigest() == wheel['digests']['sha256']
            with zipfile.ZipFile(archive) as bundle: bundle.extractall(work / 'tools')
            cmake = work / 'tools/cmake/data/bin/cmake'; cmake.chmod(0o755)
            source_archive = work / 'llama.tar.gz'
            fetch('https://codeload.github.com/ggml-org/llama.cpp/tar.gz/' + COMMIT, source_archive)
            source_hash = hashlib.sha256(source_archive.read_bytes()).hexdigest()
            if source_hash != SOURCE_SHA256:
                raise ValueError('Pinned llama.cpp archive checksum mismatch')
            with tarfile.open(source_archive) as bundle:
                for member in bundle.getmembers():
                    target = (work / member.name).resolve()
                    if not target.is_relative_to(work): raise ValueError('Unsafe archive path')
                bundle.extractall(work)
            source = work / ('llama.cpp-' + COMMIT)
            binaries = PACKAGE / 'Binaries'; binaries.mkdir(exist_ok=True)
            headers = work / 'headers'; headers.mkdir()
            for file in [source/'include/llama.h', *sorted((source/'ggml/include').glob('*.h'))]:
                shutil.copy2(file, headers / file.name)
            (headers/'module.modulemap').write_text('module QFNativeLlama { header "llama.h" export * }\n')
            shutil.copy2(source/'LICENSE', PACKAGE/'LICENSE-llama.cpp.txt')
            shutil.copy2(source/'LICENSE', ROOT/'QiafanYoupu/Resources/Legal/llama.cpp-LICENSE.txt')
            libraries = []
            for sdk, variant in [('iphoneos', 'device'), ('iphonesimulator', 'simulator')]:
                build = work / variant
                sysroot = subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'], text=True).strip()
                command = [str(cmake), '-S', str(source), '-B', str(build), '-G', 'Unix Makefiles',
                    '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT='+sysroot,
                    '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
                    '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
                    '-DLLAMA_BUILD_TESTS=OFF','-DLLAMA_BUILD_EXAMPLES=OFF','-DLLAMA_BUILD_TOOLS=OFF',
                    '-DLLAMA_BUILD_SERVER=OFF','-DLLAMA_CURL=OFF','-DGGML_NATIVE=OFF',
                    '-DLLAMA_OPENSSL=OFF','-DLLAMA_BUILD_APP=OFF','-DLLAMA_BUILD_COMMON=OFF',
                    '-DLLAMA_BUILD_MTMD=OFF','-DGGML_CPU_ALL_VARIANTS=OFF',
                    '-DGGML_CPU_ARM_ARCH='+ARM_ARCH,'-DGGML_METAL=OFF','-DGGML_ACCELERATE=ON',
                    '-DGGML_BLAS=ON','-DGGML_BLAS_VENDOR=Apple',
                    # The upstream new ILP64 CBLAS ABI requires iOS 16.4. Use
                    # Apple's still-supported classic CBLAS ABI for iOS 15.
                    '-DCMAKE_C_FLAGS=-UACCELERATE_NEW_LAPACK -UACCELERATE_LAPACK_ILP64',
                    '-DCMAKE_CXX_FLAGS=-UACCELERATE_NEW_LAPACK -UACCELERATE_LAPACK_ILP64',
                    '-DGGML_OPENMP=OFF','-DGGML_BACKEND_DL=OFF']
                subprocess.run(command, check=True, timeout=120)
                subprocess.run([str(cmake),'--build',str(build),'--target','llama','--parallel','2'], check=True, timeout=900)
                archives = sorted(build.rglob('*.a'))
                if not archives: raise ValueError('No runtime archives')
                output = work / ('libQFLlama-'+variant+'.a')
                subprocess.run(['/usr/bin/libtool','-static','-o',str(output), *map(str,archives)], check=True, timeout=90)
                libraries += ['-library',str(output),'-headers',str(headers)]
            # A failed compile must not remove the previously working runtime.
            staged = work/'QFNativeLlama.xcframework'
            subprocess.run(['xcodebuild','-create-xcframework',*libraries,'-output',str(staged)], check=True, timeout=120)
            output = binaries/'QFNativeLlama.xcframework'
            previous = binaries/'QFNativeLlama.previous.xcframework'
            if previous.exists(): raise ValueError('Previous runtime requires explicit recovery before rebuilding')
            if output.exists(): output.rename(previous)
            try:
                shutil.move(str(staged), output)
            except BaseException:
                if previous.exists(): previous.rename(output)
                raise
            if previous.exists(): shutil.rmtree(previous)
            (PACKAGE/'upstream-lock.json').write_text(json.dumps({
                'repository':'https://github.com/ggml-org/llama.cpp','tag':'v0.6.0','commit':COMMIT,
                'sourceSHA256':source_hash,'cmakeVersion':'3.31.6','cmakeWheelSHA256':wheel['digests']['sha256'],
                'deploymentTarget':'15.0','architectures':['ios-arm64','ios-arm64-simulator'],
                'backend':'CPU','armArch':ARM_ARCH,'metal':False,'accelerate':True,
                'blas':'Apple Accelerate (classic CBLAS ABI, iOS 15)',
                'parallelJobs':2,'modelWeightsBundled':False,
                'artifacts': {str(p.relative_to(PACKAGE)): {
                    'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()
                } for p in sorted(output.rglob('*')) if p.is_file()}},indent=2)+'\n')
            print('Pinned iPhone X+ FP16 / Accelerate runtime built:', output, flush=True)
        finally:
            owner.write_text(json.dumps({'pid':os.getpid(),'directory':str(work),'released':True}))


if __name__ == '__main__': main()
