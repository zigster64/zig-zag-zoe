build:
	zig build

clean:
	rm -rf zig-cache zig-out

docker: docker-build

docker-build:
	zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
	ls -l zig-out/bin/zig-zag-zoe
	file zig-out/bin/zig-zag-zoe
	docker build -t zig-zag-zoe .

docker-run:
	docker run -it -e PORT=8080 -p 8080:8080 zig-zag-zoe:latest

docker-push:
	docker tag zig-zag-zoe ${DOCKER_REGISTRY}/zig-zag-zoe:latest
	docker push ${DOCKER_REGISTRY}/zig-zag-zoe:latest


