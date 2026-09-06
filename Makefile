.PHONY: test fmt fmt-check vet check

test:
	v test .

fmt:
	v fmt -w .

fmt-check:
	v fmt -diff .

vet:
	v vet .

check: fmt-check vet test
