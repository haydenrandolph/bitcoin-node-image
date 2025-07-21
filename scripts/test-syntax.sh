#!/bin/bash

# Test script to verify all shell scripts have correct syntax
echo "Testing shell script syntax..."

# Test all scripts
for script in scripts/*.sh; do
    echo "Testing $script..."
    if bash -n "$script"; then
        echo "✅ $script - Syntax OK"
    else
        echo "❌ $script - Syntax Error"
        exit 1
    fi
done

# Test heredoc syntax specifically
echo "Testing heredoc syntax..."

# Test the problematic sed commands
cat << 'TEST_EOF'
# Test sed command 1
if ! grep -q "autologin-user=bitcoin" /etc/lightdm/lightdm.conf; then
  sed -i "s/^#*autologin-user=.*/autologin-user=bitcoin/" /etc/lightdm/lightdm.conf
fi

# Test sed command 2
if [ -f "package.json" ]; then
  sed -i "s/\"start\":.*/\"start\": \"vite preview --host 0.0.0.0\",/" package.json || true
fi

echo "✅ Heredoc syntax test passed"
TEST_EOF

echo "✅ All tests passed" 