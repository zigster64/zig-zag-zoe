help:
	cat Makefile

build:
	zig build

clean:
	rm -rf zig-cache zig-out

run:
	zig build run

run-fast:
	zig build -Doptimize=ReleaseFast run

docker: docker-build docker-push

docker-build:
	#zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
	zig build -Dtarget=aarch64-linux-musl -Doptimize=Debug
	ls -l zig-out/bin/zig-zag-zoe
	file zig-out/bin/zig-zag-zoe
	docker build -t zig-zag-zoe -f Docker/Dockerfile .

docker-run:
	docker run -it -e PORT=8080 -p 8080:8080 zig-zag-zoe:latest

docker-push:
	ecr-login
	docker tag zig-zag-zoe ${DOCKER_REGISTRY}/zig-zag-zoe:latest
	docker push ${DOCKER_REGISTRY}/zig-zag-zoe:latest

# this is a pain - need to stop the existing task then update the service. better than nothing
ecs-service-redeploy:
	aws ecs update-service --profile ${AWS_PROFILE} --cluster zig-zag-zoe --service zig-zag-zoe-service --task-definition zig-zag-zoe-task

build-and-launch: docker-build docker-push ecs-service-redeploy
