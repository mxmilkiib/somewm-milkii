# awesomewm configuration testing makefile
# provides convenient targets for configuration validation and testing

.PHONY: check test xephyr-test clean help

# default target
help:
	@echo "awesomewm configuration testing targets:"
	@echo ""
	@echo "  check        - syntax check configuration"
	@echo "  test         - full xephyr test (10 seconds)"
	@echo "  xephyr-test  - alias for test"
	@echo "  clean        - kill any running test processes"
	@echo "  help         - show this help"
	@echo ""
	@echo "environment variables:"
	@echo "  CONFIG_PATH     - path to config file (default: rc.lua)"
	@echo "  TIMEOUT         - test duration in seconds (default: 10)"

# syntax check only
check:
	@echo "🔍 checking configuration syntax..."
	@awesome -k -c $(or $(CONFIG_PATH),rc.lua)
	@echo "✅ syntax check passed"

# full xephyr test
test: check
	@echo "🧪 running xephyr test..."
	@TIMEOUT_SECONDS=$(or $(TIMEOUT),10) ./test_xephyr.sh $(or $(CONFIG_PATH),rc.lua)
	@echo "✅ xephyr test completed"

# alias for test
xephyr-test: test

# cleanup any running test processes
clean:
	@echo "🧹 cleaning up test processes..."
	@pkill -f "Xephyr :1" 2>/dev/null || true
	@pkill -f "DISPLAY=:1 awesome" 2>/dev/null || true
	@echo "✅ cleanup completed"

# quick test rule for plugin development
plugin-test: check
	@echo "🔧 quick plugin test (5 seconds)..."
	@TIMEOUT_SECONDS=5 ./test_xephyr.sh $(or $(CONFIG_PATH),rc.lua)
	@echo "✅ plugin test completed"
