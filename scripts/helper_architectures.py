"""Verify universal helper slices and select architectures the Mac can execute."""
import platform
import subprocess


def execution_prefixes(helper, all_architectures):
    """Return arch prefixes; requested executable slices must never fall back.

    The ARM capability query describes the hardware even when Python runs under
    Rosetta. Intel Macs can inspect an ARM slice but cannot execute that slice.
    """
    if not all_architectures:
        return [[]]

    for architecture in ('arm64', 'x86_64'):
        verification = subprocess.run(['/usr/bin/lipo', str(helper), '-verify_arch', architecture],
                                      capture_output=True, text=True, timeout=30)
        if verification.returncode != 0:
            raise RuntimeError('Helper slice verification failed for ' + architecture + ': ' +
                               verification.stderr[:4096])
    print('Helper universal slices verified: arm64 and x86_64.', flush=True)
    capability = subprocess.run(['/usr/sbin/sysctl', '-n', 'hw.optional.arm64'],
                                capture_output=True, text=True, timeout=10)
    value = capability.stdout.strip()
    if capability.returncode == 0:
        if value not in ('0', '1'):
            raise RuntimeError('Unexpected hw.optional.arm64 value: ' + repr(value))
        arm_hardware = value == '1'
    elif 'unknown oid' in capability.stderr.lower() and platform.machine() in ('x86_64', 'i386'):
        # Some Intel macOS kernels omit this optional capability entirely.
        # ARM kernels expose it to both native and translated processes.
        arm_hardware = False
    else:
        raise subprocess.CalledProcessError(capability.returncode, capability.args,
                                            output=capability.stdout, stderr=capability.stderr)

    if arm_hardware:
        # An unavailable Rosetta runtime is a requested execution failure, not
        # grounds to discard the x86_64 behavioral assertions.
        return [['/usr/bin/arch', '-arm64'], ['/usr/bin/arch', '-x86_64']]

    print('SKIP arm64 execution: Intel hardware cannot execute arm64; '
          'both universal slices were verified. Running x86_64 behavioral checks.', flush=True)
    return [['/usr/bin/arch', '-x86_64']]
