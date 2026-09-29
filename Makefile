.PHONY: test test-live clean

test:
	python3 -I -B test/test-security.py -v

# Real agents, real credentials, real (cheap) API calls. Run locally.
test-live:
	python3 -B test/test-agents.py -v

clean:
	rm -rf bin
