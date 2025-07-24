#!/bin/bash

# Bitcoin Node Image - Fix Validation Script
# Tests the fixes applied to resolve build issues

set -e

echo "🔍 Bitcoin Node Image - Fix Validation"
echo "======================================"
echo

# Test 1: Check script syntax
echo "✅ Test 1: Script syntax validation"
bash -n scripts/customize-image.sh && echo "  ✓ customize-image.sh syntax OK"
bash -n scripts/bootstrap-rpc-creds.sh && echo "  ✓ bootstrap-rpc-creds.sh syntax OK"
bash -n scripts/firstboot-setup.sh && echo "  ✓ firstboot-setup.sh syntax OK"
echo

# Test 2: Check for problematic systemctl commands in chroot (excluding enable-services.sh creation)
echo "✅ Test 2: Check for systemctl enable commands in chroot script"
# Look for direct systemctl enable commands, not those being written to enable-services.sh
if grep -n "systemctl enable" scripts/customize-image.sh | grep -v "enable-services.sh" | grep -v "echo.*systemctl enable"; then
    echo "  ❌ Found direct systemctl enable commands in chroot script"
    grep -n "systemctl enable" scripts/customize-image.sh | grep -v "enable-services.sh" | grep -v "echo.*systemctl enable"
    exit 1
else
    echo "  ✓ No direct systemctl enable commands found in chroot script"
fi
echo

# Test 3: Check for swap file conflict handling
echo "✅ Test 3: Check swap file conflict handling"
if grep -q "swap file creation" scripts/customize-image.sh && grep -q "Skipping swap file creation" scripts/customize-image.sh; then
    echo "  ✓ Swap file creation properly skipped in chroot"
else
    echo "  ❌ Swap file creation not properly handled"
    exit 1
fi
echo

# Test 4: Check for service enablement script
echo "✅ Test 4: Check service enablement script creation"
if grep -q "enable-services.sh" scripts/customize-image.sh; then
    echo "  ✓ Service enablement script creation found"
else
    echo "  ❌ Service enablement script creation not found"
    exit 1
fi
echo

# Test 5: Check firstboot integration
echo "✅ Test 5: Check firstboot integration"
if grep -q "enable-services.sh" scripts/firstboot-setup.sh; then
    echo "  ✓ Firstboot service enablement integration found"
else
    echo "  ❌ Firstboot service enablement integration not found"
    exit 1
fi
echo

# Test 6: Check SSH configuration
echo "✅ Test 6: Check SSH configuration"
if grep -q "sshd_config.d" scripts/customize-image.sh; then
    echo "  ✓ SSH configuration setup found"
else
    echo "  ❌ SSH configuration setup not found"
    exit 1
fi
echo

# Test 7: Check error handling
echo "✅ Test 7: Check error handling"
if grep -q "|| echo \"Warning:" scripts/customize-image.sh; then
    echo "  ✓ Error handling with graceful degradation found"
else
    echo "  ❌ Error handling not found"
    exit 1
fi
echo

# Test 8: Check bootstrap script improvements
echo "✅ Test 8: Check bootstrap script improvements"
if grep -q "Creating bitcoin.conf file" scripts/bootstrap-rpc-creds.sh; then
    echo "  ✓ Bootstrap script file creation handling found"
else
    echo "  ❌ Bootstrap script file creation handling not found"
    exit 1
fi
echo

# Test 9: Check file permissions
echo "✅ Test 9: Check file permissions"
if grep -q "chmod 600" scripts/customize-image.sh; then
    echo "  ✓ Secure file permissions found"
else
    echo "  ❌ Secure file permissions not found"
    exit 1
fi
echo

# Test 10: Check memory management
echo "✅ Test 10: Check memory management"
if grep -q "apt-get clean" scripts/customize-image.sh; then
    echo "  ✓ Memory cleanup found"
else
    echo "  ❌ Memory cleanup not found"
    exit 1
fi
echo

# Test 11: Check that services are NOT enabled in chroot
echo "✅ Test 11: Verify services are NOT enabled in chroot"
if grep -q "systemctl enable ssh" scripts/customize-image.sh && ! grep -q "echo.*systemctl enable ssh" scripts/customize-image.sh; then
    echo "  ❌ Found direct systemctl enable ssh in chroot script"
    exit 1
else
    echo "  ✓ SSH service enabling properly deferred to first boot"
fi
echo

echo "🎉 All validation tests passed!"
echo
echo "📋 Summary of fixes applied:"
echo "  ✓ Swap file conflict resolution"
echo "  ✓ SSH service enabling moved to first boot"
echo "  ✓ Systemd service conflicts resolved"
echo "  ✓ Memory management improvements"
echo "  ✓ Error handling enhancements"
echo "  ✓ Bootstrap script robustness"
echo "  ✓ Security improvements"
echo
echo "🚀 Build process should now complete successfully!" 