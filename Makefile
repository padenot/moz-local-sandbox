.PHONY: test clean

test:
	python3 -I -B test/test-security.py -v

clean:
	rm -rf bin
