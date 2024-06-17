help:
	cat Makefile

build:
	zig build

clean:
	rm -rf zig-cache zig-out

run:

	zig build run

watch:
	find src -name '*.zig' -o -name '*.html' | entr -r zig build -freference-trace run

run-fast:
	zig build -Doptimize=ReleaseFast run

docker: docker-build docker-push

docker-build:
	zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
	#zig build -Dtarget=aarch64-linux-musl -Doptimize=Debug
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

bastille:
	zig build -Doptimize=ReleaseSmall
	bastille cmd zzz killall daemon
	bastille cp zzz zig-out/bin/zig-zag-zoe /root/bin
	ls -ltra zig-out/bin/zig-zag-zoe
	bastille cmd zzz ls -ltra /root/bin/zig-zag-zoe
	md5 zig-out/bin/zig-zag-zoe
	bastille cmd zzz md5 /root/bin/zig-zag-zoe
	bastille cmd zzz daemon -rf /root/bin/zig-zag-zoe
